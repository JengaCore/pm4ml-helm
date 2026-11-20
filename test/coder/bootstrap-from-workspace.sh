#!/bin/sh
# TEST ONLY. The chart's bootstrap Job needs a Role, which a Coder workspace's service
# account may not create. This renders the Job's own script and runs it from the
# workspace, through a port-forward to the store: same script, same result.
#   bootstrap-from-workspace.sh <namespace> <release> <values-file> [store: openbao|vault]
# Run it after `helm install` (with bootstrap.enabled=false), once the store pod runs.
# Idempotent: run it again after every helm upgrade that changes the store.
set -eu
NS="$1"; R="$2"; VALUES="$3"; STORE="${4:-openbao}"
HERE=$(cd "$(dirname "$0")" && pwd); CHART="$HERE/../../charts/pm4ml-dfsp"
T=$(mktemp -d); trap 'kill "${PF:-0}" 2>/dev/null || true; rm -rf "$T"' EXIT
helm template "$R" "$CHART" -n "$NS" -f "$VALUES" --set bootstrap.enabled=true --set restore.enabled=false \
  --show-only templates/bootstrap.yaml > "$T/rendered.yaml"
# The script is the ConfigMap's bootstrap.sh block, indented by four spaces.
awk '/^  bootstrap\.sh: \|/{f=1; next} f && (/^[^ ]/ || /^  [^ ]/){f=0} f{sub(/^    /, ""); print}' "$T/rendered.yaml" > "$T/bootstrap.sh"
[ -s "$T/bootstrap.sh" ] || { echo "no bootstrap.sh in the rendered chart" >&2; exit 1; }
kubectl -n "$NS" port-forward "pod/$R-$STORE-0" 18299:8200 >/dev/null 2>&1 & PF=$!
sleep 3
# Point the script at the port-forward, and its kubectl at the namespace.
sed -i "s#A=\"http://$R-$STORE:8200\"#A=\"http://127.0.0.1:18299\"#" "$T/bootstrap.sh"
{ echo "kubectl() { command kubectl -n '$NS' \"\$@\"; }"; cat "$T/bootstrap.sh"; } > "$T/run.sh"
HOME="$T" sh "$T/run.sh"
