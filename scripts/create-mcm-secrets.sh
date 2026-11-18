#!/usr/bin/env bash
# DEFAULT (MCM) mode: creates the Secrets PM4ML needs before `helm install`.
#
#   NS=<namespace> ./scripts/create-mcm-secrets.sh     # prompts for the client secret
#
#   <release>-mcm      client-secret  the DFSP's client secret from the hub operator
#                                 (Compose: AUTH_CLIENT_SECRET in Vault shared-secrets)
#   <release>-runtime  ilp-secret     random, created once and kept across re-runs
#                      cache-url      Redis URL (CACHE_URL=...; default redis://<release>-redis:6379)
#   <release>-tls      empty placeholder files: management-api pushes the real
#                  certificates over the control channel (Compose ships the
#                  same empty files in docker/sdk-scheme-adapter/)
#   <release>-jws      throwaway key, replaced the same way
set -euo pipefail
NS="${NS:?set NS}"
R="${RELEASE:-pm4ml}"   # Helm release name; Secrets are named <release>-*
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
apply() { kubectl -n "$NS" create secret generic "$@" --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null; }
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

if [ -n "${CLIENT_SECRET_FILE:-}" ]; then cp "$CLIENT_SECRET_FILE" "$tmp/cs"
elif ! exists "$R"-mcm || [ "${ROTATE_CLIENT_SECRET:-}" = 1 ]; then
  read -rsp "Client secret from the hub operator: " cs; echo; printf '%s' "$cs" > "$tmp/cs"; unset cs
fi
[ -s "$tmp/cs" ] 2>/dev/null && apply "$R"-mcm --from-file=client-secret="$tmp/cs"

# <release>-runtime: the ILP secret (random once, then kept) and the Redis URL
# (CACHE_URL_FILE, else CACHE_URL, else the in-namespace redis/redis.yaml).
# The URL may hold a password or use rediss:// (TLS), so it lives here, not in values.
write_runtime() {
  ilp="$(kubectl -n "$NS" get secret "$R-runtime" -o jsonpath='{.data.ilp-secret}' 2>/dev/null | base64 -d || true)"
  [ -n "$ilp" ] || ilp="${ILP_SECRET:-$(openssl rand -hex 32)}"
  printf '%s' "$ilp" > "$tmp/ilp"
  if [ -n "${CACHE_URL_FILE:-}" ]; then cp "$CACHE_URL_FILE" "$tmp/cache-url"
  elif [ -n "${CACHE_URL:-}" ]; then printf '%s' "$CACHE_URL" > "$tmp/cache-url"
  else
    cur="$(kubectl -n "$NS" get secret "$R-runtime" -o jsonpath='{.data.cache-url}' 2>/dev/null | base64 -d || true)"
    printf '%s' "${cur:-redis://$R-redis:6379}" > "$tmp/cache-url"
  fi
  apply "$R-runtime" --from-file=ilp-secret="$tmp/ilp" --from-file=cache-url="$tmp/cache-url"
}
write_runtime

if ! exists "$R"-tls; then
  for f in hub-ca.pem client.pem client.key in-ca.pem server.pem server.key; do : > "$tmp/$f"; done
  args=(); for f in hub-ca.pem client.pem client.key in-ca.pem server.pem server.key; do args+=("--from-file=$f=$tmp/$f"); done
  apply "$R"-tls "${args[@]}"
fi
exists "$R"-jws || { openssl genrsa -out "$tmp/jws.key" 2048 2>/dev/null; apply "$R"-jws --from-file=jws-signing.key="$tmp/jws.key"; }
kubectl -n "$NS" get secret "$R"-mcm "$R"-runtime "$R"-tls "$R"-jws
