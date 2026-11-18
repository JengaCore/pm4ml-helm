# pm4ml-dfsp

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

The chart injects `SDK_OUTBOUND_URL` / `MLCONN_OUTBOUND_ENDPOINT`
(`http://<release>-sdk:4001`), `DFSP_ID`, `DFSP_CURRENCY` and, if
`injectRedisUrl`, `REDIS_URL`. The SDK calls the core connector at
`http://<release>-core-connector:<port><backendPath>`.

Core connector deployed elsewhere: `coreConnector.enabled: false` and
`coreConnector.externalBackendEndpoint: host:port`.

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
pm4mlhelm03. Not exercised on that cluster: the bootstrap Job's Role (the test
service account cannot create Roles; the same script ran with the operator's
rights, `bootstrap.rbac: false`).

## Values

Every key is documented in [values.yaml](values.yaml). The main ones:

| Key | Default | Description |
|---|---|---|
| `dfspId` | `""` | The DFSP id, exactly as the hub operator created it in MCM (case-sensitive). |
| `nameOverride` | `""` | Overrides the chart name used in resource names. |
| `fullnameOverride` | `""` | Overrides the full name (default: the release name). |
| `switch.domain` | `""` | The switch's domain: hosts default to fspiop.<domain>, mcm.<domain>, keycloak.<domain>. |
| `switch.fspiopHost` | `""` | FSPIOP endpoint (lookups, quotes, transfers). Default: fspiop.<domain>. |
| `switch.mcmUrl` | `""` | MCM base URL. Default: https://mcm.<domain>/pm4mlapi. |
| `switch.keycloakUrl` | `""` | Keycloak base URL. Default: https://keycloak.<domain>. |
| `switch.realm` | `dfsps` | Keycloak realm holding the DFSP clients. |
| `switch.apiType` | `fspiop` | API flavour; must match the switch: fspiop or iso20022. |
| `switch.ilpVersion` | `"4"` | ILP version (4 with iso20022; Compose uses 4). |
| `switch.currency` | `""` | Settlement currency of this DFSP on the switch. |
| `switch.caBundle` | `""` | Private CA (PEM) of the switch's mcm./keycloak. hosts, if they do not use a public CA. |
| `callback.host` | `""` | Public host name the switch calls back (in the server certificate and in MCM). Only the name is needed at install: the address can come after (see preflight). |
| `callback.preflight.enabled` | `true` | management-api waits (init container) until callback.host resolves before enrolling, so a DFSP can install first, read the load balancer's address, then create the DNS record. |
| `callback.preflight.expectIP` | `""` | Also require this address among the answers (the reserved IP). Empty: any address. |
| `callback.service.enabled` | `true` | Publish the SDK's inbound port as a TCP 443 service (TLS passthrough: the SDK terminates mTLS). |
| `callback.service.type` | `LoadBalancer` | LoadBalancer (cloud, MetalLB, Octavia) or NodePort (behind an F5/HAProxy in TCP mode). |
| `callback.service.nodePort` | `null` | Fixed node port when type is NodePort. |
| `callback.service.loadBalancerSourceRanges` | `[]` | Restrict to the switch's egress IPs (CIDRs). Strongly recommended. |
| `callback.service.externalTrafficPolicy` | `Local` | Keep the switch's source IP. |
| `callback.service.loadBalancerIP` | `""` | A reserved address (OpenStack floating IP, GKE static IP, Azure static IP). Some providers want an annotation instead: see the chart README, "Callback address". |
| `callback.service.annotations` | `{}` | e.g. AWS NLB: service.beta.kubernetes.io/aws-load-balancer-type: external, aws-load-balancer-nlb-target-type: ip, aws-load-balancer-eip-allocations: eipalloc-... |
| `callback.service.keep` | `true` | Keep the Service (and so its address) on helm uninstall (helm.sh/resource-policy: keep). |
| `callback.istio.enabled` | `false` | Istio Gateway (PASSTHROUGH) + VirtualService instead of, or as well as, the Service. |
| `callback.ingressNginx.enabled` | `false` | ingress-nginx Ingress with ssl-passthrough (the controller needs --enable-ssl-passthrough). |
| `egress.whitelistIps` | `[]` | The DFSP's fixed egress IPs (bare IPv4, no CIDR): MCM gives them to the switch. |
| `mcm.clientSecret.existingSecret` | `""` | Secret holding the Keycloak client secret the hub operator issued. Create it (kubectl or External Secrets) before installing. Default name: <release>-mcm. |
| `mcm.subject` | `{...}` | Subject of the DFSP's CA and certificates. |
| `sdk.replicaCount` | `2` | 2+ in production: replicas share state through Redis. |
| `sdk.pdb` | `{...}` | PodDisruptionBudget for the SDK. |
| `sdk.preStopSeconds` | `35` | Seconds the pod keeps serving payments in flight before it stops. |
| `sdk.extraEnv` | `{}` | Extra environment variables (name: value), applied last. |
| `managementApi.extraEnv` | `{}` | Extra environment variables (name: value), applied last. |
| `coreConnector.enabled` | `true` | Deploy the DFSP's core connector with this chart. |
| `coreConnector.image.repository` | `pm4ml/mojaloop-payment-manager-simulator-core-connector` | The DFSP's own core connector image. |
| `coreConnector.imagePullSecrets` | `[]` | Pull secrets for a private registry, e.g. [{ name: my-registry }]. |
| `coreConnector.port` | `3003` | Port of the API the SDK calls (its backend API). |
| `coreConnector.extraPorts` | `[]` | Extra ports to expose on the Service, e.g. the API the core banking system calls. |
| `coreConnector.backendPath` | `""` | Path of the backend endpoint, if not at the root. |
| `coreConnector.env` | `{}` | Environment variables (name: value). |
| `coreConnector.envFromSecrets` | `{}` | Environment variables from Secrets: NAME: { secret: <name>, key: <key> }. |
| `coreConnector.envFrom` | `[]` | Whole Secrets/ConfigMaps as environment (envFrom entries). |
| `coreConnector.extraVolumes` | `[]` | Extra volumes and mounts (configuration files, certificates for the core banking API...). |
| `coreConnector.injectRedisUrl` | `true` | Inject REDIS_URL (the DFSP's Redis) into the core connector. |
| `coreConnector.podSecurityContext` | `{}` | Pod and container security context for the core connector (depends on its image). |
| `coreConnector.externalBackendEndpoint` | `""` | The SDK's backend when coreConnector.enabled is false (host:port). |
| `store.type` | `openbao` | openbao (unseals itself with a static key) or vault (Shamir key shares, as Compose). |
| `store.persistence.enabled` | `true` | Production: true. The store holds the DFSP CA and private keys. |
| `store.sealSecret` | `""` | OpenBao: Secret with the 32-byte static seal key (key unseal.key). Created by the bootstrap Job if missing (back it up!). Default: <release>-openbao-seal. |
| `redis.mode` | `ha` | ha: the redisHa subchart (Sentinel + HAProxy, password). single: one Redis (tests). external: a managed Redis whose URL is in redis.external.urlSecret. |
| `redis.ha.enabled` | `true` | Must be true when mode is ha (it enables the subchart). |
| `redis.external.urlSecret` | `""` | Secret and key holding redis:// or rediss:// URL (with its password). |
| `redis-ha` | `{...}` | redis-ha subchart values (dandydeveloper/redis-ha 4.35.5), used when redis.mode is ha. |
| `redis-ha.existingSecret` | `pm4ml-redis-auth` | Secret with the Redis password (key auth). The bootstrap Job creates it with a random password if missing. Set <release>-redis-auth when several releases share a namespace (a subchart value cannot be derived from the release name). |
| `redis-ha.haproxy.networkPolicy` | `{...}` | Only this chart's pods (label app.kubernetes.io/part-of: pm4ml-dfsp) reach HAProxy. |
| `bootstrap.enabled` | `true` | Job (one per Helm revision): initialises and configures the store, creates the DFSP CA (once, never replaced), the AppRoles and the runtime secrets. Idempotent. |
| `bootstrap.rbac` | `true` | Create the namespaced Role it needs (Secrets only). |
| `backup.enabled` | `false` | CronJob: snapshot of the store to an S3-compatible bucket. |
| `backup.s3Secret` | `""` | Secret with AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION, S3_BUCKET and optional S3_ENDPOINT. |
| `networkPolicies.enabled` | `true` | Restrict the store and the single Redis to this release's pods. |
| `monitoring.annotations` | `true` | prometheus.io/* annotations on the SDK pods (port 4004). |
| `monitoring.podMonitor.enabled` | `false` | Create a PodMonitor (Prometheus Operator). |
