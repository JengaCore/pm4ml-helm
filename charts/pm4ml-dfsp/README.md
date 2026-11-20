# pm4ml-dfsp

![Version: 0.2.0](https://img.shields.io/badge/Version-0.2.0-informational?style=flat-square) ![AppVersion: v24.19.3](https://img.shields.io/badge/AppVersion-v24.19.3-informational?style=flat-square)

Helm chart for a DFSP's Payment Manager (PM4ML) on any Kubernetes, connected to
a jengacore switch through MCM. It follows
[pm4ml-docker-compose](https://github.com/JengaCore/pm4ml-docker-compose): the hub
operator adds the DFSP in MCM and sends it a Keycloak client id and secret;
management-api does the rest (CA, CSRs, certificates, peer JWS keys) by REST.

One `values.yaml` drives everything. To run its own core connector, a DFSP
changes `coreConnector.image` (and its port, environment, Secrets and files);
nothing else in the chart changes.

## What it deploys

| Component | Values | Default |
|---|---|---|
| SDK scheme adapter (mTLS + JWS to the switch) | `sdk.*` | v24.19.3, 2 replicas, PDB, graceful stop |
| management-api (enrolment with MCM) | `managementApi.*`, `mcm.*` | 7.0.0 |
| The DFSP's core connector | `coreConnector.*` | simulator core connector; any image |
| Secret store (DFSP CA, private keys) | `openbao.*` or `vault.*` (upstream charts) | OpenBao 2.6.5 ([openbao/openbao](https://github.com/openbao/openbao-helm) chart), Raft on a PVC, static seal; Vault 1.13.3 ([hashicorp/vault](https://github.com/hashicorp/vault-helm)) with `presets/store-vault.yaml` |
| Redis-compatible state store (SDK) | `valkey.*` (upstream chart) | [Valkey](https://github.com/valkey-io/valkey-helm) single node, password; HA (replication + Sentinel + HAProxy) with `presets/valkey-ha.yaml`; a managed Redis with `presets/redis-external.yaml` |
| Callback edge (switch → DFSP, TLS passthrough) | `callback.*` | L4 `LoadBalancer` on 443; or NodePort, Istio, ingress-nginx |
| Bootstrap Job (store init, CA, AppRoles, runtime Secrets) | `bootstrap.*` | on, idempotent, one per revision |
| Backup CronJob (store snapshots → any S3 API) | `backup.*` | off |
| NetworkPolicies, PodMonitor | `networkPolicies.*`, `monitoring.*` | on, off |

## Get the chart

Released versions are OCI artifacts on GHCR, signed with cosign (keyless):

```sh
helm show values oci://ghcr.io/jengacore/charts/pm4ml-dfsp --version <x.y.z>
cosign verify ghcr.io/jengacore/charts/pm4ml-dfsp:<x.y.z> \
  --certificate-identity https://github.com/JengaCore/pm4ml-helm/.github/workflows/chart-release.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Every chart change raises `version` in `Chart.yaml`; a merge to `main` with a new
version publishes it (`.github/workflows/chart-release.yml`) after the same checks
as every pull request: lint, Kubernetes schemas, kube-linter, shellcheck of every
embedded script, the generated values table, refusal of unsafe values, and an
install on kind for OpenBao + Valkey HA and Vault + single-node Valkey (bootstrap Job
with its Role, store, Redis password, NetworkPolicies, upgrade, store restart).
Run the static checks locally with `.github/scripts/chart-checks.sh`.

## Upstream charts and presets

The chart writes only what is ours: the SDK, management-api, the core connector, the
callback edge, the bootstrap / backup / restore / certificate-check Jobs and the
NetworkPolicies. The secret store and the Redis-compatible store are upstream charts,
pinned in `Chart.yaml`, configured under their own key (`openbao`, `vault`, `valkey`)
with the upstream chart's values. `values.yaml` holds the production defaults; the
`presets/` files switch a building block in one `-f`:

| Preset | Gives |
|---|---|
| (none) | OpenBao (static seal, Raft on a volume) + single-node Valkey with a password |
| `presets/valkey-ha.yaml` | Valkey with replication, Sentinel and HAProxy (3 data nodes, 3 Sentinels, 2 HAProxy) |
| `presets/redis-external.yaml` | A managed Redis (ElastiCache, Azure Cache, Memorystore) instead of Valkey |
| `presets/store-vault.yaml` | Vault 1.13.3 with key shares instead of OpenBao |

```sh
helm upgrade --install mydfsp charts/pm4ml-dfsp -f charts/pm4ml-dfsp/presets/valkey-ha.yaml -f my-values.yaml
```

**Upgrading from 0.1.x:**
1. Rewrite the values: `redis.mode`, `redis-ha`, `store.type`, `store.persistence`... are
   refused with a message naming the new key (HA is `presets/valkey-ha.yaml`).
2. Take a backup (backup CronJob) and keep the OpenBao seal Secret.
3. **Vault installs only:** the old and the new StatefulSet are both `<release>-vault`,
   and their selectors differ (immutable), so delete the old one first:
   `kubectl delete statefulset <release>-vault`. Deleting a StatefulSet does not delete
   its volume claims (the 0.1.x chart sets no retention policy). Its volume
   claim has the same name as the new one (`data-<release>-vault-0`); not exercised: if the
   new Vault does not come up initialised on it, delete the claim and restore (step 4).
4. Upgrade with `restore.enabled=true`: the store (OpenBao: `<release>-openbao`, a new
   volume) starts empty and the restore Job brings back the same CA, no new onboarding.
   Then upgrade again with `restore.enabled=false`. Done on sbx UAT for OpenBao.
5. Redis holds only payments in flight: upgrade outside traffic.

## Install

1. Choose the callback host name (`callback.host`): it goes into the server
   certificate and into MCM at enrolment. The address can come later (see
   [Callback address](#callback-address)).
2. Create the Secret with the client secret the hub operator sent:
   ```sh
   kubectl -n dfsp create secret generic mydfsp-mcm --from-literal=client-secret='<from the hub>'
   ```
   (or with External Secrets from your secrets manager).
3. Write your values (start from [`examples/values-production.yaml`](examples/values-production.yaml);
   on EKS add [`examples/values-aws.yaml`](examples/values-aws.yaml)) and install:
   ```sh
   helm dependency build charts/pm4ml-dfsp
   helm -n dfsp install mydfsp charts/pm4ml-dfsp -f my-values.yaml
   kubectl -n dfsp logs -f job/mydfsp-bootstrap-1
   ```
4. Move Secret `mydfsp-store-init` (unseal/recovery keys, root token) to escrow
   and delete it; with OpenBao, also back up `mydfsp-openbao-seal`.
5. Point `callback.host` at the callback Service's address
   (`kubectl get svc mydfsp-callbacks`) if not done before: management-api
   waits for that DNS record, then enrols.
6. The hub operator signs the DFSP's request in MCM. management-api installs the
   certificates; payments flow.

The NOTES printed by `helm install` repeat these steps with your names.

## Certificates and renewal

| Certificate | Signed by | Lifetime (default) | Renewal |
|---|---|---|---|
| DFSP CA | itself, in the store | 97 600 h | never replaced by the chart |
| Server (callbacks) | DFSP CA | the PKI mount's default, 32 days | automatic, 2 days before expiry; no hub action (the hub trusts the CA) |
| Client (to the switch) | hub CA, in MCM | the hub's choice (90 days on sbx) | management-api sends a new CSR 7 days before expiry; **the hub operator signs it** in MCM |
| Hub's client certificate | DFSP CA | 5 years | signed by management-api |

Alert on the client certificate's expiry: it is the only renewal that needs a
person on the hub side. The MCM does not sign a renewal by itself: connection-manager
v3.1.5 stores the new CSR as a pending enrolment (as at onboarding), and the hub's
onboarding module deliberately never automates signing. management-api collects the
signed certificate within a minute and hands it to the SDK without a restart.
MCM tells nobody about a renewal request (no email, webhook or metric), so the chart
watches it: the `certCheck` CronJob (on by default, every 6 hours) reads, with the
DFSP's own MCM credentials, what MCM holds for this DFSP. It fails, and posts to
`certCheck.alertWebhook` (any Slack-compatible incoming webhook), when a renewal waits
for the hub's signature (`renewal.pending`) or the certificate expires within
`certCheck.warnDays` (14). If the check itself cannot run (MCM or Keycloak
unreachable, the client secret rejected) the Job fails too and the webhook says so. With
the Prometheus Operator, `certCheck.prometheusRule`
adds `Pm4mlCertificateAttention`; without it, the failed Job is the signal
(`KubeJobFailed`). Validated against sbx UAT's MCM. The hub runs the same check on its
side (switch-iac `dfsp-cert-check`, `DfspCertificateAttention`). Agree with the hub how
you tell them a renewal is waiting. Upstream bug: `POST /dfsp/servercerts` on
management-api 7.0.0 returns 500 (`ctx.stateMachine` is undefined), so the
server certificate cannot be renewed on demand; the automatic renewal works.

### Renewing or replacing the client certificate by hand

Renewal is automatic on the DFSP side; a person can still start one at any time
(after a suspected key leak, before a planned change, to test the procedure):

```sh
kubectl -n <ns> exec deploy/<release>-management-api -- \
  wget -qO- --header 'Content-Type: application/json' \
  --post-data '{"reason":"<why>"}' http://127.0.0.1:9000/recreate/outboundTLS
```

management-api creates a new key and CSR and sends it to MCM; `certCheck` and the hub's
check report `renewal.pending`; the hub operator signs it; management-api installs the
new certificate within about two minutes, with no restart. Validated on sbx UAT
(`pm4mlhelm04`, 2026-11-19): request 12 signed, new serial in use, payments 10/10 each
way before, during and after, both checks back to `cert.ok`. The previous certificate
is not revoked and stays valid until it expires: say so to the hub if the reason is a
leaked key. `/recreate/JWS` does the same for the JWS signing key (peers pick up the
new key from MCM; not exercised here). The server certificate (callbacks) cannot be
renewed by hand on management-api 7.0.0 (`POST /dfsp/servercerts` answers 500); it
renews itself 2 days before expiry.

## Callback address

The switch calls the DFSP at `https://<callback.host>:443`, with mutual TLS
terminated by the SDK. The chart keeps that address stable and refuses to
enrol on a name that does not resolve:

- **Name before address.** management-api has an init container
  (`callback.preflight`) that waits until `callback.host` resolves, and, with
  `callback.preflight.expectIP`, until it resolves to that address. So either
  reserve the address first, or install, read the address from
  `kubectl get svc <release>-callbacks`, then create the DNS record:
  enrolment starts by itself. Its log says what it waits for:
  `kubectl logs deploy/<release>-management-api -c wait-callback-dns`.
- **The address survives.** The Service has `helm.sh/resource-policy: keep`
  (`callback.service.keep`): `helm uninstall` and a reinstall keep the same
  load balancer and address. Delete the Service by hand to release it.
- **A reserved address**, so a lost cluster or Service comes back on the same
  IP and nothing changes on the switch side:

| Platform | Reserve | Values |
|---|---|---|
| AWS (NLB, AWS Load Balancer Controller) | one Elastic IP per subnet | `annotations`: `service.beta.kubernetes.io/aws-load-balancer-type: external`, `...-nlb-target-type: ip`, `...-scheme: internet-facing`, `...-eip-allocations: eipalloc-a,eipalloc-b` |
| Azure (AKS) | a static Standard public IP, in the node resource group or another one | `annotations`: `service.beta.kubernetes.io/azure-pip-name: <name>` (+ `azure-load-balancer-resource-group: <rg>` if elsewhere) |
| Google (GKE) | a regional static external IP | `loadBalancerIP: <ip>` |
| OpenStack (Octavia) | a floating IP in the project | `loadBalancerIP: <floating ip>` (the Service then shows it; validated) |
| MetalLB | an address in an `IPAddressPool` | `annotations`: `metallb.universe.tf/loadBalancerIPs: <ip>` |
| F5 / HAProxy / bare metal | the appliance's VIP, TCP mode, forwarding to a NodePort | `type: NodePort`, `nodePort: 3xxxx` |

Always set `loadBalancerSourceRanges` to the switch's egress addresses (ask
the hub operator) and keep `externalTrafficPolicy: Local`. Check from outside:
`openssl s_client -connect <callback.host>:443 -servername <callback.host>`
must show `<dfspId> CA` as issuer once enrolled.

## Backups and restore

`backup.enabled` runs a CronJob that takes a Raft snapshot of the store with a
snapshot-only AppRole and uploads it to any S3 API (`backup.s3Secret`). If the
store's volume is lost:

```sh
helm upgrade <release> ... --set restore.enabled=true     # restores the newest snapshot
kubectl logs -f job/<release>-store-restore-<revision>
helm upgrade <release> ... --set restore.enabled=false    # back to normal
```

The restore Job only writes into an empty store, and the bootstrap Job is skipped while
it is on (on an empty store it would create a new CA). With `restore.rbac` it restarts
the store pod: OpenBao then unseals itself and the Job restarts management-api; Vault
waits for its **original** key shares (before that restart Vault can keep the throwaway
seal setting and reject them with `invalid key size 33`), after which you restart
management-api. Payments keep flowing while the store is down or being restored: it is only
on the enrolment path. Keep the OpenBao seal key Secret: the snapshot is useless without it.

## Security defaults

- **NetworkPolicies** (`networkPolicies.enabled`): the SDK's outbound API (4001),
  which starts payments without authentication, accepts only this release's core
  connector (plus `networkPolicies.sdkOutboundFrom`); management-api accepts only
  the SDK; the store and Redis only this release's pods; callbacks (4000) are open
  to the load balancer. They need a network plugin that enforces them.
- **Containers**: non-root, read-only root file system (writable `/tmp`), no
  capabilities, `RuntimeDefault` seccomp; the same defaults for the core connector,
  which you can relax in `coreConnector.securityContext` if its image needs to.
- **The store must persist**: the chart refuses a store without a volume
  (`<openbao|vault>.server.dataStorage.enabled: false`) unless `store.acceptDataLoss: true`. Without a volume, any change to
  the store's pod (a `helm upgrade` included) recreates it empty: new CA, onboarding
  again. That happened once on a test release; hence the guard.
- **Releases sharing a namespace** need their own OpenBao seal Secret
  (`openbao.server.volumes`, `seal` volume: `<release>-openbao-seal`; the chart refuses
  the shared default). Valkey's password Secret and NetworkPolicy already follow the
  release name (`<release>-redis-auth`, label `<release>-valkey-client`).

## Bring your own core connector

```yaml
coreConnector:
  image:
    repository: registry.example.com/bank/core-connector
    tag: "2.3.1"
  imagePullSecrets: [ { name: registry } ]
  port: 3003                  # the backend API the SDK calls
  backendPath: ""             # if it is not at the root
  extraPorts:                 # e.g. the API the core banking system calls
    - { name: cbs-api, port: 3004 }
  env:
    CBS_BASE_URL: https://cbs.internal.example
  envFromSecrets:
    CBS_API_KEY: { secret: cbs-credentials, key: api-key }
  extraVolumes:
    - { name: cbs-ca, secret: { secretName: cbs-ca } }
  extraVolumeMounts:
    - { name: cbs-ca, mountPath: /etc/cbs-ca, readOnly: true }
  readinessProbe: { httpGet: { path: /health, port: 3003 } }
  resources: { requests: { cpu: 200m, memory: 512Mi }, limits: { memory: 1Gi } }
```

The core connector runs as uid 1001 by default (the Mojaloop/PM4ML images' user):
set `coreConnector.podSecurityContext.runAsUser` to your image's uid.

The chart injects `SDK_OUTBOUND_URL` / `MLCONN_OUTBOUND_ENDPOINT`
(`http://<release>-sdk:4001`), `DFSP_ID`, `DFSP_CURRENCY` and, if
`injectRedisUrl`, `REDIS_URL`. The SDK calls the core connector at
`http://<release>-core-connector:<port><backendPath>`.

Core connector deployed elsewhere: `coreConnector.enabled: false` and
`coreConnector.externalBackendEndpoint: host:port`, plus
`networkPolicies.sdkOutboundFrom` listing the core connector's pods (required while
`networkPolicies.enabled` is true).

The core connector must keep its own record of the payments it starts (keyed by
`homeTransactionId`) and, after an error or timeout, ask
`GET /transfers/{transferId}` on the SDK before retrying: the SDK does not
de-duplicate. See [docs/PRODUCTION.md](../../docs/PRODUCTION.md#idempotency-the-core-connectors-part).

## Validation

On sbx UAT (ISO 20022, GMD), no change on the switch, on the Coder cluster (OpenStack,
Cilium, Cinder volumes).

**2026-11-19, final chart, release `dfsp4` = DFSP `pm4mlhelm04`**: store on a
persistent volume, Redis HA (3 + HAProxy, password), 3 SDK replicas, NetworkPolicies
on, read-only root file systems, core connector swapped by values
(`mojaloop/mojaloop-simulator:v15.5.4` as non-root).

| Test | Result |
|---|---|
| Admitted in MCM, enrolled by management-api (DNS preflight on the reserved address), CSR signed by the hub operator, reconciler wired it | ✓ |
| Send / receive with another PM4ML DFSP | 20/20 and 20/20; ledger positions moved by exactly the payments |
| Send / receive with a third DFSP | 10/10 and 10/10 |
| NetworkPolicies, from a pod of another app | SDK 4001, management-api 4005/9000, store, Redis: all **closed**; 4000 (callbacks) and 4004 (metrics) open; the allowed test client reaches 4001 |
| 100 + 100 payments both ways at once, 10 concurrent, one SDK pod deleted mid-run (graceful) | **200/200**, ledger exact |
| Redis master **force-killed** (no grace) mid-run, 60 + 60 payments | 96/120 reported completed. Checked one by one with `GET /transfers/{id}`: 4 reported as errors had **committed**, 1 failed, 1 never got an id, 18 never reached the switch (`3208`, no money moved). Ledger = the reconciled states exactly. Failover took ~20 s; this is the case the core connector's idempotency rule exists for |
| Backup CronJob → S3, then the store's **volume deleted** | snapshot 150 KB uploaded; 5/5 payments while the store was empty |
| `restore.enabled=true` | Job restored the newest snapshot; **same CA fingerprint**; management-api resumed **without a new enrolment**; 10/10 each way after |
| `helm upgrade` that recreates the store pod (the case that lost `pm4mlhelm03` without a volume) | same CA, unsealed by itself, 5/5 after |
| Server certificate renewal (earlier run, shortened TTL) | renewed itself, payments flowing during the renewals |

Not covered on this cluster: the bootstrap and restore Jobs' Roles (its service account
cannot create Roles: the same scripts ran with the operator's rights). In CI on kind, for
OpenBao and Vault: bootstrap, backup to an S3 API, the store's volume deleted, then the
restore Job and the same CA, then the next bootstrap on the restored store (CA unchanged).
The restore Job restarts the store pod with its Role; OpenBao unseals itself and the Job
restarts management-api; on Vault the test unseals with the original shares, then
restarts management-api. Also not covered: the automatic trigger of a client certificate renewal at 7 days
(the same renewal path, started by hand, was validated end to end: see "Renewing or
replacing the client certificate by hand"), node drain (no node rights), EKS/AKS, a
managed Redis over TLS.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| backup.enabled | bool | `false` | CronJob: snapshot of the store to an S3-compatible bucket. |
| backup.image | string | `"amazon/aws-cli:2.22.0"` |  |
| backup.prefix | string | `""` |  |
| backup.s3Secret | string | `""` | Secret with AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION, S3_BUCKET and optional S3_ENDPOINT. |
| backup.schedule | string | `"17 */6 * * *"` |  |
| bootstrap.enabled | bool | `true` | Job (one per Helm revision): initialises and configures the store, creates the DFSP CA (once, never replaced), the AppRoles and the runtime secrets. Idempotent. |
| bootstrap.image | string | `"alpine/k8s:1.31.4"` |  |
| bootstrap.rbac | bool | `true` | Create the namespaced Role it needs (Secrets only). |
| bootstrap.serviceAccountName | string | `""` | With rbac false: an existing ServiceAccount an administrator bound to an equivalent Role (create Secrets; get/patch/update on this release's Secrets). Without one, the Job stops before initialising anything. |
| callback.host | string | `""` | Public host name the switch calls back (in the server certificate and in MCM). Only the name is needed at install: the address can come after (see preflight). |
| callback.ingressNginx.className | string | `"nginx"` |  |
| callback.ingressNginx.enabled | bool | `false` |  |
| callback.istio.enabled | bool | `false` | Istio Gateway (PASSTHROUGH) + VirtualService instead of, or as well as, the Service. |
| callback.istio.gatewaySelector.istio | string | `"ingressgateway"` |  |
| callback.preflight.enabled | bool | `true` | management-api waits (init container) until callback.host resolves before enrolling, so a DFSP can install first, read the load balancer's address, then create the DNS record. |
| callback.preflight.expectIP | string | `""` | Also require this address among the answers (the reserved IP). Empty: any address. |
| callback.preflight.image | string | `"busybox:1.36.1"` |  |
| callback.service.annotations | object | `{}` | e.g. AWS NLB: service.beta.kubernetes.io/aws-load-balancer-type: external, aws-load-balancer-nlb-target-type: ip, aws-load-balancer-eip-allocations: eipalloc-... |
| callback.service.enabled | bool | `true` | Publish the SDK's inbound port as a TCP 443 service (TLS passthrough: the SDK terminates mTLS). |
| callback.service.externalTrafficPolicy | string | `"Local"` | Keep the switch's source IP. |
| callback.service.keep | bool | `true` | Keep the Service (and so its address) on helm uninstall (helm.sh/resource-policy: keep). |
| callback.service.loadBalancerIP | string | `""` | A reserved address (OpenStack floating IP, GKE static IP, Azure static IP). Some providers want an annotation instead: see the chart README, "Callback address". |
| callback.service.loadBalancerSourceRanges | list | `[]` | Restrict to the switch's egress IPs (CIDRs). Strongly recommended. |
| callback.service.nodePort | string | `nil` | Fixed node port when type is NodePort. |
| callback.service.port | int | `443` |  |
| callback.service.type | string | `"LoadBalancer"` | LoadBalancer (cloud, MetalLB, Octavia) or NodePort (behind an F5/HAProxy in TCP mode). |
| certCheck.alertWebhook.existingSecret | string | `""` | Secret holding a Slack-compatible incoming webhook URL (Slack, Mattermost, Rocket.Chat, Teams workflow). Empty: no message, the failed Job is the signal. |
| certCheck.alertWebhook.key | string | `"url"` |  |
| certCheck.enabled | bool | `true` | CronJob watching the DFSP's client certificate (signed by the hub in MCM): fails, and posts to alertWebhook, when a renewal waits for the hub's signature or the certificate expires within warnDays. MCM notifies nobody of a renewal request. |
| certCheck.image | string | `""` | Image with sh, curl and jq. Default: bootstrap.image. |
| certCheck.prometheusRule.enabled | bool | `false` | PrometheusRule Pm4mlCertificateAttention (Prometheus Operator), firing while the last check has not succeeded. |
| certCheck.prometheusRule.labels | object | `{}` |  |
| certCheck.schedule | string | `"41 */6 * * *"` |  |
| certCheck.warnDays | int | `14` | Alert this many days before expiry (management-api requests the renewal at 7). |
| coreConnector.affinity | object | `{}` | Default: spread replicas over nodes (preferred). |
| coreConnector.backendPath | string | `""` | Path of the backend endpoint, if not at the root. |
| coreConnector.enabled | bool | `true` | Deploy the DFSP's core connector with this chart. |
| coreConnector.env | object | `{}` | Environment variables (name: value). |
| coreConnector.envFrom | list | `[]` | Whole Secrets/ConfigMaps as environment (envFrom entries). |
| coreConnector.envFromSecrets | object | `{}` | Environment variables from Secrets: NAME: { secret: <name>, key: <key> }. |
| coreConnector.externalBackendEndpoint | string | `""` | The SDK's backend when coreConnector.enabled is false (host:port). |
| coreConnector.extraPorts | list | `[]` | Extra ports to expose on the Service, e.g. the API the core banking system calls. |
| coreConnector.extraVolumeMounts | list | `[]` |  |
| coreConnector.extraVolumes | list | `[]` | Extra volumes and mounts (configuration files, certificates for the core banking API...). |
| coreConnector.image.pullPolicy | string | `"IfNotPresent"` |  |
| coreConnector.image.repository | string | `"pm4ml/mojaloop-payment-manager-simulator-core-connector"` | The DFSP's own core connector image. |
| coreConnector.image.tag | string | `"1.4.5"` |  |
| coreConnector.imagePullSecrets | list | `[]` | Pull secrets for a private registry, e.g. [{ name: my-registry }]. |
| coreConnector.injectRedisUrl | bool | `true` | Inject REDIS_URL (the DFSP's Redis) into the core connector. |
| coreConnector.livenessProbe | object | `{}` |  |
| coreConnector.nodeSelector | object | `{}` |  |
| coreConnector.pdb.enabled | bool | `true` |  |
| coreConnector.pdb.minAvailable | int | `1` |  |
| coreConnector.podSecurityContext | object | `{"fsGroup":1001,"runAsGroup":1001,"runAsNonRoot":true,"runAsUser":1001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. uid 1001 is the user of the Mojaloop/PM4ML images; set your image's uid (Kubernetes cannot check a non-numeric USER such as app-user). |
| coreConnector.port | int | `3003` | Port of the API the SDK calls (its backend API). |
| coreConnector.readinessProbe | object | `{}` |  |
| coreConnector.replicaCount | int | `2` |  |
| coreConnector.resources.limits.memory | string | `"1Gi"` |  |
| coreConnector.resources.requests.cpu | string | `"100m"` |  |
| coreConnector.resources.requests.memory | string | `"512Mi"` |  |
| coreConnector.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. The root file system is read-only; /tmp is writable (an emptyDir). Mount other writable paths with extraVolumes, or relax this. |
| coreConnector.tolerations | list | `[]` |  |
| dfspId | string | `""` | The DFSP id, exactly as the hub operator created it in MCM (case-sensitive). |
| egress.whitelistIps | list | `[]` | The DFSP's fixed egress IPs (bare IPv4, no CIDR): MCM gives them to the switch. |
| fullnameOverride | string | `""` | Overrides the full name (default: the release name). |
| managementApi.extraEnv | object | `{}` | Extra environment variables (name: value), applied last. |
| managementApi.image.pullPolicy | string | `"IfNotPresent"` |  |
| managementApi.image.repository | string | `"pm4ml/mojaloop-payment-manager-management-api"` |  |
| managementApi.image.tag | string | `"7.0.0"` |  |
| managementApi.nodeSelector | object | `{}` |  |
| managementApi.privateKeyLength | int | `4096` |  |
| managementApi.resources.limits.memory | string | `"512Mi"` |  |
| managementApi.resources.requests.cpu | string | `"100m"` |  |
| managementApi.resources.requests.memory | string | `"256Mi"` |  |
| managementApi.tolerations | list | `[]` |  |
| mcm.clientSecret.existingSecret | string | `""` | Secret holding the Keycloak client secret the hub operator issued. Create it (kubectl or External Secrets) before installing. Default name: <release>-mcm. |
| mcm.clientSecret.key | string | `"client-secret"` |  |
| mcm.subject | object | `{"country":"","email":"","locality":"","organization":"","organizationalUnit":"Payments","state":""}` | Subject of the DFSP's CA and certificates. |
| monitoring.annotations | bool | `true` | prometheus.io/* annotations on the SDK pods (port 4004). |
| monitoring.podMonitor.enabled | bool | `false` | Create a PodMonitor (Prometheus Operator). |
| monitoring.podMonitor.interval | string | `"30s"` |  |
| monitoring.podMonitor.labels | object | `{}` |  |
| nameOverride | string | `""` | Overrides the chart name used in resource names. |
| networkPolicies.enabled | bool | `true` | NetworkPolicies: the store and the single Redis only from this release's pods; the SDK's outbound API (4001, starts payments) only from the core connector; management-api only from the SDK; the callback port (4000) from anywhere (the load balancer). |
| networkPolicies.managementApiFrom | list | `[]` | Extra peers allowed on management-api's API (9000), e.g. a payment manager UI. |
| networkPolicies.metricsFrom | list | `[]` | Peers allowed on the metrics port (4004). Default: any pod (metrics hold no secrets). |
| networkPolicies.sdkOutboundFrom | list | `[]` | Extra peers allowed on the SDK's outbound API (4001), e.g. a core connector deployed elsewhere: [{ namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: bank } } }] |
| openbao | object | `{"csi":{"enabled":false},"enabled":true,"injector":{"enabled":false},"server":{"auditStorage":{"enabled":false},"authDelegator":{"enabled":false},"dataStorage":{"enabled":true,"size":"1Gi","storageClass":null},"image":{"registry":"quay.io","repository":"openbao/openbao","tag":"2.6.5"},"resources":{"limits":{"memory":"256Mi"},"requests":{"cpu":"50m","memory":"128Mi"}},"standalone":{"config":"ui = false\ndisable_mlock = true\nstorage \"raft\" {\n  path    = \"/openbao/data\"\n  node_id = \"{{ .Release.Name }}-openbao-0\"\n}\ncluster_addr = \"http://127.0.0.1:8201\"\napi_addr     = \"http://{{ .Release.Name }}-openbao:8200\"\nlistener \"tcp\" {\n  address     = \"[::]:8200\"\n  tls_disable = 1\n  max_request_json_strings = 100000\n}\nseal \"static\" {\n  current_key_id = \"{{ .Release.Name }}-1\"\n  current_key    = \"file:///openbao/seal/unseal.key\"\n}\n","enabled":true},"volumeMounts":[{"mountPath":"/openbao/seal","name":"seal","readOnly":true}],"volumes":[{"name":"seal","secret":{"defaultMode":288,"secretName":"pm4ml-openbao-seal"}}]},"ui":{"enabled":false}}` | OpenBao subchart (openbao/openbao 0.30.7). |
| openbao.server.dataStorage.enabled | bool | `true` | The store's volume. Production: true (see store.acceptDataLoss). |
| redis.external.urlKey | string | `"url"` |  |
| redis.external.urlSecret | string | `""` | With valkey.enabled false: Secret and key holding the redis:// or rediss:// URL (with its password) of a managed Redis (ElastiCache, Azure Cache, Memorystore). |
| restore.enabled | bool | `false` | Job that restores the store from the newest backup snapshot (or restore.snapshotKey) after its volume was lost. Only into an empty store; the bootstrap Job is skipped while this is on. Set it back to false afterwards. Uses backup.s3Secret and backup.prefix. |
| restore.rbac | bool | `true` | Let the Job restart the store pod (OpenBao unseals at start) and management-api. |
| restore.snapshotKey | string | `""` | Object key of the snapshot to restore. Empty: the newest under the backup prefix. |
| sdk.affinity | object | `{}` |  |
| sdk.autoAcceptParticipantsPut | bool | `true` |  |
| sdk.autoAcceptParty | bool | `true` |  |
| sdk.autoAcceptQuotes | bool | `false` |  |
| sdk.extraEnv | object | `{}` | Extra environment variables (name: value), applied last. |
| sdk.image.pullPolicy | string | `"IfNotPresent"` |  |
| sdk.image.repository | string | `"mojaloop/sdk-scheme-adapter"` |  |
| sdk.image.tag | string | `"v24.19.3"` |  |
| sdk.jws.sign | bool | `true` |  |
| sdk.jws.validateInbound | bool | `true` |  |
| sdk.logLevel | string | `"info"` |  |
| sdk.nodeSelector | object | `{}` |  |
| sdk.pdb | object | `{"enabled":true,"minAvailable":1}` | PodDisruptionBudget for the SDK. |
| sdk.podAnnotations | object | `{}` |  |
| sdk.preStopSeconds | int | `35` | Seconds the pod keeps serving payments in flight before it stops. |
| sdk.replicaCount | int | `2` | 2+ in production: replicas share state through Redis. |
| sdk.requestTimeoutSeconds | int | `30` |  |
| sdk.resources.limits.memory | string | `"768Mi"` |  |
| sdk.resources.requests.cpu | string | `"250m"` |  |
| sdk.resources.requests.memory | string | `"384Mi"` |  |
| sdk.terminationGracePeriodSeconds | int | `60` |  |
| sdk.tolerations | list | `[]` |  |
| store.acceptDataLoss | bool | `false` | Refuse to render a store without a volume unless set: the store (the DFSP's CA, keys and enrolment) would be lost whenever its pod is recreated, a helm upgrade included. Throwaway tests only. |
| switch.apiType | string | `"fspiop"` | API flavour; must match the switch: fspiop or iso20022. |
| switch.caBundle | string | `""` | Private CA (PEM) of the switch's mcm./keycloak. hosts, if they do not use a public CA. |
| switch.currency | string | `""` | Settlement currency of this DFSP on the switch. |
| switch.domain | string | `""` | The switch's domain: hosts default to fspiop.<domain>, mcm.<domain>, keycloak.<domain>. |
| switch.fspiopHost | string | `""` | FSPIOP endpoint (lookups, quotes, transfers). Default: fspiop.<domain>. |
| switch.ilpVersion | string | `"4"` | ILP version (4 with iso20022; Compose uses 4). |
| switch.keycloakUrl | string | `""` | Keycloak base URL. Default: https://keycloak.<domain>. |
| switch.mcmUrl | string | `""` | MCM base URL. Default: https://mcm.<domain>/pm4mlapi. |
| switch.realm | string | `"dfsps"` | Keycloak realm holding the DFSP clients. |
| valkey | object | `{"auth":{"aclUsers":{"default":{"permissions":"~* &* +@all"}},"enabled":true,"usersExistingSecret":"{{ .Release.Name }}-redis-auth"},"enabled":true,"haproxy":{"enabled":false},"networkPolicy":{"allowExternal":false,"enabled":true},"persistence":{"enabled":true,"size":"2Gi"},"replica":{"enabled":false},"resources":{"limits":{"memory":"512Mi"},"requests":{"cpu":"100m","memory":"256Mi"}},"sentinel":{"enabled":false,"existingSecret":"{{ .Release.Name }}-redis-auth","passwordKey":"sentinel"}}` | Valkey subchart. enabled: false to use redis.external instead. |
| vault | object | `{"csi":{"enabled":false},"enabled":false,"injector":{"enabled":false},"server":{"auditStorage":{"enabled":false},"authDelegator":{"enabled":false},"dataStorage":{"enabled":true,"size":"1Gi","storageClass":null},"image":{"repository":"hashicorp/vault","tag":"1.13.3"},"resources":{"limits":{"memory":"256Mi"},"requests":{"cpu":"50m","memory":"128Mi"}},"standalone":{"config":"ui = false\ndisable_mlock = true\nstorage \"raft\" {\n  path    = \"/vault/data\"\n  node_id = \"{{ .Release.Name }}-vault-0\"\n}\ncluster_addr = \"http://127.0.0.1:8201\"\napi_addr     = \"http://{{ .Release.Name }}-vault:8200\"\nlistener \"tcp\" {\n  address     = \"[::]:8200\"\n  tls_disable = 1\n}\n","enabled":true}},"ui":{"enabled":false}}` | Vault subchart (hashicorp/vault 0.34.1, image pinned to 1.13.3, the last MPL release). |
