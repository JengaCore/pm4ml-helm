# pm4ml-dfsp

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![AppVersion: v24.19.3](https://img.shields.io/badge/AppVersion-v24.19.3-informational?style=flat-square)

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
| Secret store (DFSP CA, private keys) | `store.*` | OpenBao 2.6.5, Raft on a PVC, static seal |
| Redis (SDK state) | `redis.mode`, `redis-ha.*` | `ha`: Sentinel + HAProxy + password; or `single`, `external` (ElastiCache, Azure Cache) |
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
install on kind for OpenBao + Redis HA and Vault + single Redis (bootstrap Job
with its Role, store, Redis password, NetworkPolicies, upgrade, store restart).
Run the static checks locally with `.github/scripts/chart-checks.sh`.

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
person on the hub side. Upstream bug: `POST /dfsp/servercerts` on
management-api 7.0.0 returns 500 (`ctx.stateMachine` is undefined), so the
server certificate cannot be renewed on demand; the automatic renewal works.

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

## Security defaults

- **NetworkPolicies** (`networkPolicies.enabled`): the SDK's outbound API (4001),
  which starts payments without authentication, accepts only this release's core
  connector (plus `networkPolicies.sdkOutboundFrom`); management-api accepts only
  the SDK; the store and Redis only this release's pods; callbacks (4000) are open
  to the load balancer. They need a network plugin that enforces them.
- **Containers**: non-root, read-only root file system (writable `/tmp`), no
  capabilities, `RuntimeDefault` seccomp; the same defaults for the core connector,
  which you can relax in `coreConnector.securityContext` if its image needs to.
- **The store must persist**: the chart refuses `store.persistence.enabled: false`
  unless `store.persistence.acceptDataLoss: true`. Without a volume, any change to
  the store's pod (a `helm upgrade` included) recreates it empty: new CA, onboarding
  again. That happened once on a test release; hence the guard.
- **Releases sharing a namespace** need their own Redis password Secret
  (`redis-ha.existingSecret: <release>-redis-auth`; the chart refuses the shared
  default) and should narrow the redis-ha NetworkPolicy selectors to their release.

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
de-duplicate. See [docs/BUILDING-BLOCKS.md](../../docs/BUILDING-BLOCKS.md).

## Validation

2026-11-19, sbx UAT (iso20022, GMD), release `dfsp3` = DFSP `pm4mlhelm03`, no
change on the switch. Callback on an OpenStack Octavia load balancer; the
DNS preflight checked against the expected address (and kept waiting on a
wrong one); the Service kept its address through upgrades. The core connector was swapped by values only
(`mojaloop/mojaloop-simulator:v15.5.4`, port 3000, rules file from a ConfigMap).
Enrolment through MCM to `DFSP_CLIENT_CERT_CONFIGURED`; payments 20/20 in each
of: pm4mlhelm03 → another PM4ML DFSP, the reverse, and a third DFSP →
pm4mlhelm03; ledger positions read from the hub after each run matched the
payments. The OpenBao container restarted and unsealed itself. The server
certificate renewed itself before expiry (shortened TTL), with payments flowing
during the renewals. Not exercised on that cluster: the bootstrap Job's Role (the test
service account cannot create Roles; the same script ran with the operator's
rights, `bootstrap.rbac: false`).

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
| redis-ha | object | `{"auth":true,"authKey":"auth","existingSecret":"pm4ml-redis-auth","haproxy":{"enabled":true,"hardAntiAffinity":true,"image":{"repository":"public.ecr.aws/docker/library/haproxy","tag":"3.0.8-alpine"},"networkPolicy":{"enabled":true,"ingressRules":[{"ports":[{"port":6379,"protocol":"TCP"}],"selectors":[{"podSelector":{"matchLabels":{"app.kubernetes.io/part-of":"pm4ml-dfsp"}}}]}]},"replicas":2},"hardAntiAffinity":true,"image":{"repository":"public.ecr.aws/docker/library/redis","tag":"8.2.2-alpine"},"networkPolicy":{"enabled":true,"ingressRules":[{"ports":[{"port":6379,"protocol":"TCP"}],"selectors":[{"podSelector":{"matchLabels":{"app.kubernetes.io/part-of":"pm4ml-dfsp"}}}]}]},"persistentVolume":{"enabled":true,"size":"2Gi"},"redis":{"config":{"appendfsync":"everysec","appendonly":"yes"},"resources":{"limits":{"memory":"512Mi"},"requests":{"cpu":"100m","memory":"256Mi"}}},"replicas":3}` | redis-ha subchart values (dandydeveloper/redis-ha 4.35.5), used when redis.mode is ha. |
| redis-ha.existingSecret | string | `"pm4ml-redis-auth"` | Secret with the Redis password (key auth); the bootstrap Job creates it with a random password if missing. Must be <release>-redis-auth for any release not named pm4ml (the chart refuses to render otherwise: a subchart value cannot use the release name). |
| redis-ha.haproxy.networkPolicy | object | `{"enabled":true,"ingressRules":[{"ports":[{"port":6379,"protocol":"TCP"}],"selectors":[{"podSelector":{"matchLabels":{"app.kubernetes.io/part-of":"pm4ml-dfsp"}}}]}]}` | Only this chart's pods (label app.kubernetes.io/part-of: pm4ml-dfsp) reach HAProxy. Releases sharing a namespace: select app.kubernetes.io/instance: <release> instead, here and in redis-ha.networkPolicy below. |
| redis.external.urlKey | string | `"url"` |  |
| redis.external.urlSecret | string | `""` | Secret and key holding redis:// or rediss:// URL (with its password). |
| redis.ha.enabled | bool | `true` | Must be true when mode is ha (it enables the subchart). |
| redis.mode | string | `"ha"` | ha: the redisHa subchart (Sentinel + HAProxy, password). single: one Redis (tests). external: a managed Redis whose URL is in redis.external.urlSecret. |
| redis.single.image | string | `"redis:7.2.5-alpine"` |  |
| redis.single.persistence.enabled | bool | `true` |  |
| redis.single.persistence.size | string | `"2Gi"` |  |
| redis.single.persistence.storageClass | string | `""` |  |
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
| store.image.openbao | string | `"openbao/openbao:2.6.5"` |  |
| store.image.vault | string | `"hashicorp/vault:1.13.3"` |  |
| store.persistence.acceptDataLoss | bool | `false` | Required to run with persistence off: the store (and the DFSP's identity) is then lost whenever its pod is recreated, including by a helm upgrade that changes it. |
| store.persistence.enabled | bool | `true` | Production: true. The store holds the DFSP CA and private keys. |
| store.persistence.size | string | `"1Gi"` |  |
| store.persistence.storageClass | string | `""` |  |
| store.resources.limits.memory | string | `"256Mi"` |  |
| store.resources.requests.cpu | string | `"50m"` |  |
| store.resources.requests.memory | string | `"128Mi"` |  |
| store.sealSecret | string | `""` | OpenBao: Secret with the 32-byte static seal key (key unseal.key). Created by the bootstrap Job if missing (back it up!). Default: <release>-openbao-seal. |
| store.type | string | `"openbao"` | openbao (unseals itself with a static key) or vault (Shamir key shares, as Compose). |
| switch.apiType | string | `"fspiop"` | API flavour; must match the switch: fspiop or iso20022. |
| switch.caBundle | string | `""` | Private CA (PEM) of the switch's mcm./keycloak. hosts, if they do not use a public CA. |
| switch.currency | string | `""` | Settlement currency of this DFSP on the switch. |
| switch.domain | string | `""` | The switch's domain: hosts default to fspiop.<domain>, mcm.<domain>, keycloak.<domain>. |
| switch.fspiopHost | string | `""` | FSPIOP endpoint (lookups, quotes, transfers). Default: fspiop.<domain>. |
| switch.ilpVersion | string | `"4"` | ILP version (4 with iso20022; Compose uses 4). |
| switch.keycloakUrl | string | `""` | Keycloak base URL. Default: https://keycloak.<domain>. |
| switch.mcmUrl | string | `""` | MCM base URL. Default: https://mcm.<domain>/pm4mlapi. |
| switch.realm | string | `"dfsps"` | Keycloak realm holding the DFSP clients. |
