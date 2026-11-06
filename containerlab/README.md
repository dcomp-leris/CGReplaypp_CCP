# Containerlab L4S DualQ testbed

The 4-endpoint Containerlab topology with L4S DualQ (DualPI2) that the experiment
protocol needs but the Mininet code did not have. CGReplay streams across two
switches with a selectable bottleneck, a switch-side PCAP sniffer, and the
per-frame network features are merged with VMAF.

```
h0 (server) ── s1 ── s2 ── h1 (gamer)
              │        │
              h2       h3     (iperf hosts, one per switch)
```

## Requirements
- A kernel with L4S DualQ: `sch_dualpi2` + `tcp_prague` (we use the L4STeam 6.12 build).
- Docker + Containerlab.
- The CGReplay deps on the host (GStreamer, the venv, gstscream, the static libvmaf ffmpeg): the server/gamer run inside the container netns via `nsenter`, so no custom image is needed yet.

## Files
| File | What it does |
|---|---|
| `cgreplay4.clab.yml` | topology (4 hosts + 2 switches, routed; dualpi2 attached post-deploy) |
| `apply_dualq.sh` | load `sch_dualpi2`/`tcp_prague` and attach `dualpi2` on both switches |
| `set_bottleneck.sh middle\|lastmile <rate>` | pick the one shaped/measured link |
| `run_cgreplay_clab.sh` | run CGReplay through the topology + switch PCAP + VMAF + merge |
| `test_gst_netns.sh` | feasibility check (GStreamer inside the container netns) |
| `sample_merged_dataset.csv` | sample output (see below) |

## Run
```bash
sudo containerlab deploy -t cgreplay4.clab.yml
sudo ./apply_dualq.sh                 # modprobe is a host step; container exec cannot
sudo ./set_bottleneck.sh middle 10mbit
sudo ./run_cgreplay_clab.sh           # set REPO= to your CGReplay checkout
# redeploy with --reconfigure after a host reboot (containerlab veth wiring is not persistent)
```

## Status (validated)
- 4-endpoint topology, routed; L4S DualQ on both switches; selectable bottleneck (middle `s1-s2` or last-mile `s2-h1`).
- CGReplay streams end-to-end through the topology (via `nsenter` into h0/h1), through the DualQ bottleneck.
- Switch sniffer (`tcpdump` at `s2-eth2`) + VMAF + merge keyed by the **RTP timestamp**.
- Limited run (RTP over a 10 Mbit DualQ middle bottleneck): 114 frames received, VMAF SSIM 0.78 / QoE 0.49, **merge 126/126 frames matched by `rtp_timestamp`** (network features + quality on the same row). See `sample_merged_dataset.csv`: `frame_id, rtp_timestamp, n_pkts, bytes, lost, span_ms, SSIM, PSNR, VMAF, QoE`.

## What is left for the full scenario matrix
- Timed iperf cross-traffic (T0+30 → T0+90) and 120 s runs, which need deterministic frame looping (Kombat has 120 frames).
- Use the `alireza`-branch transports (webrtc-twcc, webrtc-rfc8888, roq, scream) instead of the plain RTP path used here.
- Scenario matrix S0/S1/S2 × middle/last-mile, 5 repetitions × game × transport, with per-run output directories and `run.json`.
- Extra per-run logs from the protocol: `srv_encoder_bitrate.csv` and the transport/controller telemetry.
- A custom Docker image with the CGReplay deps for a fully reproducible collection (the current launcher reuses host deps via `nsenter`).

## What I need from Alireza to continue
1. Confirm the merged-dataset schema (this one vs the merge on the `alireza` branch) so we align on a single format.
2. Target values for B (link capacity) and C (iperf rate), or OK to run the no-cross-traffic pilot and pick them.
3. Should the Containerlab run be driven by your `run_matrix.sh` (one orchestrator), or stay a separate Containerlab runner?
4. Frame looping: loop the 120-frame capture, or use the Kaggle dataset? The reference must loop the same way for VMAF.
5. The exact transport list to include (webrtc-twcc, webrtc-rfc8888, webrtc-none, roq, scream — which ones).
