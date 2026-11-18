#!/bin/sh
# TEST ONLY. N payments through one DFSP's SDK, C at a time (inside the cluster).
#   load.sh <sdk-outbound-url> <from> <to> <amount> <currency> <N> <C> <outfile>
# One line per payment in <outfile>: "<transferId> <state> <seconds>".
set -u
SDK="$1"; FROM="$2"; TO="$3"; AMT="$4"; CUR="$5"; N="$6"; C="$7"; OUT="$8"
: > "$OUT"
i=0
while [ "$i" -lt "$N" ]; do
  j=0
  while [ "$j" -lt "$C" ] && [ "$i" -lt "$N" ]; do
    sh /tmp/transfer.sh "$SDK" "$FROM" "$TO" "$AMT" "$CUR" >> "$OUT" 2>/dev/null &
    i=$((i + 1)); j=$((j + 1))
  done
  wait
done
echo "$(grep -c ' COMPLETED ' "$OUT") / $N COMPLETED"
