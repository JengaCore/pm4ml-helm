#!/usr/bin/env bash
# Online backup and restore of the DFSP's secret store (Raft snapshot).
# The store holds the DFSP CA key, the client/server/JWS private keys and the
# enrolment state: lose it without a backup and the DFSP onboards again
# (new CA, new CSR, hub signs again, peers learn a new JWS key).
#
#   NS=<ns> RELEASE=<release> STORE=vault|openbao ./secret-store/backup.sh save    <file>
#   NS=<ns> RELEASE=<release> STORE=vault|openbao ROOT_TOKEN=... ./secret-store/backup.sh restore <file>
#
# save logs in with the snapshot-only AppRole in Secret <release>-store-backup
# (init.sh creates it), so a scheduled job needs no root token. It can read a
# snapshot and nothing else. ROOT_TOKEN or TOKEN_FILE override it.
#
# The snapshot is encrypted by the store's barrier key, so it is useless
# without the unseal material (Vault: 3 of 5 keys; OpenBao static seal: the
# key in Secret <release>-openbao-seal). Keep the two in different places.
# Production: run "save" on a schedule and ship the file to object storage
# (S3 with SSE-KMS, versioning and object lock), see docs/PRODUCTION.md.
#
# restore: on an EMPTY store (after a lost volume). First INIT_ONLY=1
# secret-store/init.sh (throwaway keys), then restore with that init's root
# token: the snapshot brings back the original data, CA, keys and AppRoles.
# For OpenBao the seal key Secret must be the original one. Vault: unseal with
# the ORIGINAL keys afterwards. Then restart management-api.
set -euo pipefail
usage() { sed -n '2,24p' "$0" >&2; exit 1; }
NS="${NS:?set NS}"; R="${RELEASE:-pm4ml}"; STORE="${STORE:-vault}"
ACTION="${1:-}"; FILE="${2:-}"
[ -n "$ACTION" ] && [ -n "$FILE" ] || usage
case "$STORE" in vault) BIN=vault; ADDR=VAULT_ADDR ;; openbao) BIN=bao; ADDR=BAO_ADDR ;; *) echo "STORE: vault|openbao" >&2; exit 1 ;; esac
POD="$R-vault-0"
ex() { kubectl -n "$NS" exec -i "$POD" -c vault -- "$@"; }

TOKEN=""
if [ -n "${ROOT_TOKEN:-}" ]; then TOKEN="$ROOT_TOKEN"
elif [ -n "${TOKEN_FILE:-}" ]; then TOKEN="$(cat "$TOKEN_FILE")"
fi

case "$ACTION" in
  save)
    if [ -z "$TOKEN" ]; then
      g() { kubectl -n "$NS" get secret "$R-store-backup" -o jsonpath="{.data.$1}" | base64 -d; }
      rid="$(g role-id 2>/dev/null || true)"; sid="$(g secret-id 2>/dev/null || true)"
      [ -n "$rid" ] && [ -n "$sid" ] || { echo "no token: set ROOT_TOKEN/TOKEN_FILE, or run init.sh to create Secret $R-store-backup" >&2; exit 1; }
      TOKEN="$(printf '%s\n%s\n' "$rid" "$sid" | ex sh -c "export $ADDR=http://127.0.0.1:8200; read -r a; read -r b; $BIN write -field=token auth/approle/login role_id=\"\$a\" secret_id=\"\$b\"")"
    fi
    umask 077
    printf '%s' "$TOKEN" | ex sh -c "export $ADDR=http://127.0.0.1:8200 ${BIN^^}_TOKEN=\$(cat); $BIN operator raft snapshot save /tmp/snap >/dev/null && cat /tmp/snap; rm -f /tmp/snap" > "$FILE"
    [ -s "$FILE" ] || { echo "snapshot is empty" >&2; exit 1; }
    echo "saved $(wc -c < "$FILE") bytes to $FILE"
    ;;
  restore)
    [ -n "$TOKEN" ] || { echo "restore needs ROOT_TOKEN (or TOKEN_FILE): the root token of the INIT_ONLY init" >&2; exit 1; }
    kubectl -n "$NS" cp "$FILE" "$POD:/tmp/snap" -c vault
    printf '%s' "$TOKEN" | ex sh -c "export $ADDR=http://127.0.0.1:8200 ${BIN^^}_TOKEN=\$(cat); $BIN operator raft snapshot restore -force /tmp/snap; rm -f /tmp/snap"
    echo "restored. Vault: unseal with the ORIGINAL keys (secret-store/unseal.sh). OpenBao: unseals itself."
    echo "then: kubectl -n $NS rollout restart deploy/$R-management-api"
    ;;
  *) usage ;;
esac
