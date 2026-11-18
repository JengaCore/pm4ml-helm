#!/usr/bin/env bash
# Online backup and restore of the DFSP's secret store (Raft snapshot).
# The store holds the DFSP CA key, the client/server/JWS private keys and the
# enrolment state: lose it without a backup and the DFSP onboards again
# (new CA, new CSR, hub signs again, peers learn a new JWS key).
#
#   NS=<ns> RELEASE=<release> STORE=vault|openbao ./secret-store/backup.sh save    <file>
#   NS=<ns> RELEASE=<release> STORE=vault|openbao ./secret-store/backup.sh restore <file>
#
# The snapshot is encrypted by the store's barrier key, so it is useless
# without the unseal material (Vault: 3 of 5 keys; OpenBao static seal: the
# key in Secret <release>-openbao-seal). Keep the two in different places.
# Production: run "save" on a schedule and ship the file to object storage
# (S3 with SSE-KMS, versioning and object lock), see docs/PRODUCTION.md.
#
# restore: on an EMPTY store (after a lost volume). Initialise it first with
# secret-store/init.sh (throwaway keys), then restore: the snapshot brings back
# the original data, keys and AppRole. For OpenBao the seal key Secret must be
# the original one. Afterwards restart management-api.
set -euo pipefail
NS="${NS:?set NS}"; R="${RELEASE:-pm4ml}"; STORE="${STORE:-vault}"
ACTION="${1:?save|restore}"; FILE="${2:?file}"
case "$STORE" in vault) BIN=vault; ADDR=VAULT_ADDR ;; openbao) BIN=bao; ADDR=BAO_ADDR ;; *) echo "STORE: vault|openbao" >&2; exit 1 ;; esac
POD="$R-vault-0"
# Token: ROOT_TOKEN (or TOKEN_FILE). Snapshots need sudo on sys/storage/raft.
TOKEN="${ROOT_TOKEN:-$( [ -n "${TOKEN_FILE:-}" ] && cat "$TOKEN_FILE" )}"
[ -n "$TOKEN" ] || { echo "set ROOT_TOKEN or TOKEN_FILE (a token with sudo on sys/storage/raft/snapshot)" >&2; exit 1; }
ex() { kubectl -n "$NS" exec -i "$POD" -c vault -- "$@"; }
case "$ACTION" in
  save)
    umask 077
    printf '%s' "$TOKEN" | ex sh -c "export $ADDR=http://127.0.0.1:8200 ${BIN^^}_TOKEN=\$(cat); $BIN operator raft snapshot save /tmp/snap && cat /tmp/snap && rm -f /tmp/snap" > "$FILE"
    echo "saved $(wc -c < "$FILE") bytes to $FILE"
    ;;
  restore)
    kubectl -n "$NS" cp "$FILE" "$POD:/tmp/snap" -c vault
    printf '%s' "$TOKEN" | ex sh -c "export $ADDR=http://127.0.0.1:8200 ${BIN^^}_TOKEN=\$(cat); $BIN operator raft snapshot restore -force /tmp/snap; rm -f /tmp/snap"
    echo "restored. Vault: unseal with the ORIGINAL keys (secret-store/unseal.sh). OpenBao: unseals itself."
    echo "then: kubectl -n $NS rollout restart deploy/$R-management-api"
    ;;
  *) echo "save|restore" >&2; exit 1 ;;
esac
