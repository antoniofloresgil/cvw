#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Build a disk image of the board's SD card without root: the same GPT layout as ../sdcard/flash-sd.sh (1 device tree, 2 OpenSBI fw_jump, 3 Linux Image,
# 4 ext4 data partition) with the SPEC staging directory (stage.py output) and the measurement scripts in the data partition.
# The image is then written to the card with one command (the only step that needs root, and it replaces everything on the card):
#   sudo dd if=<image> of=/dev/sdX bs=4M conv=fsync status=progress
# On the board the data partition is /dev/mmcblk0p4; mount it at /mnt/d and run
#   sh /mnt/d/stage/perf-run.sh /mnt/d/stage /mnt/d/results <benchmark>...
# Usage: make-sd-image.sh <buildroot images dir> <device tree .dtb> <stage dir> <data partition size: MiB | auto | card:<device or size in bytes>> <image file>
# auto (the quick one) makes the data partition twice the stage directory plus 2 GiB for the results, so dd writes only that much; the rest of a
# larger card stays unused.  With card:/dev/sdX the data partition takes everything after the other three, so the image is exactly as large as the
# card (the card must be at least that large; GPT is not moved) and dd has to write it all, zeros included: tens of minutes for a 64 GB card.
# The stage directory holds SPEC CPU 2026 content: the image is for the licensee's own cards, never for git or publication.

set -euo pipefail
[ $# -eq 5 ] || { sed -n '2,13p' "$0" | sed 's/^# \?//'; exit 1; }
IMAGES=$1 DTB=$2 STAGE=$3 DATA_MIB=$4 OUT=$5
FW_JUMP=$IMAGES/fw_jump.bin KERNEL=$IMAGES/Image
for f in "$FW_JUMP" "$KERNEL" "$DTB"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }; done
[ -d "$STAGE" ] || { echo "missing $STAGE" >&2; exit 1; }

sectors() { echo $(( ($(stat -c %s "$1") + 511) / 512 )); }  # file size in 512-byte blocks, rounded up, as flash-sd.sh takes it from ls
DST_SIZE=$(sectors "$DTB")
FW_SIZE=$(sectors "$FW_JUMP")
KERNEL_SIZE=$(sectors "$KERNEL")
FW_START=$((34 + DST_SIZE))
KERNEL_START=$((FW_START + FW_SIZE))
FS_START=$((KERNEL_START + KERNEL_SIZE))
if [ "$DATA_MIB" = auto ]; then
    DATA_MIB=$(( $(du -sm --apparent-size "$STAGE" | cut -f1) * 2 + 2048 ))
fi
if [[ $DATA_MIB == card:* ]]; then
    CARD=${DATA_MIB#card:}
    [ -b "$CARD" ] && CARD=$(lsblk -bdn -o SIZE "$CARD")
    FS_SECTORS=$(( CARD / 512 - FS_START - 34 ))
    FS_SECTORS=$(( FS_SECTORS / 8 * 8 ))  # whole 4 KiB blocks
else
    FS_SECTORS=$((DATA_MIB * 2048))
fi
TOTAL=$((FS_START + FS_SECTORS + 34))  # the backup GPT takes the last 33 sectors
[[ $DATA_MIB == card:* ]] && TOTAL=$((CARD / 512))  # as large as the card, so the backup GPT is in the card's last sectors

rm -f "$OUT"
truncate -s $((TOTAL * 512)) "$OUT"
sgdisk -g --clear --set-alignment=1 \
    --new=1:34:+"$DST_SIZE" --change-name=1:'fdt' \
    --new=2:"$FW_START":+"$FW_SIZE" --change-name=2:'opensbi' --typecode=2:2E54B353-1271-4842-806F-E436D6AF6985 \
    --new=3:"$KERNEL_START":+"$KERNEL_SIZE" --change-name=3:'kernel' \
    --new=4:"$FS_START":-0 --change-name=4:'filesystem' \
    "$OUT" > /dev/null

put() { dd if="$1" of="$OUT" bs=512 seek="$2" conv=notrunc status=none; }
put "$DTB" 34
put "$FW_JUMP" "$FW_START"
put "$KERNEL" "$KERNEL_START"

# The data partition: <stage dir> as /stage, a README, owned by root.
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
cp -a "$STAGE" "$ROOT/stage"
cat > "$ROOT/README.txt" << 'EOF'
Data partition of the Wally SPEC board card (mount it: mkdir -p /mnt/d; mount /dev/mmcblk0p4 /mnt/d).
  /mnt/d/stage      one directory per benchmark (executable, inputs, cmds), the counter groups (events) and perf-run.sh
  /mnt/d/results    written by perf-run.sh: <benchmark>.<command>.g<group>.{csv,out,err,info}
Run as root with the board idle, for example (PERF_GROUPS=1 for the first group only, PERF_SKIP=1 to skip it):
  PERF_GROUPS=1 sh /mnt/d/stage/perf-run.sh /mnt/d/stage /mnt/d/results 707.ntest_r
The board has 512 MiB: 782.lbm_r and 749.fotonik3d_r do not fit at the test size.
The console UART drops characters while a benchmark runs: type slowly or wait for the end.
EOF
BLOCKS_K=$((FS_SECTORS / 2))
mke2fs -q -F -t ext4 -E "offset=$((FS_START * 512)),lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0" -d "$ROOT" "$OUT" "${BLOCKS_K}k"
sgdisk -p "$OUT" | tail -6
echo "image: $OUT ($(du -h --apparent-size "$OUT" | cut -f1) apparent, $(du -h "$OUT" | cut -f1) on disk)"
