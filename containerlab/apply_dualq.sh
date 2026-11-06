#!/usr/bin/env bash
# Load the L4S modules on the host and attach DualQ (dualpi2) on both switches.
# Run after `containerlab deploy -t cgreplay4.clab.yml`, as root.
set -u
modprobe sch_dualpi2 2>/dev/null || true
modprobe tcp_prague  2>/dev/null || true
for s in s1 s2; do
  docker exec "clab-cgreplay4-$s" tc qdisc replace dev eth2 parent 1:10 handle 20: dualpi2 target 15ms
done
echo "--- s1.eth2 ---"; docker exec clab-cgreplay4-s1 tc qdisc show dev eth2
echo "--- s2.eth2 ---"; docker exec clab-cgreplay4-s2 tc qdisc show dev eth2
