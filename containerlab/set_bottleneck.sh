#!/usr/bin/env bash
# Select which link is the shaped/measured bottleneck and set its rate B.
# DualQ (dualpi2) is already present on both s1->s2 and s2->h1; this only changes
# the htb rate so exactly one link is constrained per run.
#   sudo ./set_bottleneck.sh middle 20mbit     # shape s1->s2, last-mile free
#   sudo ./set_bottleneck.sh lastmile 20mbit   # shape s2->h1, middle free
set -euo pipefail
LAB=cgreplay4
TARGET=${1:?usage: $0 middle|lastmile <rate>}
B=${2:?usage: $0 middle|lastmile <rate>}
S1=clab-${LAB}-s1; S2=clab-${LAB}-s2; HI=1000mbit
case "$TARGET" in
  middle)
    docker exec "$S1" tc class change dev eth2 parent 1: classid 1:10 htb rate "$B" ceil "$B"
    docker exec "$S2" tc class change dev eth2 parent 1: classid 1:10 htb rate "$HI" ceil "$HI"
    echo "bottleneck = MIDDLE (s1->s2) at $B ; last-mile unconstrained" ;;
  lastmile)
    docker exec "$S2" tc class change dev eth2 parent 1: classid 1:10 htb rate "$B" ceil "$B"
    docker exec "$S1" tc class change dev eth2 parent 1: classid 1:10 htb rate "$HI" ceil "$HI"
    echo "bottleneck = LAST-MILE (s2->h1) at $B ; middle unconstrained" ;;
  *) echo "usage: $0 middle|lastmile <rate>"; exit 1 ;;
esac
