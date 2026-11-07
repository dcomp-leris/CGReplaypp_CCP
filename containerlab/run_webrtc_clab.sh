#!/usr/bin/env bash
# Run the alireza-branch WebRTC (RTP + GCC + TWCC/RFC8888 feedback) through the
# Containerlab topology via nsenter. Run as root.  Arg: twcc|rfc8888|none
set -u
REPO=/home/hugo/CGSynth/CGReplaypp
LAB=cgreplay4; SYS=/usr/bin/python3; CFG="$REPO/config/config.yaml"
FB="${1:-twcc}"; PCAP=/tmp/clab_webrtc.pcap
pid(){ docker inspect -f '{{.State.Pid}}' "clab-$LAB-$1" 2>/dev/null; }
H0=$(pid h0); H1=$(pid h1); S2=$(pid s2)
[ -z "$H0" ] || [ -z "$H1" ] && { echo "topologia nao no ar"; exit 1; }

cp "$CFG" "$CFG.clabbak"; trap 'mv "$CFG.clabbak" "$CFG" 2>/dev/null' EXIT
sed -i 's/^    server_IP: .*/    server_IP: "10.0.1.10"/' "$CFG"
sed -i 's/^    player_IP: .*/    player_IP: "10.0.2.10"/' "$CFG"
sed -i 's/QUIC: True/QUIC: False/; s/SCReAM: True/SCReAM: False/; s/RoQ: True/RoQ: False/' "$CFG"
sed -i 's/^    live_watching: .*/    live_watching: False/' "$CFG"
rm -f "$REPO/player/received_frames/"*.png 2>/dev/null

rm -f "$PCAP"; nsenter -t "$S2" -n tcpdump -i eth2 -w "$PCAP" udp >/dev/null 2>&1 & TCPD=$!; sleep 1
echo "WebRTC server ($FB) in h0 ..."
nsenter -t "$H0" -n sh -c "cd $REPO/server && CGREPLAY_CC_FEEDBACK=$FB DISPLAY=:0 PYTHONUNBUFFERED=1 $SYS cg_server1.py" > /tmp/clab_wsrv.log 2>&1 &
sleep 1
echo "WebRTC gamer in h1 ..."
nsenter -t "$H1" -n sh -c "cd $REPO/player && CGREPLAY_CC_FEEDBACK=$FB DISPLAY=:0 PYTHONUNBUFFERED=1 $SYS cg_gamer1.py" > /tmp/clab_wgam.log 2>&1 &
for i in $(seq 1 90); do grep -q "RTP streaming complete" /tmp/clab_wgam.log 2>/dev/null && break; sleep 1; done
sleep 2; kill -INT $TCPD 2>/dev/null; sleep 1

n=$(ls "$REPO/player/received_frames/"*.png 2>/dev/null | wc -l)
echo "=== frames recebidos: $n ; feedback=$FB ; pcap: $(du -h $PCAP 2>/dev/null|cut -f1) ==="
echo "--- srv_gcc.csv (feedback funcionando?) ---"; tail -3 "$REPO/server/logs/srv_gcc.csv" 2>/dev/null || echo "(sem srv_gcc.csv)"
echo "--- gamer log ---"; tail -5 /tmp/clab_wgam.log
echo "--- server log ---"; tail -5 /tmp/clab_wsrv.log
