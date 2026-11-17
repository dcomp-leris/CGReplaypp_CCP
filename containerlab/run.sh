#!/usr/bin/env bash
# Run ONE cloud-gaming transport through the L4S DualQ testbed for a chosen session length,
# and get its per-frame dataset + QoE. Front-end to run_one.sh (one uv .venv for all).
#
#   run.sh <transport> [duration_s] [game] [scenario] [rep]
#
#   transport : webrtc-twcc | webrtc-rfc8888 | quic | roq | roq-cubic | scream
#               (quic = plain QUIC over reliable streams; its dataset has quality+QoE but
#                no per-frame pcap network features, since it is not RTP)
#   duration  : session length in seconds (default 120; e.g. 60, 120, 300)
#   game      : Fortnite (default) | Kombat | Forza
#   scenario  : S0-M (default S1-M) ... S{0,1,2}-{M,L}  (cross-traffic level x bottleneck link)
#
# Run them one by one, e.g.:
#   ./run.sh webrtc-twcc 120
#   ./run.sh webrtc-rfc8888 120
#   ./run.sh roq 120
#   ./run.sh roq-cubic 120
#   ./run.sh scream 120
set -euo pipefail
LAB=cgreplay4; LABDIR=/home/hugo/cc-lab

T="${1:?transport: webrtc-twcc|webrtc-rfc8888|quic|roq|roq-cubic|scream}"
DUR="${2:-120}"; GAME="${3:-Fortnite}"; SCN="${4:-S1-M}"; REP="${5:-1}"

# A reboot wipes the containerlab veth wiring; redeploy + reattach DualQ if the server IP is gone.
if ! sudo docker exec "clab-$LAB-h0" ip -br addr 2>/dev/null | grep -q 10.0.1.10; then
  echo "[run] topology down — redeploying + DualQ ..."
  sudo containerlab deploy -t "$LABDIR/cgreplay4.clab.yml" --reconfigure >/dev/null 2>&1
  sudo "$LABDIR/apply_dualq.sh" >/dev/null 2>&1
fi

echo "[run] $T  duration=${DUR}s  game=$GAME  scenario=$SCN  rep=$REP"
sudo DURATION="$DUR" "$LABDIR/run_one.sh" "$T" "$GAME" "$SCN" "$REP"

R=$(ls -dt "$LABDIR"/results/${GAME}_${T}_${SCN}_r${REP}_* 2>/dev/null | head -1)
if [ -s "$R/dataset/video_frames.csv" ]; then
  echo "[run] OK -> $R/dataset/video_frames.csv"
  [ -f "$R/dataset/qoe.json" ] && echo "[run]    QoE  -> $R/dataset/qoe.json"
else
  echo "[run] FAILED: no dataset produced (check the topology / logs)"; exit 1
fi
