#!/usr/bin/env bash
# Scenario matrix for the CGReplay++ congestion study:
#   REPS repetitions x transports x (S0/S1/S2 x middle/last-mile).
# Each cell is one 120 s run via run_one.sh (bottleneck + ECN + timed iperf + merge).
# Defaults: all six transports, VMAF stride 5. The full study is REPS=5:
#   REPS=5 CGREPLAY_PCAP=drop ./run_matrix.sh
# RESUMABLE: cells whose dataset already exists are skipped, so you can stop it any time
# (Ctrl-C, reboot, VM off) and resume by re-running the SAME command — it continues where it
# left off. No need to run the ~21 h in one sitting.
# Override any knob by env, e.g. REPS=5 GAME=Kombat TRANSPORTS="roq-reno roq-cubic" ...
set -u
LAB=/home/hugo/cc-lab
cd "$LAB" || exit 1

REPS="${REPS:-1}"                          # repetitions per cell (the study wants 5)
GAME="${GAME:-Fortnite}"
# Final transport set: WebRTC (TWCC + RFC 8888), plain QUIC, RoQ with NewReno and CUBIC
# (aioquic has no BBR), SCReAM. Override TRANSPORTS to subset.
TRANSPORTS="${TRANSPORTS:-webrtc-twcc webrtc-rfc8888 quic roq-reno roq-cubic scream}"
SCENARIOS="${SCENARIOS:-S0-M S0-L S1-M S1-L S2-M S2-L}"
export CGREPLAY_VMAF_STRIDE="${CGREPLAY_VMAF_STRIDE:-5}"
export DURATION="${DURATION:-120}" B="${B:-10mbit}" C="${C:-8M}"
export IPERF_START="${IPERF_START:-30}" IPERF_LEN="${IPERF_LEN:-60}"
export CGREPLAY_PCAP="${CGREPLAY_PCAP:-gzip}"   # gzip pcaps after merge (keep | gzip | drop) so 180 runs fit
MINFREE_MB="${MINFREE_MB:-800}"            # abort before a run if the disk is this low
LOG="$LAB/matrix_$(date +%Y%m%d-%H%M%S).log"

ncells=0; for t in $TRANSPORTS; do for s in $SCENARIOS; do ncells=$((ncells+1)); done; done
total=$((ncells * REPS))
echo "=== matrix start $(date) | $total runs ($ncells cells x $REPS reps) | stride=$CGREPLAY_VMAF_STRIDE dur=${DURATION}s B=$B C=$C ===" | tee -a "$LOG"
echo "    transports: $TRANSPORTS" | tee -a "$LOG"

# Bring-up once (a reboot — or `mn -c` from a demo run — wipes the containerlab veths).
if ! sudo docker exec clab-cgreplay4-h0 ip -br addr 2>/dev/null | grep -q 10.0.1.10; then
  echo "[matrix] redeploy topology + dualq" | tee -a "$LOG"
  sudo containerlab deploy -t cgreplay4.clab.yml --reconfigure >/dev/null 2>&1
  sudo ./apply_dualq.sh >/dev/null 2>&1
fi

n=0; ok=0; fail=0
for rep in $(seq 1 "$REPS"); do            # rep outer → each sweep is a complete matrix
  for t in $TRANSPORTS; do
    for s in $SCENARIOS; do
      n=$((n+1))
      # Resumable: skip a cell that already has a dataset, so the matrix can be stopped
      # (reboot / Ctrl-C / VM off) and resumed by re-running the same command — it picks up
      # where it left off instead of redoing finished runs.
      done_rd=$(ls -dt results/${GAME}_${t}_${s}_r${rep}_* 2>/dev/null | head -1)
      if [ -n "$done_rd" ] && [ -s "$done_rd/dataset/video_frames.csv" ]; then
        ok=$((ok+1)); echo "=== [$n/$total] $t $s rep$rep | SKIP (done: $(basename "$done_rd")) ===" | tee -a "$LOG"
        continue
      fi
      free=$(df -m / | awk 'NR==2{print $4}')
      if [ "$free" -lt "$MINFREE_MB" ]; then
        echo "[matrix] ABORT at $n/$total: disk ${free}MB < ${MINFREE_MB}MB (gzip/offload the RoQ+QUIC pcaps, then resume with a higher starting rep)" | tee -a "$LOG"
        exit 1
      fi
      echo "=== [$n/$total] $t $s rep$rep | free ${free}MB | $(date +%T) ===" | tee -a "$LOG"
      if sudo CGREPLAY_VMAF_STRIDE="$CGREPLAY_VMAF_STRIDE" DURATION="$DURATION" B="$B" C="$C" \
           IPERF_START="$IPERF_START" IPERF_LEN="$IPERF_LEN" CGREPLAY_PCAP="$CGREPLAY_PCAP" \
           ./run_one.sh "$t" "$GAME" "$s" "$rep" >>"$LOG" 2>&1; then
        rd=$(ls -dt results/${GAME}_${t}_${s}_r${rep}_* 2>/dev/null | head -1)
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
done
echo "=== matrix done $(date): ok=$ok fail=$fail of $total ===" | tee -a "$LOG"
