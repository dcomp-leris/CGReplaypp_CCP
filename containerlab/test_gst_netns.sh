#!/usr/bin/env bash
# Feasibility test: run host GStreamer inside the h0/h1 container network
# namespaces (nsenter -n). Proves we can stream RTP through the 4-endpoint
# Containerlab topology without a custom image. Run as root.
set -u
LAB=cgreplay4
pid() { docker inspect -f '{{.State.Pid}}' "clab-$LAB-$1" 2>/dev/null; }
H0=$(pid h0); H1=$(pid h1)
if [ -z "$H0" ] || [ -z "$H1" ]; then
  echo "topologia nao esta no ar. Rode: cd ~/cc-lab && sudo containerlab deploy -t cgreplay4.clab.yml && sudo ~/cc-lab/apply_dualq.sh"
  exit 1
fi
echo "h0 pid=$H0  h1 pid=$H1"
OUT=/tmp/gstns; rm -f ${OUT}_*.png

# receiver in h1 netns (gamer side), saves decoded frames as PNG
nsenter -t "$H1" -n gst-launch-1.0 -q \
  udpsrc port=5002 timeout=10000000000 ! "application/x-rtp,clock-rate=(int)90000,payload=96" ! \
  rtpjitterbuffer latency=200 ! rtph264depay ! avdec_h264 ! videoconvert ! \
  pngenc ! multifilesink location=${OUT}_%03d.png > /tmp/gstns_rx.log 2>&1 &
RX=$!
sleep 2

echo "=== streaming h0 -> h1 (10.0.2.10) por s1-s2 ==="
nsenter -t "$H0" -n gst-launch-1.0 -q \
  videotestsrc num-buffers=120 is-live=true ! video/x-raw,width=320,height=240,framerate=30/1 ! \
  x264enc tune=zerolatency speed-preset=ultrafast key-int-max=3 ! h264parse ! \
  rtph264pay config-interval=-1 ! udpsink host=10.0.2.10 port=5002 > /tmp/gstns_tx.log 2>&1
sleep 12
kill $RX 2>/dev/null

n=$(ls ${OUT}_*.png 2>/dev/null | wc -l)
echo "frames decodificados em h1: $n  (esperado ~120)"
