#!/bin/sh
# untar.sh <tar> <dest dir>: extract a plain ustar archive (files and directories) without tar, for the board's BusyBox (no tar applet).
t=$1; d=$2; blk=0
mkdir -p "$d"
while :; do
  dd if="$t" of=/tmp/h bs=512 skip=$blk count=1 2>/dev/null
  name=$(dd if=/tmp/h bs=1 count=100 2>/dev/null | tr -d '\0')
  [ -z "$name" ] && break
  mode=$(dd if=/tmp/h bs=1 skip=100 count=7 2>/dev/null)
  size=$(printf %d 0$(dd if=/tmp/h bs=1 skip=124 count=11 2>/dev/null))
  type=$(dd if=/tmp/h bs=1 skip=156 count=1 2>/dev/null)
  blk=$(expr $blk + 1)
  case $type in
    5) mkdir -p "$d/$name" ;;
    0|"") nb=$(expr \( $size + 511 \) / 512)
       mkdir -p "$d/$(dirname "$name")"
       if [ $size -eq 0 ]; then : > "$d/$name"; else dd if="$t" bs=512 skip=$blk count=$nb 2>/dev/null | head -c $size > "$d/$name"; fi
       chmod $mode "$d/$name"; blk=$(expr $blk + $nb) ;;
    *) echo "untar: unsupported type $type for $name"; exit 1 ;;
  esac
done
echo "untar done $t blocks=$blk"
