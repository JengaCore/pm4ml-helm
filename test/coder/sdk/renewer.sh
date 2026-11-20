#!/bin/sh
# TEST ONLY. The single renewer of a cluster-mode DFSP (mcm enrol --watch --k8s-secret),
# run from the Coder workspace through `kubectl proxy`: the workspace's service account
# may not create the Role an in-cluster renewer needs (deploy/kubernetes/cluster.yaml in
# the SDK has that Deployment). Same code path.
#   SDK=~/switch-connector-sdk NS=default DFSP_ID=sdkhelm02 CALLBACK_HOST=... sh renewer.sh
#   MCM_RENEW_DAYS=400 sh renewer.sh   # forces a renewal request (a 90-day certificate is always "due")
# Keeps Secrets $DFSP_ID-tls, $DFSP_ID-tls-jws-peers and $DFSP_ID-tls-state. Stop it with Ctrl-C;
# the client secret is read from the cluster into a 0600 file and shredded on exit.
set -eu
: "${SDK:?}" "${NS:?}" "${DFSP_ID:?}" "${CALLBACK_HOST:?}"
SWITCH_DOMAIN="${SWITCH_DOMAIN:-uat.sandbox.jengacore.com}"
W=$(mktemp -d); chmod 700 "$W"; umask 077
kubectl -n "$NS" get secret "$DFSP_ID-mcm" -o jsonpath='{.data.client-secret}' | base64 -d > "$W/mcm-secret"
kubectl proxy --port=8011 >/dev/null 2>&1 & PROXY=$!
trap 'kill $PROXY 2>/dev/null; shred -u "$W/mcm-secret" 2>/dev/null; find "$W" -name "*.key*" -exec shred -u {} \; 2>/dev/null; rm -rf "$W"' EXIT INT TERM
sleep 2
export DFSP_ID SWITCH_DOMAIN CALLBACK_HOST
MCM_OUT="$W/work" MCM_K8S_SECRET="$DFSP_ID-tls" MCM_K8S_API=http://127.0.0.1:8011 MCM_K8S_NAMESPACE="$NS" \
MCM_CLIENT_SECRET_FILE="$W/mcm-secret" MCM_RENEW_DAYS="${MCM_RENEW_DAYS:-30}" \
node "$SDK/packages/cli/dist/index.js" mcm enrol --watch 30
