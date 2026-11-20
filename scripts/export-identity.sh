#!/usr/bin/env bash
# Exports a DFSP's identity from its secret store into files: the certificates
# and private keys management-api enrolled with MCM, and the peer JWS keys.
#
#   NS=<ns> RELEASE=<release> STORE=vault|openbao OUT=<dir> ./scripts/export-identity.sh
#
# Uses for the result:
#   - an encrypted, off-cluster copy of the identity (e.g. AWS Secrets Manager,
#     docs/PRODUCTION.md), so losing the store does not mean onboarding again;
#   - static mode (TLS_DIR=<dir> ./scripts/create-static-secrets.sh, and
#     <dir>/values-jws-peers.yaml), e.g. to run without management-api.
#
# It reads with management-api's own AppRole (Secret <release>-vault-approle),
# never with a root token. <dir> holds private keys: create it on an encrypted
# disk, never commit it, delete it when done.
set -euo pipefail
NS="${NS:?set NS}"; R="${RELEASE:-pm4ml}"; STORE="${STORE:-vault}"; OUT="${OUT:?set OUT}"
case "$STORE" in vault) BIN=vault; ADDR=VAULT_ADDR ;; openbao) BIN=bao; ADDR=BAO_ADDR ;; *) echo "STORE: vault|openbao" >&2; exit 1 ;; esac
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
umask 077; mkdir -p "$OUT/peers"

g() { kubectl -n "$NS" get secret "$R-vault-approle" -o jsonpath="{.data.$1}" | base64 -d; }
creds="$(printf '%s\n%s' "$(g role-id)" "$(g secret-id)")"
state="$(printf '%s' "$creds" | kubectl -n "$NS" exec -i "$R-vault-0" -c vault -- sh -c "
  export $ADDR=http://127.0.0.1:8200
  read -r rid; read -r sid
  export ${BIN^^}_TOKEN=\$($BIN write -field=token auth/approle/login role_id=\"\$rid\" secret_id=\"\$sid\")
  $BIN read -format=json secrets/state-machine-state")"

printf '%s' "$state" | OUT="$OUT" python3 -c '
import json, os, sys
d = json.load(sys.stdin)["data"]
v = d.get("value", d)
v = json.loads(v) if isinstance(v, str) else v
c = v["state"]["context"]["connectorConfig"]
out = os.environ["OUT"]
files = {
    "hub-ca.pem": c["outbound"]["tls"]["creds"]["ca"],     # verifies the hub (fspiop.)
    "client.pem": c["outbound"]["tls"]["creds"]["cert"],   # our client cert, signed by the hub CA
    "client.key": c["outbound"]["tls"]["creds"]["key"],
    "in-ca.pem":  c["inbound"]["tls"]["creds"]["ca"],      # our CA: verifies the hub client cert
    "server.pem": c["inbound"]["tls"]["creds"]["cert"],    # our callback server cert
    "server.key": c["inbound"]["tls"]["creds"]["key"],
    "jws.key":    c["jwsSigningKey"],
}
for name, pem in files.items():
    pem = pem if isinstance(pem, str) else "".join(pem)
    open(os.path.join(out, name), "w").write(pem if pem.endswith("\n") else pem + "\n")
peers = c.get("peerJWSKeys", {})
lines = ["scheme-adapter:", "  sdk-scheme-adapter-api-svc:", "    config:", "      jwsVerificationKeys:"]
for k, pem in sorted(peers.items()):
    open(os.path.join(out, "peers", k + ".pem"), "w").write(pem)
    lines.append("        %s: |" % k)
    lines += ["          " + l for l in pem.strip().splitlines()]
open(os.path.join(out, "values-jws-peers.yaml"), "w").write("\n".join(lines) + "\n")
print("exported %d files and %d peer keys (%s) to %s" % (len(files), len(peers), ", ".join(sorted(peers)), out))
'
for f in client server; do
  openssl x509 -in "$OUT/$f.pem" -noout -subject -enddate | tr '\n' ' '; echo
done
