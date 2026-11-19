# Next chart version: the switch-connector-sdk as an alternative to PM4ML

[JengaCore/switch-connector-sdk](https://github.com/JengaCore/switch-connector-sdk)
lets a DFSP build its connector in TypeScript against a protocol-agnostic API; the
connector speaks FSPIOP to the switch itself (mutual TLS, JWS, ILP) and enrols with
MCM through `connector-cli mcm enrol`, the way management-api does. Its
`deploy/kubernetes/connector.yaml` already runs one DFSP on Kubernetes with the same
four inputs as this chart (DFSP id, switch domain, callback host, MCM client secret).

## How it maps onto the chart

| Chart block | PM4ML mode (today) | switch-connector-sdk mode (planned) |
|---|---|---|
| Core connector | `coreConnector.*`, calls the SDK's API | **the connector itself** (`connector.image`), built by the DFSP with the SDK |
| SDK scheme adapter | `sdk.*`, 2+ replicas, Redis | not deployed: the connector speaks FSPIOP |
| Enrolment | management-api + secret store | init container `mcm enrol --wait` and sidecar `mcm enrol --watch` (same image) |
| Keys | OpenBao/Vault, snapshots | a credentials PVC (`/certs`): backup by volume snapshots, or a later store integration |
| Redis | HA / single / managed | not needed (journal on the PVC) |
| Callback edge | L4 LB / NodePort / Istio / nginx passthrough, DNS preflight | unchanged: the connector terminates mutual TLS on its port |
| NetworkPolicies, PodMonitor, security contexts | yes | yes |

Shape of the values (sketch):

```yaml
mode: switch-connector-sdk          # default: pm4ml
connector:
  image: { repository: ghcr.io/<dfsp>/connector, tag: "1.0.0" }
  credentials: { size: 64Mi, storageClass: "" }
  switchTrustConfigMap: switch-trust  # the scheme's TLS CA for MCM/Keycloak
```

## Open points before building it

- Replicas: the SDK keeps payer-side correlations in memory and one journal per DFSP,
  so one replica with `Recreate` (no PDB); scaling out needs a shared
  `CorrelationStorageEngine` first.
- Key storage: a PVC holds the DFSP CA and private keys in files; production needs
  encryption at rest, a backup schedule and a restore test, as for the store today.
- CI: an e2e against the SDK's FSPIOP simulator (`Dockerfile.simulator`) instead of a
  switch, so the payment path is tested in kind too.
