#!/usr/bin/env bash
# Setup of the secret store for management-api. It follows
# JengaCore/pm4ml-docker-compose docker/vault/vault-init.sh: AppRole, PKI at pki/,
# KV v1 at secrets/, roles client-cert-role and server-cert-role, and the DFSP's
# root CA in pki/. It runs from the operator's machine with `kubectl exec`, so
# the cluster needs no extra RBAC.
#
#   NS=<namespace> RELEASE=<release> STORE=vault|openbao DFSP_ID=<dfsp id> ./secret-store/init.sh
#
# Output:
#   ./<ns>-<release>-store-init.json  unseal/recovery keys + root token. Move it to
#                                     escrow NOW and delete the file.
#   Secret <release>-vault-approle    role-id / secret-id for management-api
#   Secret <release>-store-backup     role-id / secret-id for backup.sh (snapshots only)
#
# Re-running on an initialised store (ROOT_TOKEN=... or the init file present):
# creates what is missing (the CA on a store set up before it was added, the
# backup AppRole) and rotates both AppRole secret-ids. It never replaces an
# existing CA: that would mean onboarding the DFSP again.
# INIT_ONLY=1: initialise (and unseal) only, before restoring a snapshot.
set -euo pipefail
NS="${NS:?set NS}"
STORE="${STORE:-vault}"
R="${RELEASE:-pm4ml}"   # Helm release name
POD="${POD:-$R-vault-0}"
case "$STORE" in
  vault)   BIN=vault; ADDR_VAR=VAULT_ADDR; DATA=/vault/file ;;
  openbao) BIN=bao;   ADDR_VAR=BAO_ADDR;   DATA=/openbao/file ;;
  *) echo "STORE must be vault or openbao" >&2; exit 1 ;;
esac
OUT="${OUT:-./${NS}-${R}-store-init.json}"
# Subject of the DFSP CA created in pki/ (it signs the DFSP's callback server
# certificate and the hub's client certificate for this DFSP). Required: the
# CA is created once and uploaded to the hub's MCM, so a wrong subject sticks.
if [ "${INIT_ONLY:-}" != 1 ]; then
  DFSP_ID="${DFSP_ID:?set DFSP_ID (the DFSP id; used as the CA subject)}"
fi
CA_CN="${CA_CN:-${DFSP_ID:-} CA}"
CA_ORG="${CA_ORG:-${DFSP_ID:-}}"

kx() { kubectl -n "$NS" exec -i "$POD" -c vault -- env "$ADDR_VAR=http://127.0.0.1:8200" "$@"; }
# Pass the token on stdin, never on a command line.
kxt() { local tok="$1"; shift; printf '%s' "$tok" | kubectl -n "$NS" exec -i "$POD" -c vault -- \
          sh -c "export $ADDR_VAR=http://127.0.0.1:8200 ${BIN^^}_TOKEN=\$(cat); $*"; }

echo "Waiting for $POD..."
kubectl -n "$NS" wait --for=condition=PodScheduled "pod/$POD" --timeout=300s >/dev/null
until kx "$BIN" status -format=json >/dev/null 2>&1 || [ $? -eq 2 ]; do sleep 3; done

initialized=$(kx "$BIN" status -format=json 2>/dev/null | sed -n 's/.*"initialized": *\([a-z]*\).*/\1/p' || true)

if [ "$initialized" != "true" ]; then
  # A volume holding data of the file backend (the storage these manifests used
  # before Raft) looks uninitialised to Raft. Initialising it would create a new
  # CA, i.e. onboard the DFSP again. Migrate instead (docs/PRODUCTION.md).
  if kx sh -c "[ -d $DATA/core ] || [ -d $DATA/logical ]" 2>/dev/null; then
    echo "$DATA holds file-backend data from an earlier version. Do not initialise:" >&2
    echo "migrate it to Raft first (docs/PRODUCTION.md, 'Upgrading a store from file to Raft')." >&2
    exit 1
  fi
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
  # Restoring a backup (secret-store/backup.sh restore): only an initialised,
  # unsealed store is needed; the snapshot brings back the configuration and
  # the AppRoles, so do not overwrite their Secrets.
  if [ "${INIT_ONLY:-}" = 1 ]; then echo "INIT_ONLY: store initialised, nothing configured"; exit 0; fi
  ROOT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['root_token'])" "$OUT")
else
  ROOT="${ROOT_TOKEN:-}"
  if [ -z "$ROOT" ]; then
    [ -s "$OUT" ] || { echo "Store already initialised: set ROOT_TOKEN (or keep $OUT) to complete it / rotate the AppRoles" >&2; exit 1; }
    ROOT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['root_token'])" "$OUT")
  fi
fi

# Idempotent: every step checks before it writes, so this also completes a
# store set up by an earlier version of this script.
kxt "$ROOT" "
  set -e
  $BIN auth list -format=json | grep -q '\"approle/\"' || $BIN auth enable approle
  mounts=\$($BIN secrets list -format=json)
  echo \"\$mounts\" | grep -q '\"pki/\"' || { $BIN secrets enable -path=pki pki; $BIN secrets tune -max-lease-ttl=97600h pki; }
  echo \"\$mounts\" | grep -q '\"secrets/\"' || $BIN secrets enable -path=secrets -version=1 kv
  # The DFSP's own CA. management-api starts by reading the CA already in
  # pki/ (getPrebuiltCA) and uploads it to the hub's MCM; with none it
  # uploads an empty CA and every certificate it issues later fails with
  # \"no default issuer\". Created only if absent: never replaced.
  if [ -z \"\$($BIN read -field=certificate pki/cert/ca 2>/dev/null)\" ]; then
    $BIN write -field=certificate pki/root/generate/internal common_name=\"$CA_CN\" \
      organization=\"$CA_ORG\" ttl=97600h >/dev/null
    echo 'created the DFSP CA: $CA_CN'
  fi
  for r in client-cert-role server-cert-role; do
    $BIN write pki/roles/\$r allow_any_name=true allow_subdomains=true allow_localhost=true \
      enforce_hostnames=false require_cn=false max_ttl=97600h >/dev/null
  done
  $BIN policy write management-api - <<'EOF'
path \"pki/*\"     { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\",\"sudo\"] }
path \"secrets/*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] }
path \"sys/mounts\"   { capabilities = [\"read\"] }
path \"sys/mounts/*\" { capabilities = [\"create\",\"read\",\"update\"] }
EOF
  $BIN write auth/approle/role/management-api policies=management-api \
    secret_id_ttl=0 token_ttl=1h token_max_ttl=24h >/dev/null
  # backup.sh: online Raft snapshots and nothing else (it cannot restore).
  $BIN policy write store-backup - <<'EOF'
path \"sys/storage/raft/snapshot\" { capabilities = [\"read\"] }
EOF
  $BIN write auth/approle/role/store-backup policies=store-backup \
    secret_id_ttl=0 token_ttl=15m token_max_ttl=1h >/dev/null
"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
approle_secret() { # role, secret name
  kxt "$ROOT" "$BIN read -field=role_id auth/approle/role/$1/role-id" > "$tmp/role-id"
  kxt "$ROOT" "$BIN write -f -field=secret_id auth/approle/role/$1/secret-id" > "$tmp/secret-id"
  kubectl -n "$NS" create secret generic "$2" \
    --from-file=role-id="$tmp/role-id" --from-file=secret-id="$tmp/secret-id" \
    --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
}
approle_secret management-api "$R-vault-approle"
approle_secret store-backup "$R-store-backup"
echo "Secrets $R-vault-approle and $R-store-backup written. Restart management-api if it is running:"
echo "  kubectl -n $NS rollout restart deploy/$R-management-api"
