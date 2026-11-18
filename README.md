# PM4ML on Kubernetes

Helm deployment of Payment Manager for Mojaloop (PM4ML) for a DFSP joining a
jengacore switch. The defaults match
[JengaCore/pm4ml-docker-compose](https://github.com/JengaCore/pm4ml-docker-compose)
(MCM onboarding, Vault, mTLS and JWS on). Started from
[ThitsaX/pm4ml-deployment](https://github.com/ThitsaX/pm4ml-deployment); why it
changed is in [docs/REVIEW-2026-11.md](docs/REVIEW-2026-11.md).

| Doc | |
|---|---|
| [docs/PRODUCTION.md](docs/PRODUCTION.md) | keys and backups, load balancer and mTLS, AWS / Azure / on-prem reference |
| [docs/OPTIONS.md](docs/OPTIONS.md) | every default, its options, and where Helm differs from Compose |
| [docs/SECRET-BACKENDS.md](docs/SECRET-BACKENDS.md) | Vault, OpenBao, managed and cloud options |
| [docs/REVIEW-2026-11.md](docs/REVIEW-2026-11.md) | review of the ThitsaX repo |

## What runs

```mermaid
flowchart LR
  CBS[Core banking] -->|private network| CC[core connector :3003]
  CC --> SDK[sdk-scheme-adapter]
  SDK --> R[(Redis)]
  MA[management-api] -->|control channel: certs, JWS keys| SDK
  MA --> V[(Vault / OpenBao)]
  MA -->|CSRs, JWS key, endpoints| MCM[hub MCM]
  SDK -->|mTLS + JWS| HUB[hub fspiop.]
  HUB -->|mTLS callbacks| LB[ml-connect.: TLS passthrough] --> SDK
```

## Prerequisites

- Kubernetes 1.27+, Helm 3.10+, `kubectl`, `perl`, `openssl`, `python3`
- 2 small volumes (Vault 1 Gi, Redis 2 Gi) from the default StorageClass
- A way to publish `ml-connect.<your domain>` with **TLS passthrough**
  (`networking/`): an L4 load balancer, Istio `PASSTHROUGH`, or ingress-nginx
  started with `--enable-ssl-passthrough`
- Egress to `mcm.`, `keycloak.` and `fspiop.<switch domain>` on 443

## From the hub operator

1. Your DFSP id, created in MCM (the hub calls this "Add DFSP")
2. The client secret of that DFSP's Keycloak client
3. Switch domain, `API_TYPE`, currency

You give the hub: the callback host `ml-connect.<your domain>` and your egress IP(s).

## Install (default: MCM mode, Vault)

```bash
NS=dfsp                                   # any namespace you own
kubectl create namespace $NS               # if you may
helm repo add pm4ml https://pm4ml.github.io/mojaloop-payment-manager-helm/repo && helm repo update

# 1. Redis (production: redis/values-redis-ha.yaml, see the checklist) and the secret store
kubectl -n $NS apply -f redis/redis.yaml
kubectl -n $NS apply -f secret-store/vault/vault.yaml
NS=$NS STORE=vault DFSP_ID=<dfsp id> ./secret-store/init.sh   # writes ./$NS-store-init.json: move it to escrow

# 2. Secrets (prompts for the client secret)
NS=$NS ./scripts/create-mcm-secrets.sh

# 3. Values: copy, fill every CHANGE ME
cp helm-values/values-pm4ml.yaml helm-values/values-local.yaml && $EDITOR helm-values/values-local.yaml

# 4. PM4ML
helm upgrade --install pm4ml pm4ml/mojaloop-payment-manager --version 10.3.6 -n $NS \
  -f helm-values/values-local.yaml --post-renderer ./post-render/post-render.sh

# 5. Callback host (pick one of networking/*.yaml), then point DNS at it
kubectl -n $NS apply -f networking/loadbalancer.yaml
```

Then ask the hub operator to sign your enrolment in MCM. Nothing tells them to,
and until they do, the SDK has no client certificate.

`--post-renderer` is required on every install and upgrade. It mounts the
Secrets and reads env values from them, which the charts cannot do.

### OpenBao instead of Vault (unseals itself)

```bash
kubectl -n $NS create secret generic pm4ml-openbao-seal --from-file=unseal.key=<(openssl rand 32)
kubectl -n $NS get secret pm4ml-openbao-seal -o yaml > openbao-seal-BACKUP.yaml   # to escrow
kubectl -n $NS apply -f secret-store/openbao/openbao.yaml
NS=$NS STORE=openbao DFSP_ID=<dfsp id> ./secret-store/init.sh
```

Same Service name, so the Helm values do not change.

### Backups (both stores)

```bash
NS=$NS STORE=vault TOKEN_FILE=<root token file> ./secret-store/backup.sh save store.snap   # schedule it, ship off-cluster
NS=$NS STORE=openbao ./scripts/export-identity.sh                                          # OUT=<dir>: break-glass copy of the keys
```

What to keep where, and how to restore: [docs/PRODUCTION.md](docs/PRODUCTION.md).

### After a restart (Vault only)

```bash
NS=$NS ./secret-store/unseal.sh        # 3 of the 5 keys
```

management-api waits for the store. Transfers keep running on the certificates
already loaded.

### Static mode (no management-api, no Vault)

```bash
NS=$NS TLS_DIR=./tls ./scripts/create-static-secrets.sh      # see its header for the files
cp helm-values/values-jws-peers.example.yaml helm-values/values-jws-peers.yaml   # Hub + peers
helm upgrade --install pm4ml pm4ml/mojaloop-payment-manager --version 10.3.6 -n $NS \
  -f helm-values/values-local.yaml -f helm-values/values-static.yaml \
  -f helm-values/values-jws-peers.yaml --post-renderer ./post-render/post-render.sh
```

## Check

```bash
kubectl -n $NS get pods
kubectl -n $NS logs deploy/pm4ml-management-api | grep -E 'eventType|error' | tail
openssl s_client -connect ml-connect.<your domain>:443 -servername ml-connect.<your domain> </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer       # must be your MCM-issued server cert
```

| Symptom | Cause |
|---|---|
| management-api: `401 invalid_client` | DFSP not created in MCM yet, or wrong client secret |
| SDK restarts: `Validation keys must be supplied` | management-api has no peer JWS keys yet (see the row above) |
| `ipList[0].address should match pattern` | `WHITELIST_IP` must be bare IPv4 addresses, not CIDR |
| `DFSP_CLIENT_CERT: pending` | the hub has not signed your enrolment |
| `3101 Invalid accept header` | `API_TYPE` differs from the hub's |
| `JWS public key for 'Hub' not available` | the hub has not published its JWS key through MCM |

More failure modes: switch-iac `docs/DFSP-ONBOARDING.md`.

## Production checklist

| | Default here | Why |
|---|---|---|
| SDK replicas | 2, soft anti-affinity, PodDisruptionBudget `minAvailable: 1` | Replicas share state in Redis: any replica takes any callback |
| SDK stop | `preStop: sleep 35`, 60 s grace | Payments in flight finish before the pod stops (validated: 0 failures while pods were killed under load) |
| Redis | **`redis/values-redis-ha.yaml`** (3 Redis + Sentinel + HAProxy, AOF, PVC) | The single `redis/redis.yaml` is a single point of failure: a Redis crash failed 47 of 60 payments in flight |
| Secret store | Vault (= Compose) or OpenBao (unseals itself) | management-api is off the payment path: payments continue while it or the store is down (validated) |
| Resources | requests/limits on SDK, management-api, core connector | Sized from the load test; one SDK replica uses at most one core |
| Metrics | `prometheus.io/scrape` on the SDK (port 4004), `monitoring/podmonitor.yaml` | Alert examples in that file |
| Idempotency | **your core connector** must not resend a payment it already sent | The SDK does not de-duplicate on `homeTransactionId`: the same id sent twice is two payments (tested). It is idempotent per `transferId`. After any error, ask `GET /transfers/{transferId}` (it queries the hub) before retrying |
| Several DFSPs per namespace | `RELEASE=<name>` on the scripts, `scripts/for-release.sh` for manifests and values | Names follow the Helm release |

## Validation (2026-11-18, against sbx UAT, no switch change)

Two DFSPs from this chart on the Coder cluster, onboarded through MCM the Compose way (hub adds the DFSP in MCM, hands over the Keycloak client id and secret, signs the CSR; the hub reconciler wires the ledger):

| DFSP | Store | Redis | Callback |
|---|---|---|---|
| `pm4mlhelm01` | OpenBao 2.6.5, static seal | `redis/redis.yaml` (single) | `ml-connect.195-15-198-39.sslip.io` (L4 LB) |
| `pm4mlhelm02` | Vault 1.13.3, Shamir | `dandydeveloper/redis-ha` (3 + Sentinel + HAProxy) | `ml-connect.84-234-26-66.sslip.io` (L4 LB) |

ISO 20022, GMD, mTLS both ways, JWS signed and validated, test backend `test-backend/mojaloop-simulator.yaml`. Ledger positions were read from central-ledger after every step; they always matched the payments reported completed, except where noted.

| Test | Result |
|---|---|
| Enrolment through `/pm4mlapi` with the client id/secret (CA, CSR, JWS key, endpoints, hub CSR), CSR signed in MCM, reconciler wiring | ✓ both DFSPs |
| Send A→B and receive (B→A) | ✓ `COMPLETED` in 1–2 s, positions +7 / −7 |
| Same `homeTransactionId` sent twice | **two payments** (positions moved twice): see Idempotency above |
| `acceptQuote` replayed on a completed transfer | no new payment, positions unchanged |
| Load: 3 SDK replicas per DFSP, 150 + 150 payments, both directions at once, 20 concurrent | 300/300, p50 2 s, p95 4 s, ledger exact; callbacks spread over all replicas |
| One SDK pod per DFSP killed during 100 + 100 payments, without graceful stop | 196/200; one payment reported failed was committed. Fixed by the preStop hook: |
| Same, with preStop + 60 s grace | **200/200, ledger exact** |
| Both management-api scaled to 0, 30 + 30 payments | 60/60 |
| Redis-HA master killed during 60 payments | **60/60** |
| Single Redis crashed (AOF kept) during 60 payments | 13/60; SDKs reconnected by themselves. 3 transfers stayed `RESERVED` and expired: aborted, no money moved, positions balanced, nothing reserved |
| OpenBao process killed | unsealed itself, management-api reconnected |
| Vault process killed (sealed) | payments continued (10/10) while sealed; `unseal.sh`, management-api reconnected |
| Store lost (pod deleted with its data), restored from a Raft snapshot (`secret-store/backup.sh`) | OpenBao: same CA, no new enrolment in MCM, management-api resumed. Vault 1.13.3 on Raft: starts, snapshot saved |
| Store lost **without** a backup | the DFSP had to onboard again (new CA, hub signs again), and the hub's lookup service kept the old CA: callbacks failed (`1001`) until its pods restart. See docs/PRODUCTION.md |
| Static mode, identity exported from the store (`scripts/export-identity.sh`) into Kubernetes Secrets, no management-api | 20/20 sent and 20/20 received |
| Redis-HA with AUTH, URL with password in Secret `<release>-runtime` | 20/20 each way; unauthenticated access refused |
| Metrics on :4004 (`mojaloop_connector_outbound_*` counters and latency histograms, event-loop lag) | ✓ |

Not covered yet: a run on EKS/AKS, a managed Redis with TLS (`rediss://`), the redis-ha values with persistence/NetworkPolicy (rendered, failover tested without persistence because the test cluster's volume quota is full), structured JSON logs (`LOG_IS_JSON_OUTPUT` is read but not used by SDK v24.19.3).

## Operations

Each DFSP runs its own PM4ML. Logs, monitoring, backups and infrastructure
troubleshooting are the DFSP's job. Back up the store (or its unseal key) and
the namespace's Secrets off-cluster: losing the DFSP CA means onboarding again.
