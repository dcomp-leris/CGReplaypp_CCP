# Containerlab L4S DualQ testbed — CGReplay++ congestion experiment

The 4-endpoint Containerlab topology with L4S DualQ (DualPI2) for the CGReplay++
congestion study (CGReplay_ex.md): compare **WebRTC / RoQ / SCReAM** under a timed
competing flow, on a selectable bottleneck, with a switch-side PCAP and the
per-frame network features merged with received-video quality (SSIM/PSNR/VMAF).

```
h0 (server) ── s1 ── s2 ── h1 (gamer)
              │        │
              h2       h3     (iperf hosts, one per switch)
           (middle)  (last mile)
```

## Requirements
- Kernel with L4S DualQ: `sch_dualpi2` + `tcp_prague` (L4STeam 6.12 build).
- Docker + Containerlab (`nicolaka/netshoot` nodes).
- CGReplay deps on the host (GStreamer, the venv with aioquic/PyAV/skimage, gstscream,
  the static libvmaf ffmpeg): the server/gamer run inside the node netns via `nsenter`,
  so no custom image is needed. iperf runs via `docker exec` (netshoot ships iperf3;
  the host does not).
- Two upstream patches (see `patches/`): apply before running.

## Patches (apply first)
These modify code that lives in third-party repos; apply them to your checkouts.
- `patches/cgreplaypp-frame-looping.patch` → `dcomp-leris/CGReplaypp` (branch `alireza`):
  deterministic frame looping gated by `CGREPLAY_LOOP_DURATION_S` so a 120 s run can
  replay a short capture, and the gamer no longer stops at `stop_frm_number` while looping.
- `patches/scream-rtcp-feedback.patch` → `EricssonResearch/scream` (`gstscream/scripts`):
  adds the SCReAM RTCP feedback channel (screamtx.rtcp_sink ↔ screamrx) so SCReAM does
  real congestion detection + rate control instead of running open-loop.

```bash
cd <CGReplaypp>  && git apply <this>/patches/cgreplaypp-frame-looping.patch
cd <scream>      && git apply <this>/patches/scream-rtcp-feedback.patch
```

## Files
| File | What it does |
|---|---|
| `cgreplay4.clab.yml` | topology (4 hosts + 2 switches, routed; dualpi2 attached post-deploy) |
| `apply_dualq.sh` | load `sch_dualpi2`/`tcp_prague` and attach `dualpi2` on both switches |
| `set_bottleneck.sh middle\|lastmile <rate>` | shape the one target link |
| `run_one.sh <transport> <game> <scenario> [rep]` | **one full run end to end** (below) |
| `collect_and_merge.sh` | assemble a run dir + run the per-frame merge (lean by default) |
| `run_webrtc_clab.sh` / `run_roq_clab.sh` / `run_scream_clab.sh` | single-transport runners (no scenario/iperf) |
| `run_pilot.sh` | per-game video-throughput pilot (to calibrate B/C) |
| `run_cgreplay_clab.sh` | the original plain-RTP runner (our branch) |
| `test_gst_netns.sh` | feasibility check (GStreamer inside a node netns) |
| `patches/` | the two upstream patches above |
| `sample_merged_dataset.csv` | sample merged output |

## Run
```bash
sudo containerlab deploy -t cgreplay4.clab.yml --reconfigure   # --reconfigure after a host reboot (veth wiring is not persistent)
sudo ./apply_dualq.sh                                          # modprobe is a host step; container exec cannot

# one run: transport ∈ {webrtc-twcc, webrtc-rfc8888, roq, scream}
#          scenario ∈ {S0,S1,S2}-{M,L}   (M=middle s1-s2, L=last-mile s2-gamer)
sudo DURATION=120 B=10mbit C=8M ./run_one.sh webrtc-twcc Kombat S1-M 1
```
`run_one.sh` sets the bottleneck + ECN for the scenario, captures PCAP on the
bottleneck egress and at the gamer, launches the transport looping to `DURATION`,
detects **T0** (first server frame) and starts the iperf cross-flow at **T0+30 s**
for **60 s** (S1/S2 only), writes `run.json`, then merges into
`dataset/video_frames.csv`. Tunables: `B` (bottleneck), `C` (iperf rate),
`DURATION`, `IPERF_START`, `IPERF_LEN`. `CGREPLAY_NO_VMAF=1` skips the slow VMAF
pass; `CGREPLAY_LEAN=1` (default) drops the bulky frame copy after the merge so each
run dir stays a few MB.

## Status (validated)
- 4-endpoint topology, routed; L4S DualQ on both switches; selectable bottleneck.
- All three transports stream end-to-end through the DualQ bottleneck with **working
  receiver→sender feedback**: WebRTC (TWCC/RFC 8888 → `srv_gcc.csv`), SCReAM (RTCP via
  the patch → real rate control), RoQ (QUIC congestion control; the receiver logs the
  TLS key so the merge decrypts the QUIC pcap and reads the RTP headers).
- Frame looping to a wall-clock duration; timed iperf cross-flow at T0+30→90.
- Merge keyed by the RTP timestamp → per-frame dataset (encoder rate, switch-side
  loss/reorder/OWD/jitter/kbps, player decode/latency, PSNR/SSIM/VMAF) in one row.
- Smoke (S1-M, webrtc-twcc, 25 s, iperf T0+10/10 s): iperf 8 Mbps/3.9 % loss, 176
  lost pkts at the bottleneck captured per-frame, 85-column dataset, run dir 14 MB.

## What is left for the full scenario matrix
- Turn VMAF back on for collection (slow, ~6 min per 40 s run — the matrix bottleneck;
  consider frame sampling or parallelism).
- Use a long capture (the 9000-frame Kaggle Fortnite) instead of looping a 120-frame set.
- Scenario matrix S0/S1/S2 × middle/last-mile, 3–4 transports, 5 repetitions per cell.
- Verify CE/ECN at the target-link egress for the S2 rows.
- A custom Docker image with the CGReplay deps for a fully reproducible collection.
