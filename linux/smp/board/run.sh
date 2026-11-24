#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# On the multicore board, as root (on the card: sh /mnt/d/stage/run.sh): the harts Linux brought up, then smpcheck.
cd "$(dirname "$0")"
echo "== harts"
cat /sys/devices/system/cpu/online; grep -c ^processor /proc/cpuinfo
dmesg | grep -i "smp:\|brought up\|hart"
echo "== smpcheck"
./smpcheck "$@"
echo "smpcheck exit $?"
