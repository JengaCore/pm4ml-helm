# pm4ml-helm

Helm chart for Payment Manager for Mojaloop (PM4ML), for a DFSP connecting to a
Mojaloop switch. It is the Kubernetes counterpart of
[pm4ml-docker-compose](https://github.com/JengaCore/pm4ml-docker-compose) and has
the same defaults.

The chart is in [`charts/pm4ml-dfsp`](charts/pm4ml-dfsp).

## Requirements

- Kubernetes 1.27 or later
- Helm 3.10 or later, and `kubectl` configured for the target cluster
- A default StorageClass (or set one in your values): 1 Gi for the secret store,
  2 Gi for Redis
- From the hub operator:
  - the DFSP id, as created in MCM
  - the Keycloak client secret for that DFSP
  - the switch domain, API type (`fspiop` or `iso20022`) and settlement currency
- A public host name for callbacks, for example `ml-connect.example.com`, that you
  can point at the cluster
- Outbound access on port 443 to `mcm.`, `keycloak.` and `fspiop.` under the
  switch domain

You give the hub operator the callback host name and your egress IP address(es).

## Installation

Run every command from the root of a clone of this repository.

1. Clone the repository and fetch the chart dependencies:

   ```sh
   git clone https://github.com/JengaCore/pm4ml-helm.git
   cd pm4ml-helm
   helm dependency build charts/pm4ml-dfsp
   ```

2. Create the namespace and the secret holding the client secret from the hub
   operator:

   ```sh
   kubectl create namespace dfsp
   kubectl -n dfsp create secret generic mydfsp-mcm \
     --from-literal=client-secret='<client secret>'
   ```

3. Create your values file from the example and replace every `<...>`:

   ```sh
   cp charts/pm4ml-dfsp/examples/values-production.yaml my-values.yaml
   ```

   The values you must set are listed under [Configuration](#configuration). On
   EKS, also pass `-f charts/pm4ml-dfsp/examples/values-aws.yaml`.

4. Install the chart. The release name must match the names used in the values
   file (`mydfsp` below):

   ```sh
   helm -n dfsp install mydfsp charts/pm4ml-dfsp -f my-values.yaml
   ```

5. Follow the bootstrap Job. It initialises the secret store and creates the
   DFSP's certificate authority:

   ```sh
   kubectl -n dfsp logs -f job/mydfsp-bootstrap-1
   ```

6. Store the secret `mydfsp-store-init` (unseal and recovery keys, root token)
   somewhere safe outside the cluster, then delete it. With OpenBao, also back up
   `mydfsp-openbao-seal`.

   ```sh
   kubectl -n dfsp get secret mydfsp-store-init -o yaml > store-init.yaml
   kubectl -n dfsp get secret mydfsp-openbao-seal -o yaml > openbao-seal.yaml
   kubectl -n dfsp delete secret mydfsp-store-init
   ```

7. Create the DNS record for `callback.host` pointing at the address of the
   callback service:

   ```sh
   kubectl -n dfsp get svc mydfsp-callbacks
   ```

   management-api waits for the record before it enrols.

8. Ask the hub operator to sign the DFSP's certificate request in MCM.
   management-api installs the certificates when they are signed.

### Installing from the registry

Released versions are also published as OCI artifacts, so the chart can be
installed without cloning. Steps 2 and 3 are the same. The example values are in
the chart, so pull it first:

```sh
helm pull oci://ghcr.io/jengacore/charts/pm4ml-dfsp --version 0.2.2 --untar
cp pm4ml-dfsp/examples/values-production.yaml my-values.yaml
helm -n dfsp install mydfsp oci://ghcr.io/jengacore/charts/pm4ml-dfsp \
  --version 0.2.2 -f my-values.yaml
```

Replace `0.2.2` with the version you want; the released versions are listed under
the repository's Releases. To verify the signature before installing:

```sh
cosign verify ghcr.io/jengacore/charts/pm4ml-dfsp:0.2.2 \
  --certificate-identity https://github.com/JengaCore/pm4ml-helm/.github/workflows/chart-release.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Configuration

Settings are in `values.yaml` in the chart. Secrets never go in the values file.

Required:

| Key | Description |
|---|---|
| `dfspId` | DFSP id, exactly as created in MCM (case-sensitive) |
| `switch.domain` | Switch domain |
| `switch.currency` | Settlement currency |
| `switch.apiType` | `fspiop` or `iso20022`, as the switch |
| `callback.host` | Public host name the switch calls back |
| `egress.whitelistIps` | Your fixed egress IPv4 addresses (no CIDR) |
| `mcm.clientSecret.existingSecret` | Name of the secret created in step 2 |
| `mcm.subject` | Organisation, country and locality for the certificates |
| `coreConnector.image` | Your core connector image |
| `openbao.server.volumes` | The seal secret, named `<release>-openbao-seal`. Already set in the example file |

### Secret store and Redis

The default is OpenBao and a single Valkey node. Use a preset to change either,
with one extra `-f`:

| Preset | Result |
|---|---|
| `presets/valkey-ha.yaml` | Valkey with replication, Sentinel and HAProxy |
| `presets/redis-external.yaml` | A managed Redis instead of Valkey |
| `presets/store-vault.yaml` | Vault instead of OpenBao |

```sh
helm -n dfsp install mydfsp charts/pm4ml-dfsp \
  -f charts/pm4ml-dfsp/presets/valkey-ha.yaml -f my-values.yaml
```

Use Valkey HA or a managed Redis in production. A single Valkey node that fails
causes payments in flight to fail.

### Callback

By default the chart creates a `LoadBalancer` service on port 443 that passes TLS
through to the SDK. A NodePort service, an Istio gateway and an ingress-nginx
ingress are also available under `callback.*`. Restrict
`callback.service.loadBalancerSourceRanges` to the switch's egress addresses.

The full list of values, with defaults, is in
[charts/pm4ml-dfsp/README.md](charts/pm4ml-dfsp/README.md#values).

## Several releases in one cluster

The namespace is the one you pass with `-n`, and the release name is the name you
give `helm install`. Resource names follow the release name. The client secret can
have any name: set it in `mcm.clientSecret.existingSecret` (the default is
`<release>-mcm`).

Each release needs its own:

- release name
- `dfspId`
- `callback.host`, and a DNS record for it
- client secret, issued by the hub for that DFSP

Example with two releases in separate namespaces:

```sh
kubectl create namespace bank-a
kubectl -n bank-a create secret generic bank-a-mcm --from-literal=client-secret='<secret A>'
helm -n bank-a install bank-a charts/pm4ml-dfsp -f bank-a-values.yaml

kubectl create namespace bank-b
kubectl -n bank-b create secret generic bank-b-mcm --from-literal=client-secret='<secret B>'
helm -n bank-b install bank-b charts/pm4ml-dfsp -f bank-b-values.yaml
```

Each release has its own secret store, Redis and callback service. If releases
share a namespace, each also needs its own OpenBao seal secret, because the chart
refuses to render the shared default:

```yaml
openbao:
  server:
    volumes:
      - { name: seal, secret: { secretName: bank-b-openbao-seal, defaultMode: 0440 } }
```

The resource requirements below are per release.

## Resource requirements

These are the chart's default requests, with two replicas each of the SDK and the
core connector.

| Setup | CPU | Memory | Memory limit | Disk |
|---|---|---|---|---|
| OpenBao or Vault, single Valkey | 0.95 | 2.4 GiB | 4.75 GiB | 3 GiB |
| OpenBao or Vault, Valkey HA | 1.15 | 2.9 GiB | 5.75 GiB | 7 GiB |

The core connector accounts for 0.2 CPU and 1 GiB of the memory request. Size it
for your own image. Jobs are short-lived and not included. Spread replicas over at
least two nodes, or three with Valkey HA.

## Upgrading

```sh
helm dependency build charts/pm4ml-dfsp
helm -n dfsp upgrade mydfsp charts/pm4ml-dfsp -f my-values.yaml
```

Chart 0.2.0 replaced the secret store and Redis templates of 0.1.x. Upgrading
from 0.1.x needs a backup and a restore; the steps are in the
[chart README](charts/pm4ml-dfsp/README.md).

## Backup and restore

The backup CronJob (`backup.enabled`) writes secret store snapshots to any S3 API.
The restore Job (`restore.enabled`) restores the newest snapshot. Keep the OpenBao
seal secret separately: a snapshot cannot be restored without it. Details are in
the [chart README](charts/pm4ml-dfsp/README.md#backups-and-restore).

## Uninstalling

```sh
helm -n dfsp uninstall mydfsp
```

The callback service is kept by default, so that its address survives a
reinstall (`callback.service.keep`). Persistent volumes are not deleted.

## Further documentation

- [Chart README](charts/pm4ml-dfsp/README.md): values reference, certificates and
  renewal, callback addresses, validation results
- [docs/PRODUCTION.md](docs/PRODUCTION.md)
- [docs/SECRET-BACKENDS.md](docs/SECRET-BACKENDS.md)
- [docs/REVIEW-2026-11.md](docs/REVIEW-2026-11.md): review of ThitsaX/pm4ml-deployment
- [docs/NEXT-SWITCH-CONNECTOR-SDK.md](docs/NEXT-SWITCH-CONNECTOR-SDK.md)

Chart checks run on every pull request (`.github/workflows/chart-ci.yml`) and can
be run locally with `.github/scripts/chart-checks.sh`.
