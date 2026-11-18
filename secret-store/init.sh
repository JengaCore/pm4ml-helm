#!/usr/bin/env bash
# One-time setup of the secret store for management-api. It follows
# JengaCore/pm4ml-docker-compose docker/vault/vault-init.sh: AppRole, PKI at pki/,
# KV v1 at secrets/, roles client-cert-role and server-cert-role.
# It runs from the operator's machine with `kubectl exec`, so the cluster
# needs no extra RBAC.
#
#   NS=<namespace> STORE=vault|openbao ./secret-store/init.sh
#
# Output:
#   ./<ns>-store-init.json   unseal/recovery keys + root token. Move it to your
#                            password manager or escrow NOW and delete the file.
#   Secret pm4ml-vault-approle  role-id / secret-id for management-api
# Re-running on an initialised store only rotates the AppRole secret-id.
set -euo pipefail
NS="${NS:?set NS}"
STORE="${STORE:-vault}"
POD="${POD:-pm4ml-vault-0}"
case "$STORE" in
  vault)   BIN=vault; ADDR_VAR=VAULT_ADDR ;;
  openbao) BIN=bao;   ADDR_VAR=BAO_ADDR ;;
  *) echo "STORE must be vault or openbao" >&2; exit 1 ;;
esac
OUT="${OUT:-./${NS}-store-init.json}"

kx() { kubectl -n "$NS" exec -i "$POD" -c vault -- env "$ADDR_VAR=http://127.0.0.1:8200" "$@"; }
# Pass the token on stdin, never on a command line.
kxt() { local tok="$1"; shift; printf '%s' "$tok" | kubectl -n "$NS" exec -i "$POD" -c vault -- \
          sh -c "export $ADDR_VAR=http://127.0.0.1:8200 ${BIN^^}_TOKEN=\$(cat); $*"; }

echo "Waiting for $POD..."
kubectl -n "$NS" wait --for=condition=PodScheduled "pod/$POD" --timeout=300s >/dev/null
until kx "$BIN" status -format=json >/dev/null 2>&1 || [ $? -eq 2 ]; do sleep 3; done

initialized=$(kx "$BIN" status -format=json 2>/dev/null | sed -n 's/.*"initialized": *\([a-z]*\).*/\1/p' || true)

if [ "$initialized" != "true" ]; then
  [ -e "$OUT" ] && { echo "$OUT exists; refusing to overwrite it" >&2; exit 1; }
  umask 077
  if [ "$STORE" = vault ]; then
    kx vault operator init -key-shares=5 -key-threshold=3 -format=json > "$OUT"
    for i in 0 1 2; do
      key=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['unseal_keys_b64'][$i])" "$OUT")
      printf '%s' "$key" | kubectl -n "$NS" exec -i "$POD" -c vault -- \
        sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal "$(cat)" >/dev/null'
    done
  else
    # Static seal: recovery keys instead of unseal keys; it unseals itself.
    kx bao operator init -recovery-shares=5 -recovery-threshold=3 -format=json > "$OUT"
    until kx bao status -format=json 2>/dev/null | grep -q '"sealed": *false'; do sleep 2; done
  fi
  echo "Initialised. Keys and root token: $OUT  <- move to escrow and delete"
  ROOT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['root_token'])" "$OUT")

  kxt "$ROOT" "
    set -e
    $BIN auth enable approle
    $BIN secrets enable -path=pki pki
    $BIN secrets tune -max-lease-ttl=97600h pki
    $BIN secrets enable -path=secrets -version=1 kv
    for r in client-cert-role server-cert-role; do
      $BIN write pki/roles/\$r allow_any_name=true allow_subdomains=true allow_localhost=true \
        enforce_hostnames=false require_cn=false max_ttl=97600h >/dev/null
    done
    $BIN policy write pm4ml-management-api - <<'EOF'
path \"pki/*\"     { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\",\"sudo\"] }
path \"secrets/*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] }
path \"sys/mounts\"   { capabilities = [\"read\"] }
path \"sys/mounts/*\" { capabilities = [\"create\",\"read\",\"update\"] }
EOF
    $BIN write auth/approle/role/pm4ml-management-api policies=pm4ml-management-api \
      secret_id_ttl=0 token_ttl=1h token_max_ttl=24h
  "
else
  ROOT="${ROOT_TOKEN:-}"
  if [ -z "$ROOT" ]; then
    [ -s "$OUT" ] || { echo "Store already initialised: set ROOT_TOKEN (or keep $OUT) to rotate the AppRole" >&2; exit 1; }
    ROOT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['root_token'])" "$OUT")
  fi
fi

ROLE_ID=$(kxt "$ROOT" "$BIN read -field=role_id auth/approle/role/pm4ml-management-api/role-id")
SECRET_ID=$(kxt "$ROOT" "$BIN write -f -field=secret_id auth/approle/role/pm4ml-management-api/secret-id")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '%s' "$ROLE_ID" > "$tmp/role-id"; printf '%s' "$SECRET_ID" > "$tmp/secret-id"
kubectl -n "$NS" create secret generic pm4ml-vault-approle \
  --from-file=role-id="$tmp/role-id" --from-file=secret-id="$tmp/secret-id" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
echo "Secret pm4ml-vault-approle written. Restart management-api if it is running:"
echo "  kubectl -n $NS rollout restart deploy/pm4ml-management-api"
