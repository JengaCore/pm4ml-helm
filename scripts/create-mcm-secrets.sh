#!/usr/bin/env bash
# DEFAULT (MCM) mode: creates the Secrets PM4ML needs before `helm install`.
#
#   NS=<namespace> ./scripts/create-mcm-secrets.sh     # prompts for the client secret
#
#   pm4ml-mcm      client-secret  the DFSP's client secret from the hub operator
#                                 (Compose: AUTH_CLIENT_SECRET in Vault shared-secrets)
#   pm4ml-runtime  ilp-secret     random, created once and kept across re-runs
#   pm4ml-tls      empty placeholder files: management-api pushes the real
#                  certificates over the control channel (Compose ships the
#                  same empty files in docker/sdk-scheme-adapter/)
#   pm4ml-jws      throwaway key, replaced the same way
set -euo pipefail
NS="${NS:?set NS}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
apply() { kubectl -n "$NS" create secret generic "$@" --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null; }
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

if [ -n "${CLIENT_SECRET_FILE:-}" ]; then cp "$CLIENT_SECRET_FILE" "$tmp/cs"
elif ! exists pm4ml-mcm || [ "${ROTATE_CLIENT_SECRET:-}" = 1 ]; then
  read -rsp "Client secret from the hub operator: " cs; echo; printf '%s' "$cs" > "$tmp/cs"; unset cs
fi
[ -s "$tmp/cs" ] 2>/dev/null && apply pm4ml-mcm --from-file=client-secret="$tmp/cs"

exists pm4ml-runtime || { openssl rand -hex 32 | tr -d '\n' > "$tmp/ilp"; apply pm4ml-runtime --from-file=ilp-secret="$tmp/ilp"; }

if ! exists pm4ml-tls; then
  for f in hub-ca.pem client.pem client.key in-ca.pem server.pem server.key; do : > "$tmp/$f"; done
  args=(); for f in hub-ca.pem client.pem client.key in-ca.pem server.pem server.key; do args+=("--from-file=$f=$tmp/$f"); done
  apply pm4ml-tls "${args[@]}"
fi
exists pm4ml-jws || { openssl genrsa -out "$tmp/jws.key" 2048 2>/dev/null; apply pm4ml-jws --from-file=jws-signing.key="$tmp/jws.key"; }
kubectl -n "$NS" get secret pm4ml-mcm pm4ml-runtime pm4ml-tls pm4ml-jws
