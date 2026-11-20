#!/usr/bin/env bash
# Vault option only: unseal after a restart (3 of the 5 keys from init).
# OpenBao with the static seal never needs this.
#
#   NS=<namespace> ./secret-store/unseal.sh          # prompts for 3 keys
#   NS=<namespace> KEYS_FILE=./<ns>-store-init.json ./secret-store/unseal.sh
set -euo pipefail
NS="${NS:?set NS}"
POD="${POD:-${RELEASE:-pm4ml}-vault-0}"
unseal() {
  printf '%s' "$1" | kubectl -n "$NS" exec -i "$POD" -c vault -- \
    sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal "$(cat)" >/dev/null'
}
if [ -n "${KEYS_FILE:-}" ]; then
  for i in 0 1 2; do
    unseal "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['unseal_keys_b64'][$i])" "$KEYS_FILE")"
  done
else
  for i in 1 2 3; do read -rsp "Unseal key $i: " k; echo; unseal "$k"; done
fi
kubectl -n "$NS" exec "$POD" -c vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status' | grep -E 'Sealed|Initialized'
