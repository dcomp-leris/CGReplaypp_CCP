#!/usr/bin/env bash
# Pilot scenario matrix for the CGReplay++ congestion study.
#   transports x (S0/S1/S2 x middle/last-mile), REP repetitions each.
# Each cell is one 120 s run via run_one.sh (bottleneck + ECN + timed iperf + merge).
# Defaults: 1 rep, VMAF stride 5 (PSNR/SSIM per frame, VMAF on a 1/5 sample).
# Override any knob by env, e.g. REP=5 TRANSPORTS="roq" ./run_matrix.sh
set -u
LAB=/home/hugo/cc-lab
cd "$LAB" || exit 1

REP="${REP:-1}"
GAME="${GAME:-Fortnite}"
TRANSPORTS="${TRANSPORTS:-webrtc-twcc webrtc-rfc8888 roq scream}"
SCENARIOS="${SCENARIOS:-S0-M S0-L S1-M S1-L S2-M S2-L}"
export CGREPLAY_VMAF_STRIDE="${CGREPLAY_VMAF_STRIDE:-5}"
export DURATION="${DURATION:-120}" B="${B:-10mbit}" C="${C:-8M}"
export IPERF_START="${IPERF_START:-30}" IPERF_LEN="${IPERF_LEN:-60}"
MINFREE_MB="${MINFREE_MB:-500}"            # abort before a run if the disk is this low
LOG="$LAB/matrix_$(date +%Y%m%d-%H%M%S).log"

total=0; for t in $TRANSPORTS; do for s in $SCENARIOS; do total=$((total+1)); done; done
echo "=== matrix start $(date) | $total runs | rep=$REP stride=$CGREPLAY_VMAF_STRIDE dur=${DURATION}s B=$B C=$C ===" | tee -a "$LOG"

# Bring-up once (a reboot wipes the containerlab veth wiring).
if ! sudo docker exec clab-cgreplay4-h0 ip -br addr 2>/dev/null | grep -q 10.0.1.10; then
  echo "[matrix] redeploy topology + dualq" | tee -a "$LOG"
  sudo containerlab deploy -t cgreplay4.clab.yml --reconfigure >/dev/null 2>&1
  sudo ./apply_dualq.sh >/dev/null 2>&1
fi

n=0; ok=0; fail=0
for t in $TRANSPORTS; do
  for s in $SCENARIOS; do
    n=$((n+1))
    free=$(df -m / | awk 'NR==2{print $4}')
    if [ "$free" -lt "$MINFREE_MB" ]; then
      echo "[matrix] ABORT at $n/$total: disk ${free}MB < ${MINFREE_MB}MB (gzip RoQ pcaps or offload run dirs, then resume)" | tee -a "$LOG"
      exit 1
    fi
    echo "=== [$n/$total] $t $s rep$REP | free ${free}MB | $(date +%T) ===" | tee -a "$LOG"
    if sudo CGREPLAY_VMAF_STRIDE="$CGREPLAY_VMAF_STRIDE" DURATION="$DURATION" B="$B" C="$C" \
         IPERF_START="$IPERF_START" IPERF_LEN="$IPERF_LEN" \
         ./run_one.sh "$t" "$GAME" "$s" "$REP" >>"$LOG" 2>&1; then
      rd=$(ls -dt results/${GAME}_${t}_${s}_r${REP}_* 2>/dev/null | head -1)
      if [ -s "$rd/dataset/video_frames.csv" ]; then
        rows=$(($(wc -l < "$rd/dataset/video_frames.csv")-1))
        ok=$((ok+1)); echo "  OK ($rows frames) -> $rd" | tee -a "$LOG"
      else
        fail=$((fail+1)); echo "  FAIL: no video_frames.csv in $rd" | tee -a "$LOG"
      fi
    else
      fail=$((fail+1)); echo "  FAIL: run_one.sh exited nonzero" | tee -a "$LOG"
    fi
  done
done
echo "=== matrix done $(date): ok=$ok fail=$fail of $total ===" | tee -a "$LOG"
