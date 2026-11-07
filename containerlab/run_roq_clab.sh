#!/usr/bin/env bash
# RoQ (RTP over QUIC datagrams) through the Containerlab topology via nsenter.
# Run as root. Uses the alireza-branch roq_sender/roq_receiver (venv: aioquic, PyAV).
set -u
REPO=/home/hugo/CGSynth/CGReplaypp
LAB=cgreplay4; VENV=/home/hugo/venv/bin/python3; CFG="$REPO/config/config.yaml"
PCAP=/tmp/clab_roq.pcap
pid(){ docker inspect -f '{{.State.Pid}}' "clab-$LAB-$1" 2>/dev/null; }
H0=$(pid h0); H1=$(pid h1); S2=$(pid s2)
{ [ -z "$H0" ] || [ -z "$H1" ]; } && { echo "topologia nao no ar"; exit 1; }

cp "$CFG" "$CFG.clabbak"; trap 'mv "$CFG.clabbak" "$CFG" 2>/dev/null' EXIT
sed -i 's/^    server_IP: .*/    server_IP: "10.0.1.10"/' "$CFG"
sed -i 's/^    player_IP: .*/    player_IP: "10.0.2.10"/' "$CFG"
sed -i 's/QUIC: True/QUIC: False/; s/SCReAM: True/SCReAM: False/; s/RoQ: False/RoQ: True/' "$CFG"
sed -i 's/^    live_watching: .*/    live_watching: False/' "$CFG"
rm -f "$REPO/player/received_frames/"*.png 2>/dev/null

rm -f "$PCAP"; nsenter -t "$S2" -n tcpdump -i eth2 -w "$PCAP" udp >/dev/null 2>&1 & TCPD=$!; sleep 1
echo "RoQ server (venv) in h0 ..."
nsenter -t "$H0" -n sh -c "cd $REPO/server && DISPLAY=:0 PYTHONUNBUFFERED=1 $VENV cg_server1.py" > /tmp/clab_roqsrv.log 2>&1 &
sleep 1
echo "RoQ gamer (venv) in h1 ..."
nsenter -t "$H1" -n sh -c "cd $REPO/player && DISPLAY=:0 PYTHONUNBUFFERED=1 $VENV cg_gamer1.py" > /tmp/clab_roqgam.log 2>&1 &
# RoQ receiver prints "Receiver finished"; fall back to the RTP marker too.
for i in $(seq 1 120); do grep -qE "Receiver finished|RTP streaming complete" /tmp/clab_roqgam.log 2>/dev/null && break; sleep 1; done
sleep 2; kill -INT $TCPD 2>/dev/null; sleep 1

n=$(ls "$REPO/player/received_frames/"*.png 2>/dev/null | wc -l)
echo "=== RoQ: frames recebidos: $n ; pcap: $(du -h $PCAP 2>/dev/null|cut -f1) ==="
echo "--- gamer log ---"; tail -6 /tmp/clab_roqgam.log
echo "--- server log ---"; tail -6 /tmp/clab_roqsrv.log
