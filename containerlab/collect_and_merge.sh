#!/usr/bin/env bash
# Assemble one run directory in the layout build_rtp_dataset.py expects and run
# the merge. Called by run_one.sh after a transport finishes.
#   collect_and_merge.sh <run_dir> <game> <transport> <run_json_path> <pcap1> [pcap2 ...]
set -u
RUN="$1"; GAME="$2"; TRANSPORT="$3"; RUNJSON="$4"; shift 4
REPO=/home/hugo/CGSynth/CGReplaypp
VENV=/home/hugo/venv/bin/python3
FFMPEG=/home/hugo/CGSynth/tools/ffmpeg-vmaf/ffmpeg

mkdir -p "$RUN/server_logs" "$RUN/player_logs" "$RUN/pcap"
cp "$REPO"/server/logs/*.csv "$RUN/server_logs/" 2>/dev/null
cp "$REPO"/player/logs/*.csv "$RUN/player_logs/" 2>/dev/null
cp "$REPO"/player/logs/quic_keylog.txt "$RUN/player_logs/" 2>/dev/null   # RoQ: QUIC decryption key log
# Symlink (not copy) received_frames so the merge reads them without doubling disk
# use. Lean mode removes the symlink after; the source is overwritten next run.
ln -sfn "$REPO/player/received_frames" "$RUN/received_frames"
for p in "$@"; do [ -f "$p" ] && cp "$p" "$RUN/pcap/$(basename "$p")"; done
# config.yaml with the containerlab endpoint IPs so the pcap server->player filter is exact
sed -e 's/^    server_IP: .*/    server_IP: "10.0.1.10"/' \
    -e 's/^    player_IP: .*/    player_IP: "10.0.2.10"/' "$REPO/config/config.yaml" > "$RUN/config.yaml"
[ "$(readlink -f "$RUNJSON")" != "$(readlink -f "$RUN/run.json")" ] && cp "$RUNJSON" "$RUN/run.json"

echo "=== merge: $RUN ==="
# CGREPLAY_NO_VMAF=1 skips the slow ffmpeg/libvmaf pass (PSNR/SSIM still computed) for fast iteration.
MARGS=""; [ "${CGREPLAY_NO_VMAF:-0}" = 1 ] && MARGS="--no-vmaf"
# run from the repo so a relative reference_frames path (server/<game>) resolves
cd "$REPO" && CGREPLAY_FFMPEG="$FFMPEG" "$VENV" "$REPO/tools/build_rtp_dataset.py" "$RUN" $MARGS 2>&1 | tail -8

# Lean mode (default ON while the disk is tight): the merge has baked per-frame
# PSNR/SSIM/VMAF into dataset/video_frames.csv, so the bulky received_frames copy
# is no longer needed. Keep the CSV, logs, run.json, iperf.json and pcaps.
if [ "${CGREPLAY_LEAN:-1}" = 1 ] && [ -s "$RUN/dataset/video_frames.csv" ]; then
    rm -rf "$RUN/received_frames"
    rm -rf /tmp/cg_vmaf_* 2>/dev/null   # libvmaf scratch (root-owned, from this merge)
    echo "[lean] removed received_frames copy (quality is in the CSV); kept pcaps+CSV+logs"
fi
du -sh "$RUN" 2>/dev/null | sed 's/^/[run size] /'
