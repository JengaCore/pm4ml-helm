# Where PM4ML keeps its keys: Vault, OpenBao, managed services, or Kubernetes Secrets

This page answers one question from DFSPs: "do we have to run Vault?"

## What actually needs a secret store

Only **management-api** needs one, and only in MCM mode (the default). It talks to the store
through the Vault HTTP API, using `node-vault` inside `@pm4ml/mcm-client`. These
are all the calls it makes (from `mcm-client` `src/lib/vault/index.ts`, checked
2026-11):

| Purpose | Vault API |
|---|---|
| Log in | `auth/kubernetes/login` or `auth/approle/login` |
| Mount engines on first boot | `sys/mounts` (PKI + KV) |
| Create the DFSP CA | `pki/root/generate/exported`, `pki/config/ca`, `pki/ca/pem`, `pki/ca_chain`, `DELETE pki/root` |
| Server certificate for callbacks | `pki/issue/<server role>` |
| Sign the hub's client CSR | `pki/sign/<client role>` |
| State machine and keys | KV **v1** read/write/delete under `secrets/` |
| Health | `sys/health` |

The sdk-scheme-adapter never calls Vault. In **static mode**
(`values-static.yaml`) nothing calls Vault, and every key lives in a Kubernetes
Secret. That is how the original ThitsaX repo runs.

## The options

| Option | Code change | Who unseals | Status in this repo |
|---|---|---|---|
| **Default: HashiCorp Vault 1.13.3**, AppRole (`secret-store/vault`) | none | a person, 3 of 5 keys, after every restart (`secret-store/unseal.sh`) | = JengaCore/pm4ml-docker-compose. **Tested 2026-11-18** |
| **B. OpenBao**, static-key seal (`secret-store/openbao`) | none (same API) | itself, from a Kubernetes Secret | **Tested 2026-11-18**, including a restart that unsealed itself. Recommended when nobody can be on call to unseal |
| **A. Static mode**, Kubernetes Secrets only (`values-static.yaml`) | none | n/a | Renders; manual onboarding |
| **C. Vault with cloud-KMS auto-unseal** (AWS KMS, Azure Key Vault) | none | the KMS | Add a `seal` block to the default's config |
| **D. Managed Vault** (HCP Vault Dedicated) | none | the provider | Point `VAULT_ENDPOINT` at it, AppRole |
| **E. Cloud secret managers** (AWS Secrets Manager, Azure Key Vault) | **yes** | the provider | Not possible today. See below |
| **F. A Kubernetes-Secret backend inside mcm-client** | **yes**, in a fork | n/a | Possible later. See below |

Both tested stores use the same Service name (`pm4ml-vault`) and the same
`secret-store/init.sh`, so switching between them changes no Helm value.

### A. Static mode (no secret store)

What you lose compared with MCM mode:

- **Onboarding is manual.** The DFSP generates its CSR. The hub operator signs it
  and sends back the certificate. The DFSP's CA and server certificate are
  exchanged by hand.
- **Renewal is manual.** Nothing watches expiry. The certificate shipped in the
  upstream repo had already expired (2026-07-14) when this was written.
- **Peer JWS keys are a values file.** Every new DFSP on the scheme means an
  edit and `helm upgrade` at every other static-mode DFSP. The hub key (`Hub`)
  must be in the list, or every transfer where this DFSP is the payee times out
  after the ledger has already settled it.

This works for a pilot. It does not scale to a scheme with many participants.

### B. OpenBao

OpenBao is the Linux Foundation fork of Vault 1.14 (MPL-2.0). Its API is
Vault's, so management-api needs **no change**. Set `VAULT_ENDPOINT` to the
OpenBao service and nothing else changes.

With the default Vault, someone has to unseal it after every restart. That was
the main operational problem on our Compose sandbox DFSPs. OpenBao removes it
in either of two ways:

- **Static-key auto-unseal** (`seal "static"`, built in since OpenBao 2.4;
  this repo pins 2.6.5). The unseal key is a 32-byte file, mounted from a
  Kubernetes Secret.
  No cloud KMS is needed, so it runs the same way on-prem, AWS, AKS or Linode.
  The trade-off: whoever can read that Secret can unseal the store. In
  practice this is the same trust boundary as "secrets are Kubernetes
  Secrets", but data at rest stays encrypted, and you keep PKI and audit.
  **Back up the key. If it is lost, the data cannot be recovered.**
- **Cloud KMS auto-unseal**: AWS KMS or Azure Key Vault. Use it where a KMS is
  already in place. From OpenBao 2.7, KMS seals are external plugins, so pin the
  version you test with.

Sizing: one replica with integrated storage (Raft) on a 1 Gi volume, ~100 MiB RAM. Back it up with `secret-store/backup.sh` (Raft snapshots). It holds one
DFSP's CA and keys. HA is optional, because management-api is only on the
onboarding and renewal path, not on the transfer path. With the store down,
transfers keep running on the certificates already loaded.

`secret-store/init.sh` does the setup for both stores, with AppRole as in
Compose. If you prefer Kubernetes auth (no secret-id to rotate), the equivalent
is below. It needs a ClusterRoleBinding to `system:auth-delegator`:

```bash
bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc
bao policy write pm4ml - <<'EOF'
path "pki/*"     { capabilities = ["create","read","update","delete","list","sudo"] }
path "secrets/*" { capabilities = ["create","read","update","delete","list"] }
path "sys/mounts/*" { capabilities = ["create","read","update"] }
path "sys/mounts"   { capabilities = ["read"] }
EOF
bao write auth/kubernetes/role/pm4ml \
  bound_service_account_names=pm4ml-management-api \
  bound_service_account_namespaces=pm4ml policies=pm4ml ttl=1h
bao secrets enable -path=secrets -version=1 kv
bao secrets enable pki && bao secrets tune -max-lease-ttl=87600h pki
bao write pki/roles/server-cert-role allow_any_name=true max_ttl=17520h
bao write pki/roles/client-cert-role allow_any_name=true max_ttl=17520h
```

### C/D. Vault, self-hosted or managed

The same setup and the same values. On AWS or AKS, configure KMS auto-unseal.
A managed Vault outside the cluster has to use AppRole, because Kubernetes auth
needs the store to reach the cluster's API server. The AppRole files are then
mounted into management-api.

### E. Cloud secret managers: why not today

AWS Secrets Manager, Azure Key Vault and GCP Secret Manager store secrets.
They do not implement the Vault PKI API. management-api needs to **create a CA
and sign arbitrary CSRs** with it. Of these, only AWS Private CA does that, and it is billed per CA. Azure Key
Vault can hold certificates but cannot act as your CA. Supporting
them means writing a new backend in `mcm-client`, the same work as F, plus
cloud-specific code.

Use them *around* PM4ML instead: the External Secrets Operator can sync the
static-mode Secrets (`pm4ml-tls`, `pm4ml-jws`, `pm4ml-runtime`) or the OpenBao
unseal key from AWS Secrets Manager or Azure Key Vault. That works with no code
change.

### F. A Kubernetes-Secret backend in mcm-client (possible fork work)

The Vault surface above is small, about eight operations. A backend that does
the PKI with Node's `crypto` (as `switch-connector-sdk`'s `mcm enrol` already
does) and keeps state in one Kubernetes Secret would give MCM-mode automation
without any secret store. The cost is a fork of `@pm4ml/mcm-client` and of
`management-api` that someone has to maintain. Do it only if B turns out to be
a real barrier for DFSPs. Otherwise B gives the same result with no code.

### The other route: switch-connector-sdk

For a DFSP that does not want PM4ML at all, JengaCore's `switch-connector-sdk`
onboards through the same MCM flow without Vault. Its keys are files, and in
Kubernetes they are Secrets. See its `docs/secrets.md`.
