#!/usr/bin/env bash
# Pilot: measure native video throughput per game (WebRTC/twcc, no cross-traffic,
# unconstrained link) to calibrate B (bottleneck) and C (iperf). Run as root.
set -u
REPO=/home/hugo/CGSynth/CGReplaypp
LAB=cgreplay4; SYS=/usr/bin/python3; CFG="$REPO/config/config.yaml"
pid(){ docker inspect -f '{{.State.Pid}}' "clab-$LAB-$1" 2>/dev/null; }
H0=$(pid h0); H1=$(pid h1); S2=$(pid s2)
# unconstrained target link
/home/hugo/cc-lab/set_bottleneck.sh middle 1000mbit >/dev/null 2>&1

cp "$CFG" "$CFG.pilotbak"; trap 'mv "$CFG.pilotbak" "$CFG" 2>/dev/null' EXIT
sed -i 's/^    server_IP: .*/    server_IP: "10.0.1.10"/; s/^    player_IP: .*/    player_IP: "10.0.2.10"/' "$CFG"
sed -i 's/QUIC: True/QUIC: False/; s/SCReAM: True/SCReAM: False/; s/RoQ: True/RoQ: False/; s/^    live_watching: .*/    live_watching: False/' "$CFG"

printf "%-10s %14s %14s %8s\n" "game" "thr_pcap(Mbps)" "gcc_rate(kbps)" "frames"
printf "%-10s %14s %14s %8s\n" "----" "-------------" "--------------" "------"
for game in Kombat Forza Fortnite; do
  sed -i "s/^    game: .*/    game: \"$game\"/" "$CFG"
  rm -f "$REPO/player/received_frames/"*.png 2>/dev/null
  P=/tmp/pilot_$game.pcap; rm -f "$P"
  nsenter -t "$S2" -n tcpdump -i eth2 -w "$P" udp port 5002 >/dev/null 2>&1 & TD=$!; sleep 1
  nsenter -t "$H0" -n sh -c "cd $REPO/server && CGREPLAY_CC_FEEDBACK=twcc DISPLAY=:0 PYTHONUNBUFFERED=1 $SYS cg_server1.py" >/tmp/pilot_srv.log 2>&1 &
  sleep 1
  nsenter -t "$H1" -n sh -c "cd $REPO/player && CGREPLAY_CC_FEEDBACK=twcc DISPLAY=:0 PYTHONUNBUFFERED=1 $SYS cg_gamer1.py" >/tmp/pilot_gam.log 2>&1 &
  for i in $(seq 1 60); do grep -q "RTP streaming complete" /tmp/pilot_gam.log 2>/dev/null && break; sleep 1; done
  sleep 2; kill -INT $TD 2>/dev/null; sleep 1
  # throughput from pcap: 8 * total udp bytes / (last-first time)
  read thr <<< "$(tshark -r "$P" -Y 'udp.port==5002' -T fields -e frame.time_relative -e udp.length 2>/dev/null | \
    awk 'NR==1{t0=$1} {b+=$2; t1=$1} END{if(NR>1 && t1>t0) printf "%.2f", 8*b/(t1-t0)/1e6; else print "0"}')"
  gcc=$(awk -F, 'NF>10{s+=$(NF); n++} END{if(n)printf "%.0f", s/n}' "$REPO/server/logs/srv_gcc.csv" 2>/dev/null)
  frames=$(ls "$REPO/player/received_frames/"*.png 2>/dev/null | wc -l)
  printf "%-10s %14s %14s %8s\n" "$game" "${thr:-?}" "${gcc:-?}" "$frames"
done
