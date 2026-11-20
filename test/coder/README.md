# Re-running the UAT tests from a Coder workspace, with Claude Code

How the November 2026 validation was run, so anyone can run it again: the
`pm4ml-dfsp` chart (this repository) and the switch connector SDK
(`JengaCore/switch-connector-sdk`), each as a test DFSP on the **Coder cluster**,
paying and being paid by other DFSPs on **sbx UAT** (ISO 20022, GMD). The results
are in the chart README's [Validation](../../charts/pm4ml-dfsp/README.md#validation)
section and in the SDK pull requests (#20 to #26).

Everything here is test material: sslip.io host names, emptyDir volumes where a
pod's data may be lost, an S3 mock. Nothing in this folder holds a secret.

| File | What it is |
|---|---|
| `values-uat.yaml` | Chart values for one test DFSP (simulator as core connector, S3 mock backups) |
| `bootstrap-from-workspace.sh` | Runs the chart's bootstrap script from the workspace (the workspace cannot create the Job's Role) |
| `tester.yaml`, `transfer.sh`, `load.sh` | A pod inside the cluster that drives payments through a payment manager's SDK |
| `sdk/connector.yaml`, `sdk/load-app.sh` | One SDK connector as a DFSP, and loading a locally built image into it |
| `sdk/cluster.yaml`, `sdk/renewer.sh`, `sdk/seed-renewer-state.sh` | The same DFSP as 3 replicas, with its single certificate renewer |
| `sdk/valkey.yaml`, `sdk/send.sh` | Optional Valkey for the connector's journal; payments through the connector |

## What you need

| | |
|---|---|
| A Coder workspace | The `agent-workspace` template: `kubectl`, `helm`, `docker`, `node`, `pnpm`, `gh`, and Claude Code. Its kubeconfig reaches the Coder cluster (namespace `default`): it can create workloads, Secrets and load balancers, **not** Roles or RoleBindings |
| Checkouts | This repository, and `JengaCore/switch-connector-sdk` for the SDK tests (`pnpm install && pnpm build` once) |
| A hub operator | Someone with hub-operator rights on sbx UAT (MCM portal, or the `ops` box's helpers). Every hub-side step below is theirs |
| A DFSP id per test DFSP | Admitted by the hub operator in MCM, with a GMD account, a net debit cap and funds |
| Test parties | An MSISDN per DFSP (the `25677000xxx` range), registered in the account lookup service (a payment manager registers its own through the simulator; the SDK connector with `REGISTER_PARTIES=true`) |

The peers used last time were `pm4mlhelm01` (MSISDN `25677000001`) and `pm4mlhelm04`
(`25677000004`); any two DFSPs on UAT will do.

## Hub-side steps (hub operator)

For each new test DFSP, in this order:

1. Admit it in MCM (`dfsp_admission.sh` in switch-iac, or the MCM portal): this creates its Keycloak client. Hand over the **client secret** (to the person running the test, never in a chat or a ticket).
2. In the finance portal: GMD account, net debit cap, funds.
3. When the DFSP has enrolled (below): **sign its client certificate request** in MCM. Again for every renewal.
4. If its callback URL does not show in MCM (a payment manager registers it; the SDK's `mcm enrol` too since PR #22), set `https://<callback host>/` as its ingress endpoint, and let the reconciler run.

## The payment manager chart

```sh
cd test/coder
export NS=default R=dfsp5           # release name; DFSP id in the values file
cp values-uat.yaml values-$R.yaml   # fill in every <...>
kubectl -n $NS create secret generic $R-mcm --from-literal=client-secret='<from the hub operator>'
kubectl -n $NS create configmap $R-sim-rules --from-literal=rules.json='[]'
# The S3 mock and its Secret, once per namespace (see values-uat.yaml for the keys).
helm upgrade --install $R ../../charts/pm4ml-dfsp -n $NS -f values-$R.yaml --set bootstrap.enabled=false --set restore.enabled=false
kubectl -n $NS get svc $R-callbacks          # the load balancer's address -> callback.host / expectIP, then upgrade again
sh bootstrap-from-workspace.sh $NS $R values-$R.yaml openbao   # once the store pod runs; again after store changes
```

Then management-api enrols with MCM; the hub operator signs; the `states` of
management-api reach `HUB_CLIENT_CERT_SIGNED` and `DFSP_CLIENT_CERT_CONFIGURED`.

Payments, from the tester pod:

```sh
NS=$NS envsubst < tester.yaml | kubectl apply -f -
kubectl -n $NS cp transfer.sh payment-tester:/tmp/transfer.sh; kubectl -n $NS cp load.sh payment-tester:/tmp/load.sh
kubectl -n $NS exec payment-tester -- sh /tmp/transfer.sh http://$R-sdk:4001 <own msisdn> 25677000001 1 GMD
kubectl -n $NS exec payment-tester -- sh /tmp/load.sh http://$R-sdk:4001 <own msisdn> 25677000001 1 GMD 100 10 /tmp/out.txt
```

(The SDK Service is `<release>-sdk` on chart 0.2; check `kubectl get svc`.) Receiving: run
`load.sh` against a peer's SDK towards this DFSP's MSISDN.

| Test | How |
|---|---|
| Send / receive | `load.sh` both ways; compare the ledger positions in the finance portal |
| Pod killed mid-run | start a `load.sh`, then `kubectl delete pod <an sdk pod>` (and `--grace-period=0 --force` for a crash) |
| Redis failover | with `presets/valkey-ha.yaml`: delete the Valkey primary mid-run; check each failed payment with `GET /transfers/{id}` on the SDK |
| NetworkPolicies | from a pod without the tester label, `curl` the SDK (4001), management-api, store and Redis: all must be refused |
| Backup and restore | trigger the backup CronJob (`kubectl create job --from=cronjob/$R-store-backup b1`), delete the store's PVC and pod, then the chart README's [restore steps](../../charts/pm4ml-dfsp/README.md#backups-and-restore); the CA fingerprint must not change |
| Certificate renewal by hand | the chart README's [Renewing or replacing the client certificate by hand](../../charts/pm4ml-dfsp/README.md#renewing-or-replacing-the-client-certificate-by-hand); the hub operator signs |
| Certificate check | `kubectl create job --from=cronjob/$R-cert-check c1` and read its log |

The restore Job and the bootstrap Job normally run with their own Role
(`restore.rbac`, `bootstrap.rbac`); on this cluster their scripts run with your
rights instead, which tests the same scripts but not the Roles (CI on kind does).

## The SDK connector

Build once in the SDK checkout (`pnpm install && pnpm build`), then:

```sh
cd test/coder/sdk
export SDK=~/switch-connector-sdk NS=default DFSP_ID=sdkhelm02 SWITCH_DOMAIN=uat.sandbox.jengacore.com \
       MSISDN=25677000006 CURRENCY=GMD CALLBACK_HOST=sdkhelm02.<a-b-c-d>.sslip.io
kubectl -n $NS create secret generic $DFSP_ID-mcm --from-literal=client-secret='<from the hub operator>'
kubectl -n $NS create secret generic $DFSP_ID-ilp --from-literal=secret=$(openssl rand -hex 32)
envsubst < connector.yaml | kubectl apply -f -
kubectl -n $NS get svc $DFSP_ID-callbacks    # address -> CALLBACK_HOST, re-apply
sh load-app.sh deployment                    # the "mcm-enrol" init container then waits for the hub's signature
```

| Test | How |
|---|---|
| Send | `kubectl -n $NS cp send.sh payment-tester:/tmp/send.sh`, then `sh /tmp/send.sh http://$DFSP_ID:3001 $MSISDN 25677000001 GMD 20 10 /tmp/s.txt` in the tester |
| Receive | `load.sh` from a payment manager's SDK to `$MSISDN` |
| Cluster mode (3 replicas) | `sh seed-renewer-state.sh`; start `renewer.sh` (keep it running); `kubectl -n $NS scale deploy/$DFSP_ID --replicas=0`; create the `$DFSP_ID-cluster` token Secret; `envsubst < cluster.yaml \| kubectl apply -f -`; `sh load-app.sh statefulset`; then the send/receive tests; check `switch_connector_cluster_forwards_total` on each replica's `:3001/metrics` |
| A replica lost | during a load, `kubectl delete pod $DFSP_ID-1`: only the payments it owned fail until it is back (its app must be loaded again: `load-app.sh statefulset`) |
| Renewal in cluster mode | stop `renewer.sh`, start it with `MCM_RENEW_DAYS=400`; the hub operator signs the new request; every replica logs `TLS credentials changed on disk — reloaded` within about two minutes, and `sha256sum /certs/client.crt` is the same on all three |
| Valkey (journal, pending requests to pay) | create the `$DFSP_ID-valkey` Secret and `envsubst < valkey.yaml \| kubectl apply -f -`; `cluster.yaml` already reads `REDIS_URL_FILE`. On ISO 20022 the journal holds request to pay and bulk only |
| Request to pay | the connector's `POST :3001/request-to-pay`; between two SDK DFSPs it completes; towards a payment manager in ISO 20022 mode it does not (the payment manager refuses it: adr/0003 in the SDK) |

## Running it with Claude Code

Open the workspace, `cd` to this repository (or the SDK checkout) and start `claude`.
Claude Code reads the repository's `CLAUDE.md` and follows its rules: it runs the
read-only preflight before building, never reads the `artifacts/` credentials of
switch-iac, and **asks you before anything outward or hard to undo**: hub-operator
actions on UAT (signing a certificate request, admitting a DFSP, setting an
endpoint), deleting volumes or participants, pushing, and anything on `main`.

Give it the goal and the DFSP, not the commands; for example:

- *"Read test/coder/README.md. Install a test payment manager as release dfsp5 (DFSP
  id pm4mlhelm05, MSISDN 25677000005) on the Coder cluster against sbx UAT, run 20
  payments each way with pm4mlhelm01, and report the results in a table."*
- *"Re-run the backup and restore test on dfsp5 and check the CA fingerprint is unchanged."*
- *"Run the SDK connector as sdkhelm02 from my switch-connector-sdk checkout, then
  move it to 3 replicas with the renewer, force a renewal, and check every replica
  picked it up."*
- *"Stop the test DFSPs on Coder"* / *"delete their volumes"* when you are done.

What to expect:

- It puts its scratch files (rendered values, logs) in its job directory, not in the repository.
- Secrets are created from values you give it, or read from the cluster into 0600
  files it shreds afterwards; it does not print them. Hand it the MCM client secret
  through a file or `! kubectl create secret ...` in the session, not in the prompt.
- It waits on the hub operator's signature: it tells you which request to sign, or,
  with access to the `ops` box and your approval, signs it itself.
- Long runs (load, renewals) go to the background, and it reports when they finish.
- It ends with the results, what it left running, and what to clean up.

## Cleaning up

```sh
helm -n $NS uninstall $R                     # the callback Service is kept (callback.service.keep): delete it to free the address
kubectl -n $NS delete pvc -l app.kubernetes.io/instance=$R
kubectl -n $NS delete deploy,sts,svc,secret -l dfsp=$DFSP_ID     # SDK connector; also its -mcm, -ilp, -cluster, -tls*, -valkey Secrets by name
kubectl -n $NS delete pod payment-tester
```

On the hub side, the hub operator removes or disables the test participants when
they are no longer needed. A stopped DFSP whose store volume was deleted must enrol
again (new CA, new certificate request) before it can be used.
