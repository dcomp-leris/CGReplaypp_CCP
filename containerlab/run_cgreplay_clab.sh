#!/usr/bin/env bash
# Full limited run: CGReplay through the 4-endpoint Containerlab topology, capture
# PCAP at the switch sniffer, then post_process (VMAF) + merge the dataset.
# Run as root.  Env: GAME (config), BN=middle|lastmile, B=rate
set -u
REPO=/home/hugo/CGSynth/CGReplay
LAB=cgreplay4
SYS=/usr/bin/python3
VENV=/home/hugo/venv/bin/python3
FFMPEG=/home/hugo/CGSynth/tools/ffmpeg-vmaf/ffmpeg
CFG="$REPO/config/config.yaml"
PCAP=/tmp/clab_capture.pcap
MERGED=/tmp/clab_merged.csv
pid(){ docker inspect -f '{{.State.Pid}}' "clab-$LAB-$1" 2>/dev/null; }
H0=$(pid h0); H1=$(pid h1); S2=$(pid s2)
[ -z "$H0" ] || [ -z "$H1" ] && { echo "topologia nao esta no ar"; exit 1; }

cp "$CFG" "$CFG.clabbak"; trap 'mv "$CFG.clabbak" "$CFG" 2>/dev/null' EXIT
sed -i 's/^    server_IP: .*/    server_IP: "10.0.1.10"/' "$CFG"
sed -i 's/^    player_IP: .*/    player_IP: "10.0.2.10"/' "$CFG"
sed -i 's/QUIC: True/QUIC: False/; s/SCReAM: True/SCReAM: False/' "$CFG"
sed -i 's/^    live_watching: .*/    live_watching: False/' "$CFG"
rm -f "$REPO/player/received_frames/"*.png 2>/dev/null

# --- sniffer: capture RTP at s2 egress toward the gamer (s2-eth2) ---
rm -f "$PCAP"
nsenter -t "$S2" -n tcpdump -i eth2 -w "$PCAP" udp port 5002 >/dev/null 2>&1 &
TCPD=$!; sleep 1

echo "launching gamer (h1) ..."
nsenter -t "$H1" -n sh -c "cd $REPO/player && DISPLAY=:0 PYTHONUNBUFFERED=1 $SYS cg_gamer1.py" > /tmp/clab_gamer.log 2>&1 &
for i in $(seq 1 60); do grep -q RTP_RECEIVER_READY /tmp/clab_gamer.log 2>/dev/null && break; sleep 0.5; done
sleep 1
echo "launching server (h0) ..."
nsenter -t "$H0" -n sh -c "cd $REPO/server && DISPLAY=:0 PYTHONUNBUFFERED=1 $SYS cg_server1.py" > /tmp/clab_server.log 2>&1
sleep 3
kill -INT $TCPD 2>/dev/null; sleep 2

n=$(ls "$REPO/player/received_frames/"*.png 2>/dev/null | wc -l)
echo "=== frames recebidos: $n ; pcap: $(du -h $PCAP 2>/dev/null | cut -f1) ==="

# --- VMAF (post_process) ---
cd "$REPO"
rm -rf player/received_frames_rtp; cp -r player/received_frames player/received_frames_rtp
CGREPLAY_FFMPEG=$FFMPEG $VENV tools/post_process.py --mode rtp 2>&1 | tail -2

# --- merge (features de rede + VMAF por frame, chave rtp_timestamp) ---
$SYS tools/merge_dataset.py --pcap "$PCAP" --rtpmap server/logs/srv_rtp_map.csv \
     --vmaf player/logs/metrics_rtp.csv --port 5002 --out "$MERGED"
echo "=== amostra do dataset mesclado ==="
awk -F, 'NR==1 || ($4!="" && $12!="")' "$MERGED" | head -8
