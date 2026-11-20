#!/bin/sh
# TEST ONLY. Move a single connector's enrolment (connector.yaml) to the renewer's
# $DFSP_ID-tls-state Secret, so the cluster carries on with the same DFSP CA and
# client certificate instead of enrolling again.
#   NS=default DFSP_ID=sdkhelm02 sh seed-renewer-state.sh
set -eu
: "${NS:?}" "${DFSP_ID:?}"
W=$(mktemp -d); chmod 700 "$W"; trap 'find "$W" -type f -exec shred -u {} \; ; rm -rf "$W"' EXIT
P=$(kubectl -n "$NS" get pods -l "dfsp=$DFSP_ID,app=switch-connector" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NS" exec "$P" -c mcm-watch -- tar -C /certs --exclude=.ready -cf - . | tar -C "$W" -xf -
args=""
for f in "$W"/*; do [ -f "$f" ] && args="$args --from-file=$(basename "$f")=$f"; done
for f in "$W"/jws-peers/*; do [ -f "$f" ] && args="$args --from-file=jws-peers__$(basename "$f")=$f"; done
# shellcheck disable=SC2086
kubectl -n "$NS" create secret generic "$DFSP_ID-tls-state" $args --dry-run=client -o yaml | kubectl -n "$NS" apply -f -
