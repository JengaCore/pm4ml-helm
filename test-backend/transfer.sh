#!/bin/sh
# TEST ONLY. One payment through a DFSP's SDK outbound API (inside the cluster),
# the way a core connector drives it: lookup + quote, accept the quote, transfer.
#   transfer.sh <sdk-outbound-url> <from-msisdn> <to-msisdn> <amount> <currency> [homeTransactionId]
# Prints: <transferId> <final state> <seconds>
set -u
SDK="$1"; FROM="$2"; TO="$3"; AMT="$4"; CUR="$5"; HTX="${6:-$(cat /proc/sys/kernel/random/uuid)}"
start=$(date +%s)
r=$(curl -s --max-time 90 -X POST "$SDK/transfers" -H 'Content-Type: application/json' -d "{
  \"homeTransactionId\":\"$HTX\",\"from\":{\"idType\":\"MSISDN\",\"idValue\":\"$FROM\"},
  \"to\":{\"idType\":\"MSISDN\",\"idValue\":\"$TO\"},\"amountType\":\"SEND\",\"currency\":\"$CUR\",
  \"amount\":\"$AMT\",\"transactionType\":\"TRANSFER\",\"note\":\"pm4ml-helm validation\"}")
tid=$(printf '%s' "$r" | sed -n 's/.*"transferId":"\([^"]*\)".*/\1/p' | head -n1)
st=$(printf '%s' "$r" | sed -n 's/.*"currentState":"\([^"]*\)".*/\1/p' | head -n1)
if [ "$st" = "WAITING_FOR_PARTY_ACCEPTANCE" ]; then
  r=$(curl -s --max-time 90 -X PUT "$SDK/transfers/$tid" -H 'Content-Type: application/json' -d '{"acceptParty":true}')
  st=$(printf '%s' "$r" | sed -n 's/.*"currentState":"\([^"]*\)".*/\1/p' | head -n1)
fi
if [ "$st" = "WAITING_FOR_QUOTE_ACCEPTANCE" ]; then
  r=$(curl -s --max-time 90 -X PUT "$SDK/transfers/$tid" -H 'Content-Type: application/json' -d '{"acceptQuote":true}')
  st=$(printf '%s' "$r" | sed -n 's/.*"currentState":"\([^"]*\)".*/\1/p' | head -n1)
fi
echo "${tid:--} ${st:-ERROR} $(( $(date +%s) - start ))s"
[ "$st" = "COMPLETED" ] || { printf '%s\n' "$r" | head -c 800 >&2; echo >&2; exit 1; }
