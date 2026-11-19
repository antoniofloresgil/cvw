#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Put staged benchmarks on the board's Linux through the console UART, with no SD card reader (the board's BusyBox has no tar, so untar.sh extracts them).
#   upload-stage.sh <staging dir on this PC> <log> <fifo> <remote dir> <benchmark>...
# <log> and <fifo> are the ones of `uart-upload.py bridge`; the board must be at a shell prompt and idle (the console loses characters while a benchmark runs).
# For each benchmark: tar, uart-upload.py put (sha256-checked), untar.sh on the board, then the md5 of the sorted md5 list of its files on the board is compared with the PC's.
# Any failing step stops the script.  The first run also puts untar.sh on the board.
set -eo pipefail
stage=${1:?staging dir}
log=${2:?log}
fifo=${3:?fifo}
remote=${4:?remote dir on the board, e.g. /mnt/d/stage}
shift 4
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
send() { printf '%s\n' "$1" > "$fifo"; }
wait_for() {  # wait_for <extended regex> <seconds>: look for it in what the board printed after this point
    local start=$1 re=$2 secs=$3 t=$((SECONDS + $3))
    while [ $SECONDS -lt $t ]; do
        tail -c +$((start + 1)) "$log" | tr -d '\r' | grep -a -E -q "$re" && return 0
        sleep 2
    done
    return 1
}
python3 "$here/uart-upload.py" put "$here/untar.sh" /tmp/untar.sh "$log" "$fifo" > /dev/null
for b in "$@"; do
    echo "== $b $(date +%T)"
    tar -C "$stage" -cf "$tmp/$b.tar" "$b"
    python3 "$here/uart-upload.py" put "$tmp/$b.tar" "/tmp/$b.tar" "$log" "$fifo" | tail -1
    want=$(cd "$stage" && find "$b" -type f | LC_ALL=C sort | xargs md5sum | md5sum | cut -d' ' -f1)
    mark=$(stat -c%s "$log")
    send "mkdir -p $remote && sh /tmp/untar.sh /tmp/$b.tar $remote && rm /tmp/$b.tar && sync && cd $remote && echo CHK $b \$(find $b -type f | LC_ALL=C sort | xargs md5sum | md5sum | cut -d' ' -f1)"
    wait_for "$mark" "^CHK $b [0-9a-f]{32}" 7200 || { echo "no answer from the board for $b"; exit 1; }
    got=$(tail -c +$((mark + 1)) "$log" | tr -d '\r' | grep -a -E -o "^CHK $b [0-9a-f]{32}" | tail -1 | cut -d' ' -f3)
    [ "$got" = "$want" ] || { echo "md5 of $b differs: board $got, PC $want"; exit 1; }
    rm -f "$tmp/$b.tar"
    echo "ok $b"
done
