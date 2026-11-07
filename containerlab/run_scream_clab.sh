#!/usr/bin/env bash
# SCReAM v2 through the Containerlab topology via nsenter.
# Run as root. System python + gstscream plugin (alireza branch).
set -u
REPO=/home/hugo/CGSynth/CGReplaypp
LAB=cgreplay4; SYS=/usr/bin/python3; CFG="$REPO/config/config.yaml"
PCAP=/tmp/clab_scream.pcap
SCREAM_PLUGIN=/home/hugo/CGSynth/scream/gstscream/target/debug
SCREAM_LIB=/home/hugo/CGSynth/scream/code/wrapper_lib
# sender.sh/receiver.sh need both endpoint IPs: the server (h0) streams RTP to the
# gamer (CGREPLAY_PLAYER_IP=10.0.2.10) and the gamer's screamrx sends RTCP feedback
# back to the server (CGREPLAY_SERVER_IP=10.0.1.10) on CGREPLAY_RTCP_PORT. Without
# the feedback channel screamtx runs open-loop and does no real rate control.
GST_ENV="GST_PLUGIN_PATH=$SCREAM_PLUGIN LD_LIBRARY_PATH=$SCREAM_LIB CGREPLAY_PLAYER_IP=10.0.2.10 CGREPLAY_SERVER_IP=10.0.1.10 CGREPLAY_RTCP_PORT=5004 CGREPLAY_ENCODER=h264"
pid(){ docker inspect -f '{{.State.Pid}}' "clab-$LAB-$1" 2>/dev/null; }
H0=$(pid h0); H1=$(pid h1); S2=$(pid s2)
{ [ -z "$H0" ] || [ -z "$H1" ]; } && { echo "topologia nao no ar"; exit 1; }

cp "$CFG" "$CFG.clabbak"; trap 'mv "$CFG.clabbak" "$CFG" 2>/dev/null' EXIT
sed -i 's/^    server_IP: .*/    server_IP: "10.0.1.10"/' "$CFG"
sed -i 's/^    player_IP: .*/    player_IP: "10.0.2.10"/' "$CFG"
sed -i 's/QUIC: True/QUIC: False/; s/RoQ: True/RoQ: False/; s/SCReAM: False/SCReAM: True/' "$CFG"
sed -i 's/^    live_watching: .*/    live_watching: False/' "$CFG"
rm -f "$REPO/player/received_frames/"*.png 2>/dev/null

rm -f "$PCAP"; nsenter -t "$S2" -n tcpdump -i eth2 -w "$PCAP" udp >/dev/null 2>&1 & TCPD=$!; sleep 1
echo "SCReAM server in h0 ..."
nsenter -t "$H0" -n sh -c "cd $REPO/server && $GST_ENV DISPLAY=:0 PYTHONUNBUFFERED=1 $SYS cg_server1.py" > /tmp/clab_scrsrv.log 2>&1 &
sleep 1
echo "SCReAM gamer in h1 ..."
nsenter -t "$H1" -n sh -c "cd $REPO/player && $GST_ENV DISPLAY=:0 PYTHONUNBUFFERED=1 $SYS cg_gamer1.py" > /tmp/clab_scrgam.log 2>&1 &
for i in $(seq 1 120); do grep -q "RTP streaming complete" /tmp/clab_scrgam.log 2>/dev/null && break; sleep 1; done
sleep 2; kill -INT $TCPD 2>/dev/null; sleep 1

n=$(ls "$REPO/player/received_frames/"*.png 2>/dev/null | wc -l)
echo "=== SCReAM: frames recebidos: $n ; pcap: $(du -h $PCAP 2>/dev/null|cut -f1) ==="
echo "--- gamer log ---"; tail -6 /tmp/clab_scrgam.log
echo "--- server log ---"; tail -6 /tmp/clab_scrsrv.log
