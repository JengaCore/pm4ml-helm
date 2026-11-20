#!/bin/sh
# TEST ONLY. Runs in the tester pod. N payments through the SDK connector's /send, C at a time.
#   send.sh <connector-sidecar-url> <from-msisdn> <to-msisdn> <currency> <N> <C> <outfile>
# Prints how many ended COMMITTED.
set -u
URL="$1"; FROM="$2"; TO="$3"; CUR="$4"; N="$5"; C="$6"; OUT="$7"; : > "$OUT"
one() {
  r=$(curl -s -m 90 "$URL/send" -H 'content-type: application/json' -d "{\"from\":{\"idType\":\"MSISDN\",\"idValue\":\"$FROM\"},\"to\":{\"idType\":\"MSISDN\",\"idValue\":\"$TO\"},\"amount\":{\"amount\":\"1\",\"currency\":\"$CUR\"}}")
  st=$(printf '%s' "$r" | grep -o '"transferState":"[A-Z_]*"' | head -n1)
  echo "${st:-ERROR $(printf '%s' "$r" | head -c 200)}" >> "$OUT"
}
i=0
while [ "$i" -lt "$N" ]; do j=0
  while [ "$j" -lt "$C" ] && [ "$i" -lt "$N" ]; do one & i=$((i+1)); j=$((j+1)); done; wait
done
echo "$(grep -c '"transferState":"COMMITTED"' "$OUT") / $N COMMITTED"
