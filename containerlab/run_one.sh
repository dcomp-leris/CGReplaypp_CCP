#!/usr/bin/env bash
# One CGReplay++ congestion run through the Containerlab L4S topology, end to end:
#   scenario -> bottleneck + target-link PCAP -> iperf server -> launch transport
#   (looping to DURATION s) -> schedule the iperf cross-flow at T0+30 for 60 s
#   -> collect a per-run directory + run.json -> merge into the per-frame dataset.
#
# Usage:
#   run_one.sh <transport> <game> <scenario> [rep]
#     transport : webrtc-twcc | webrtc-rfc8888 | roq | scream
#     game      : Kombat | Forza | Fortnite
#     scenario  : S0-M | S1-M | S2-M | S0-L | S1-L | S2-L
#     rep       : repetition index (default 1)
# Tunables (env): B (bottleneck, default 10mbit), C (iperf rate, default 8M),
#   DURATION (default 120), IPERF_START (default 30), IPERF_LEN (default 60).
set -u
TRANSPORT="${1:?transport}"; GAME="${2:?game}"; SCENARIO="${3:?scenario}"; REP="${4:-1}"
REPO=/home/hugo/CGSynth/CGReplaypp
LAB=cgreplay4; SYS=/usr/bin/python3; VENV=/home/hugo/venv/bin/python3
CFG="$REPO/config/config.yaml"
LABDIR=/home/hugo/cc-lab
B="${B:-10mbit}"; C="${C:-8M}"; DURATION="${DURATION:-120}"
IPERF_START="${IPERF_START:-30}"; IPERF_LEN="${IPERF_LEN:-60}"; IPERF_PORT=5201
SERVER_IP=10.0.1.10; PLAYER_IP=10.0.2.10
H2_IP=10.0.3.10; H3_IP=10.0.4.10            # iperf hosts (s1 side / s2 side)
pid(){ docker inspect -f '{{.State.Pid}}' "clab-$LAB-$1" 2>/dev/null; }

# --- scenario -> target link, cross-traffic, ECN ---------------------------------
case "$SCENARIO" in
  *-M) LINK=middle;   SNIFF_NODE=s1; SNIFF_IF=eth2;;   # bottleneck s1->s2 egress
  *-L) LINK=lastmile; SNIFF_NODE=s2; SNIFF_IF=eth2;;   # bottleneck s2->gamer egress
  *) echo "bad scenario $SCENARIO"; exit 1;;
esac
case "$SCENARIO" in
  S0-*) CROSS=0; ECN=0;;
  S1-*) CROSS=1; ECN=0;;
  S2-*) CROSS=1; ECN=1;;
  *) echo "bad scenario $SCENARIO"; exit 1;;
esac
# iperf client/server placement: opposite sides of the target link
if [ "$LINK" = middle ]; then IPERF_CLIENT=h2; IPERF_SRV=h3; IPERF_SRV_IP=$H3_IP
else                          IPERF_CLIENT=h3; IPERF_SRV=h1; IPERF_SRV_IP=$PLAYER_IP; fi

H0=$(pid h0); H1=$(pid h1); SNIFF_PID=$(pid "$SNIFF_NODE")
GAMER_SNIFF_PID=$(pid s2)   # always also capture the media arriving at the gamer (s2-eth2)
{ [ -z "$H0" ] || [ -z "$H1" ]; } && { echo "topologia nao no ar (redeploy)"; exit 1; }

RUN_ID="${GAME}_${TRANSPORT}_${SCENARIO}_r${REP}_$(date +%Y%m%d-%H%M%S)"
RUN="$LABDIR/results/$RUN_ID"; mkdir -p "$RUN"
PCAP_T="/tmp/${RUN_ID}_${SNIFF_NODE}-${SNIFF_IF}.pcap"       # target-link egress
PCAP_G="/tmp/${RUN_ID}_s2-eth2.pcap"                         # gamer-side (media)
echo "### RUN $RUN_ID | link=$LINK B=$B cross=$CROSS(C=$C) ECN=$ECN dur=${DURATION}s"

# --- bottleneck + ECN ------------------------------------------------------------
sudo "$LABDIR/set_bottleneck.sh" "$LINK" "$B" >/dev/null 2>&1
# ECN on the hosts (L4S needs ECT-capable endpoints); SCReAM ECT via env below.
for n in h0 h1; do docker exec "clab-$LAB-$n" sysctl -qw net.ipv4.tcp_ecn="$ECN" 2>/dev/null; done

# --- config for this run ---------------------------------------------------------
cp "$CFG" "$CFG.clabbak"
trap 'kill $SRV_PID $GAM_PID 2>/dev/null; pkill -f cg_server1.py 2>/dev/null; pkill -f cg_gamer1.py 2>/dev/null; mv "$CFG.clabbak" "$CFG" 2>/dev/null' EXIT
sed -i "s/^    game: .*/    game: \"$GAME\"/" "$CFG"
sed -i 's/^    server_IP: .*/    server_IP: "10.0.1.10"/' "$CFG"
sed -i 's/^    player_IP: .*/    player_IP: "10.0.2.10"/' "$CFG"
sed -i 's/^    live_watching: .*/    live_watching: False/' "$CFG"
rm -f "$REPO/player/received_frames/"*.png "$REPO/player/logs/quic_keylog.txt" 2>/dev/null

# --- per-transport env + launch commands ----------------------------------------
LOOP_ENV="CGREPLAY_LOOP_DURATION_S=$DURATION"
case "$TRANSPORT" in
  webrtc-twcc|webrtc-rfc8888)
    FB="${TRANSPORT#webrtc-}"
    sed -i 's/QUIC: True/QUIC: False/; s/SCReAM: True/SCReAM: False/; s/RoQ: True/RoQ: False/' "$CFG"
    SRV_ENV="$LOOP_ENV CGREPLAY_CC_FEEDBACK=$FB DISPLAY=:0 PYTHONUNBUFFERED=1"; SRV_PY=$SYS
    GAM_ENV="$LOOP_ENV CGREPLAY_CC_FEEDBACK=$FB DISPLAY=:0 PYTHONUNBUFFERED=1"; GAM_PY=$SYS ;;
  roq)
    sed -i 's/QUIC: True/QUIC: False/; s/SCReAM: True/SCReAM: False/; s/RoQ: False/RoQ: True/' "$CFG"
    SRV_ENV="$LOOP_ENV DISPLAY=:0 PYTHONUNBUFFERED=1"; SRV_PY=$VENV
    GAM_ENV="$LOOP_ENV DISPLAY=:0 PYTHONUNBUFFERED=1"; GAM_PY=$VENV ;;
  scream)
    sed -i 's/QUIC: True/QUIC: False/; s/RoQ: True/RoQ: False/; s/SCReAM: False/SCReAM: True/' "$CFG"
    SP=/home/hugo/CGSynth/scream/gstscream/target/debug
    SL=/home/hugo/CGSynth/scream/code/wrapper_lib
    GENV="GST_PLUGIN_PATH=$SP LD_LIBRARY_PATH=$SL CGREPLAY_PLAYER_IP=$PLAYER_IP CGREPLAY_SERVER_IP=$SERVER_IP CGREPLAY_RTCP_PORT=5004 CGREPLAY_ENCODER=h264 CGREPLAY_SCREAM_ECT=$ECN"
    SRV_ENV="$LOOP_ENV $GENV DISPLAY=:0 PYTHONUNBUFFERED=1"; SRV_PY=$SYS
    GAM_ENV="$LOOP_ENV $GENV DISPLAY=:0 PYTHONUNBUFFERED=1"; GAM_PY=$SYS ;;
  *) echo "bad transport $TRANSPORT"; exit 1;;
esac

# --- captures (exclude the iperf port so the media pcap stays small) --------------
rm -f "$PCAP_T" "$PCAP_G"
nsenter -t "$SNIFF_PID" -n tcpdump -i "$SNIFF_IF" -w "$PCAP_T" "udp and not port $IPERF_PORT" >/dev/null 2>&1 & TD1=$!
[ "$SNIFF_PID" != "$GAMER_SNIFF_PID" ] && { nsenter -t "$GAMER_SNIFF_PID" -n tcpdump -i eth2 -w "$PCAP_G" "udp and not port $IPERF_PORT" >/dev/null 2>&1 & TD2=$!; } || TD2=""
sleep 1

# iperf runs via `docker exec` (the netshoot container ships iperf3; the host does
# NOT, so `nsenter -n iperf3` would be "command not found"). The server/client are
# launched from the T0 scheduler below.

# --- launch transport: server (h0) then gamer (h1) -------------------------------
nsenter -t "$H0" -n sh -c "cd $REPO/server && $SRV_ENV $SRV_PY cg_server1.py" > /tmp/${RUN_ID}_srv.log 2>&1 & SRV_PID=$!
sleep 1
nsenter -t "$H1" -n sh -c "cd $REPO/player && $GAM_ENV $GAM_PY cg_gamer1.py" > /tmp/${RUN_ID}_gam.log 2>&1 & GAM_PID=$!

# --- T0 = first server video frame; schedule iperf cross-flow at T0+30 -----------
IPLOG=/tmp/${RUN_ID}_iperf.log
if [ "$CROSS" = 1 ]; then
  ( for i in $(seq 1 120); do grep -q "Streaming frame" /tmp/${RUN_ID}_srv.log 2>/dev/null && break; sleep 0.5; done
    echo "[iperf] T0 detected $(date +%T); cross-flow in ${IPERF_START}s (C=$C for ${IPERF_LEN}s) ${IPERF_CLIENT}->${IPERF_SRV_IP}" > "$IPLOG"
    docker exec -d "clab-$LAB-$IPERF_SRV" iperf3 -s -1 -p $IPERF_PORT >>"$IPLOG" 2>&1
    sleep "$IPERF_START"
    echo "[iperf] starting client $(date +%T)" >> "$IPLOG"
    docker exec "clab-$LAB-$IPERF_CLIENT" iperf3 -c "$IPERF_SRV_IP" -u -p $IPERF_PORT -b "$C" -t "$IPERF_LEN" \
        --get-server-output --json > "$RUN/iperf.json" 2>>"$IPLOG"
    echo "[iperf] client done $(date +%T) exit=$?" >> "$IPLOG" ) &
fi

# --- wait for the gamer to finish (hard cap in the gamer watchdog backs this up) --
# Break as soon as the gamer is done: its completion line (GStreamer transports print
# "RTP streaming complete"; the RoQ receiver prints "[SUMMARY]") or, robustly for any
# transport, the gamer process having exited. The DURATION+90 cap is the backstop.
for i in $(seq 1 $((DURATION + 90))); do
  grep -qE "RTP streaming complete|\[SUMMARY\]" /tmp/${RUN_ID}_gam.log 2>/dev/null && break
  kill -0 $GAM_PID 2>/dev/null || break
  sleep 1
done
sleep 2; kill -INT $TD1 $TD2 2>/dev/null; wait $TD1 2>/dev/null; sleep 1

# Stop the transport. The RoQ server (roq_main) keeps the QUIC port open after the
# stream ends, so without this it lingers and the NEXT run's receiver connects to the
# stale server (old code, no loop) instead of a fresh one. Kill the nsenter wrappers
# and their python children (reparented, so a pkill by script name is the reliable part).
kill $SRV_PID $GAM_PID 2>/dev/null
pkill -f cg_server1.py 2>/dev/null; pkill -f cg_gamer1.py 2>/dev/null
sleep 1

n=$(ls "$REPO/player/received_frames/"*.png 2>/dev/null | wc -l)
echo "### frames=$n ; target-pcap=$(du -h $PCAP_T 2>/dev/null|cut -f1) ; gamer-pcap=$(du -h $PCAP_G 2>/dev/null|cut -f1)"

# --- run.json --------------------------------------------------------------------
COMMIT=$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null)
cat > "$RUN/run.json" <<JSON
{ "run_id": "$RUN_ID", "game": "$GAME", "transport": "$TRANSPORT", "scenario": "$SCENARIO",
  "rep": $REP, "target_link": "$LINK", "B": "$B", "C": "$([ "$CROSS" = 1 ] && echo "$C" || echo null)",
  "cross_traffic": $CROSS, "ecn": $ECN, "duration_s": $DURATION,
  "iperf_start_s": $IPERF_START, "iperf_len_s": $IPERF_LEN, "iperf_port": $IPERF_PORT,
  "commit": "$COMMIT", "codec": "h264", "reference_frames": "$REPO/server/$GAME" }
JSON

# --- collect + merge -------------------------------------------------------------
PCAPS=("$PCAP_T"); [ -n "$TD2" ] && PCAPS+=("$PCAP_G")
"$LABDIR/collect_and_merge.sh" "$RUN" "$GAME" "$TRANSPORT" "$RUN/run.json" "${PCAPS[@]}"
# the /tmp pcaps are now copied into $RUN/pcap and the srv/gam logs are consumed
rm -f "$PCAP_T" "$PCAP_G" /tmp/${RUN_ID}_srv.log /tmp/${RUN_ID}_gam.log /tmp/${RUN_ID}_iperf.log 2>/dev/null
mv "$CFG.clabbak" "$CFG" 2>/dev/null; trap - EXIT
echo "### done -> $RUN"
