# Defaults and options

The defaults are what [JengaCore/pm4ml-docker-compose](https://github.com/JengaCore/pm4ml-docker-compose)
runs, so a DFSP gets the same behaviour on Compose and on Kubernetes. This page
lists each choice, its default, the options, and where the Helm deployment
deliberately differs from Compose.

## Choices

| Choice | Default (= Compose) | Options |
|---|---|---|
| Onboarding | **MCM**: management-api enrols with the hub, renews certificates, fetches peer JWS keys | Static (`values-static.yaml`): certificates and keys by hand |
| Secret store | **HashiCorp Vault 1.13.3**, AppRole, PKI `pki/`, KV v1 `secrets/` | OpenBao 2.6.5 with static seal (unseals itself); Vault with KMS seal; managed Vault. See [SECRET-BACKENDS.md](SECRET-BACKENDS.md) |
| Redis | **one Redis**, no password | Here with AOF persistence and a NetworkPolicy (`redis/redis.yaml`). Or any Redis 6+: managed, or `redis/values-redis-ha.yaml` |
| API | **`fspiop`**, ILP v4 | `iso20022`: set `API_TYPE` and point the four endpoints at `extapi.<switch domain>` |
| SDK image | **v24.19.3** | Change `scheme-adapter…image.tag`, together with the hub |
| management-api image | **7.0.0** | |
| Callback host | **`ml-connect.<pm4ml domain>`**, mTLS terminated by the SDK (Compose: HAProxy SSL passthrough) | Istio `PASSTHROUGH`, ingress-nginx `--enable-ssl-passthrough`, or an L4 `LoadBalancer` Service (`networking/`) |
| FSPIOP token | **Keycloak `dfsps` realm**, client = DFSP id | |
| Auto-accept | **party: yes, quotes: no, participants PUT: yes** | |
| Portal (UI, experience-api, Keycloak) | **on** in Compose | **off here**. The chart's portal components are older than Compose's (UI 1.19.0 vs 1.20.0, experience-api 3.1.1 vs infitx 3.2.2) and need their own Keycloak. Enable after testing them |
| TTK | profile in Compose | off; use the hub's TTK |

## Where Helm differs from Compose, and why

| | Compose | Here | Why |
|---|---|---|---|
| `ILP_SECRET` | not set, so the SDK default (`mojaloop-sdk`) is used and is the same for every DFSP | random per install, from Secret `pm4ml-runtime` | A secret known to everyone lets the hub or the payer compute fulfilments the payee never produced |
| `FX_TRANSFERS_ENPOINT` | typo in docker-compose.yaml and .env.example; the SDK reads `FX_TRANSFERS_ENDPOINT`, so the value is ignored | `FX_TRANSFERS_ENDPOINT` | Report upstream to JengaCore/pm4ml-docker-compose |
| Redis persistence | none (`FLUSHALL` is a recovery step) | AOF every second | A restart must not orphan in-flight transfers into hub timeouts |
| App secrets | Vault `shared-secrets/pm4ml` (KV v2), rendered by vault-agent into an env file | Kubernetes Secrets (`pm4ml-mcm`, `pm4ml-runtime`) | Kubernetes already has a secret object; no agent needed |
| Vault root token | kept in `/vault/initial-keys` | in `<ns>-store-init.json`, to move to escrow | Same contents, one explicit hand-off |
| Store init | `init-vault` container | `secret-store/init.sh` via `kubectl exec` | No in-cluster RBAC needed. Like Compose it creates the DFSP CA in `pki/` (management-api reads it as its "prebuilt CA"; without it, it uploads an empty CA and every certificate fails with `no default issuer`) |
| OpenBao JSON limit | n/a (Vault) | `max_request_json_strings = 100000` | OpenBao refuses management-api's state document with its default of 1000 |
| Placeholder TLS/JWS files | empty files in `docker/sdk-scheme-adapter/` | Secrets `pm4ml-tls` (empty) and `pm4ml-jws` (throwaway), from `scripts/create-mcm-secrets.sh` | The SDK refuses to start without the files; management-api replaces them |
| `ENABLE_TEST_FEATURES` | true | true | Kept. Port 4002 is never published |
| SDK replicas | 1 container | 2, PDB, soft anti-affinity, preStop + 60 s grace | Production: a graceful pod stop (drain, rollout) fails no payment in flight (validated). On a node loss or crash, payments in flight can be reported failed yet committed: the core connector checks `GET /transfers/{transferId}` before treating them as failed |
| Redis for production | single container | `redis/values-redis-ha.yaml` recommended | A Redis crash fails payments in flight; Sentinel failover did not (validated) |
| Resources | none | requests/limits on SDK, management-api, core connector | One noisy pod cannot starve the others |
| Several DFSPs per namespace | n/a | `RELEASE=` / `scripts/for-release.sh` | Names follow the Helm release |

## Behaviour to expect before the hub admits the DFSP

Until the hub operator has created the DFSP in MCM and the client secret is
right, management-api logs `401 invalid_client` from Keycloak and keeps
retrying, and the SDK restarts with `Validation keys must be supplied`: it has
no peer JWS keys yet. Both resolve once management-api reaches MCM. This is the
state the test install on 2026-11-18 stopped at (see the README).
