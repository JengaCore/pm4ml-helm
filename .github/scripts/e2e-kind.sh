#!/usr/bin/env bash
# End-to-end checks of charts/pm4ml-dfsp on a throwaway cluster (kind in CI).
# No switch: management-api cannot enrol, so this checks what the chart does by itself:
#   - the bootstrap Job, with its own namespaced Role, initialises and configures the
#     store and creates every Secret the pods wait for;
#   - the store is unsealed, holds the DFSP CA, and keeps it across a helm upgrade
#     (a second bootstrap run) and a store pod restart;
#   - Redis answers with the password and refuses without it;
#   - the NetworkPolicies let the core connector reach the SDK's outbound API and
#     block any other pod (when the cluster's network plugin enforces them).
# usage: e2e-kind.sh <values file> <openbao|vault> <ha|single> [namespace]
set -euo pipefail
VALUES="$1"; KIND="$2"; MODE="$3"; NS="${4:-e2e}"; R=ci; CHART=charts/pm4ml-dfsp
k() { kubectl -n "$NS" "$@"; }
step() { echo; echo "=== $*"; }
fail() { echo "FAIL: $*" >&2; dump; exit 1; }
dump() {
  k get pods,jobs,secrets -o wide || true
  for p in $(k get pods -o name); do echo "--- $p"; k logs "$p" --all-containers --tail=30 2>&1 | cut -c1-300 || true; done
}
# Runs a one-shot pod and prints its log. Not `kubectl run -i`: its output is lost when
# the container ends before kubectl attaches.
run_pod() { # <image> <labels> <uid> <command> [env JSON array]
  local name="probe-$RANDOM"
  k run "$name" --restart=Never --image="$1" --labels="$2" --overrides='{"spec":{
      "securityContext":{"runAsNonRoot":true,"runAsUser":'"$3"',"seccompProfile":{"type":"RuntimeDefault"}},
      "containers":[{"name":"'"$name"'","image":"'"$1"'","command":["sh","-c","'"$4"'"],"env":'"${5:-[]}"'}]}}' >/dev/null
  for _ in $(seq 1 60); do
    case "$(k get pod "$name" -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac; sleep 2
  done
  k logs "$name" 2>/dev/null || true
  k delete pod "$name" --wait=false >/dev/null 2>&1 || true
}
store() { k exec "$R-vault-0" -- wget -qO- "http://127.0.0.1:8200/v1/$1"; }
ca_fp() { store pki/cert/ca | jq -r .data.certificate | sha256sum | cut -c1-64; }   # SHA-256 of the CA PEM

step "install ($KIND, redis $MODE)"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
k create secret generic "$R-mcm" --from-literal=client-secret=e2e-not-a-secret --dry-run=client -o yaml | k apply -f -
helm upgrade --install "$R" "$CHART" -n "$NS" -f "$VALUES" --timeout 10m

step "bootstrap Job 1"
k wait --for=condition=complete "job/$R-bootstrap-1" --timeout=600s || fail "bootstrap Job 1 did not complete"
k logs "job/$R-bootstrap-1"
for s in runtime vault-approle store-backup jws tls store-init; do
  k get secret "$R-$s" -o name >/dev/null || fail "Secret $R-$s missing"
done
[ "$KIND" = openbao ] && { k get secret "$R-openbao-seal" -o name >/dev/null || fail "seal Secret missing"; }
url=$(k get secret "$R-runtime" -o jsonpath='{.data.cache-url}' | base64 -d)
[ -n "$url" ] || fail "empty cache-url"
[ "$(store sys/seal-status | jq -r .sealed)" = false ] || fail "store sealed"
FP1=$(ca_fp); echo "DFSP CA: $FP1"
[ -n "$FP1" ] || fail "no DFSP CA"

step "Redis"
# Generous timeouts: first image pulls on a fresh CI node are slow.
k rollout status deploy/"$R-management-api" --timeout=900s || fail "management-api not ready"
RH="$R-redis"; [ "$MODE" = ha ] && RH="$R-redis-ha-haproxy"
if [ "$MODE" = ha ]; then
  k rollout status statefulset/"$R-redis-ha-server" --timeout=600s
  k rollout status deploy/"$R-redis-ha-haproxy" --timeout=600s
  sleep 10   # HAProxy marks the master UP after its first health checks
else k rollout status statefulset/"$R-redis" --timeout=600s; fi
redis_probe() { # <labels> <command> [auth Secret] -> output
  local env='[]'
  # The password reaches the probe from the Secret (env valueFrom), never on a command line.
  [ -n "${3:-}" ] && env='[{"name":"REDISCLI_AUTH","valueFrom":{"secretKeyRef":{"name":"'"$3"'","key":"auth"}}}]'
  run_pod redis:7.2.5-alpine "$1" 999 "$2" "$env"
}
OWN="app.kubernetes.io/part-of=pm4ml-dfsp,app.kubernetes.io/instance=$R,app.kubernetes.io/name=probe"
if [ "$MODE" = ha ]; then
  ok=""; for _ in 1 2 3; do
    redis_probe "$OWN" "timeout 10 redis-cli -h $RH ping" "$R-redis-auth" | grep -q PONG && { ok=1; break; }
    sleep 10
  done
  [ -n "$ok" ] || fail "Redis with the password"
  redis_probe "$OWN" "timeout 10 redis-cli -h $RH get x" | grep -q NOAUTH || fail "Redis without the password must be refused"
  echo "Redis: password required"
else
  redis_probe "$OWN" "timeout 10 redis-cli -h $RH ping" | grep -q PONG || fail "Redis"
fi
# grep, not tail: the shell's "Terminated" (stderr) can land after BLOCKED in the log.
if redis_probe "app.kubernetes.io/name=intruder" "timeout 8 redis-cli -h $RH ping || echo BLOCKED" | grep -q BLOCKED; then
  other=BLOCKED; else other=REACHABLE; fi
echo "Redis from a pod of another app: $other"
if [ "$other" != BLOCKED ] && [ "${REQUIRE_NETPOL:-}" = 1 ]; then fail "Redis reachable from any pod"; fi

step "NetworkPolicies"
# Without a switch the SDK does not become ready (no peer JWS keys), so the policy is
# checked on management-api's control channel (4005): only the SDK may reach it.
# Same template mechanism as the SDK's outbound API (4001: core connector only).
probe() { # <label app.kubernetes.io/name> <host> <port> -> OPEN|CLOSED
  run_pod busybox:1.36.1 "app.kubernetes.io/name=$1,app.kubernetes.io/instance=$R" 65534 \
    "nc -z -w 5 $2 $3 && echo OPEN || echo CLOSED" | grep -E 'OPEN|CLOSED' | tail -1
}
a=$(probe sdk-scheme-adapter "$R-management-api" 4005); b=$(probe intruder "$R-management-api" 4005)
echo "management-api:4005 from an SDK-labelled pod: $a, from another pod: $b"
[ "$a" = OPEN ] || fail "the SDK cannot reach management-api"
if [ "$b" = OPEN ]; then
  [ "${REQUIRE_NETPOL:-}" = 1 ] && fail "NetworkPolicy not enforced"
  echo "WARNING: this cluster's network plugin does not enforce NetworkPolicies"
fi

step "upgrade: bootstrap Job 2 must change nothing"
helm upgrade "$R" "$CHART" -n "$NS" -f "$VALUES" --set sdk.logLevel=debug --timeout 10m
k wait --for=condition=complete "job/$R-bootstrap-2" --timeout=600s || fail "bootstrap Job 2"
[ "$(ca_fp)" = "$FP1" ] || fail "DFSP CA changed on upgrade"

step "store pod restart"
k delete pod "$R-vault-0" --wait=true
# The StatefulSet recreates it; wait for it to exist, then to run (not to be Ready: a
# sealed Vault never is), then for the API to answer. Every wait is bounded.
for _ in $(seq 1 60); do k get pod "$R-vault-0" >/dev/null 2>&1 && break; sleep 2; done
k wait --for=jsonpath='{.status.containerStatuses[0].started}'=true pod/"$R-vault-0" --timeout=600s \
  || fail "store pod did not start after restart"
for _ in $(seq 1 150); do store sys/seal-status >/dev/null 2>&1 && break; sleep 2; done
store sys/seal-status >/dev/null 2>&1 || fail "store does not answer after restart"
if [ "$KIND" = openbao ]; then
  for _ in $(seq 1 30); do [ "$(store sys/seal-status | jq -r .sealed)" = false ] && break; sleep 2; done
  [ "$(store sys/seal-status | jq -r .sealed)" = false ] || fail "OpenBao did not unseal itself"
else
  [ "$(store sys/seal-status | jq -r .sealed)" = true ] || fail "Vault should be sealed after a restart"
  for i in 0 1 2; do
    key=$(k get secret "$R-store-init" -o jsonpath='{.data.init\.json}' | base64 -d | jq -r ".keys_base64[$i]")
    # shellcheck disable=SC2016  # $K expands in the pod's shell
    k exec -i "$R-vault-0" -- sh -c 'read -r K; VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal "$K" >/dev/null' <<<"$key"
  done
fi
[ "$(ca_fp)" = "$FP1" ] || fail "DFSP CA lost across a store restart"

step "backup to S3, lose the store's volume, restore Job (with its Role)"
# A throwaway S3 API in the namespace.
k create deployment s3 --image=adobe/s3mock:3.12.0 --port=9090 >/dev/null
k set env deployment/s3 initialBuckets=backups >/dev/null
k expose deployment s3 --port=9090 >/dev/null
k create secret generic "$R-backup-s3" --from-literal=AWS_ACCESS_KEY_ID=e2e --from-literal=AWS_SECRET_ACCESS_KEY=e2e \
  --from-literal=AWS_DEFAULT_REGION=us-east-1 --from-literal=S3_BUCKET=backups --from-literal=S3_ENDPOINT=http://s3:9090 >/dev/null
k rollout status deploy/s3 --timeout=600s
BK=(--set backup.enabled=true --set "backup.s3Secret=$R-backup-s3")
helm upgrade "$R" "$CHART" -n "$NS" -f "$VALUES" "${BK[@]}" --timeout 10m
k create job backup-now --from=cronjob/"$R-store-backup" >/dev/null
k wait --for=condition=complete job/backup-now --timeout=600s || fail "backup Job"
k logs job/backup-now --all-containers | tail -2
unseal_vault() {
  for i in 0 1 2; do
    key=$(k get secret "$R-store-init" -o jsonpath='{.data.init\.json}' | base64 -d | jq -r ".keys_base64[$i]")
    # shellcheck disable=SC2016  # $K expands in the pod's shell
    k exec -i "$R-vault-0" -- sh -c 'read -r K; VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal "$K" >/dev/null' <<<"$key"
  done
}
k scale statefulset "$R-vault" --replicas=0 >/dev/null
k wait --for=delete pod/"$R-vault-0" --timeout=300s
k delete pvc "data-$R-vault-0" --wait=true --timeout=300s
k scale statefulset "$R-vault" --replicas=1 >/dev/null
for _ in $(seq 1 60); do k get pod "$R-vault-0" >/dev/null 2>&1 && break; sleep 2; done
k wait --for=jsonpath='{.status.containerStatuses[0].started}'=true pod/"$R-vault-0" --timeout=600s || fail "new store pod"
for _ in $(seq 1 150); do store sys/seal-status >/dev/null 2>&1 && break; sleep 2; done
[ "$(store sys/init | jq -r .initialized)" = false ] || fail "the new volume should be empty"
helm upgrade "$R" "$CHART" -n "$NS" -f "$VALUES" "${BK[@]}" --set restore.enabled=true --timeout 10m
REV=$(helm -n "$NS" history "$R" -o json | jq -r '.[-1].revision')
k get job "$R-bootstrap-$REV" >/dev/null 2>&1 && fail "bootstrap must not run during a restore"
# complete or failed, whichever comes first (backoffLimit 0: a failure is final)
for _ in $(seq 1 120); do
  st=$(k get job "$R-store-restore-$REV" -o jsonpath='{.status.succeeded}/{.status.failed}')
  case "$st" in 1/*) break ;; */1) k logs "job/$R-store-restore-$REV"; fail "restore Job failed" ;; esac; sleep 5
done
[ "$(k get job "$R-store-restore-$REV" -o jsonpath='{.status.succeeded}')" = 1 ] || fail "restore Job did not finish"
k logs "job/$R-store-restore-$REV"
[ "$KIND" = vault ] && unseal_vault
for _ in $(seq 1 90); do [ "$(store sys/seal-status | jq -r .sealed)" = false ] && break; sleep 2; done
[ "$(ca_fp)" = "$FP1" ] || fail "restore did not bring back the same DFSP CA"
echo "restored: same DFSP CA"
# Back to normal: the next revision's bootstrap Job runs on the restored store.
helm upgrade "$R" "$CHART" -n "$NS" -f "$VALUES" "${BK[@]}" --timeout 10m
k wait --for=condition=complete "job/$R-bootstrap-$((REV + 1))" --timeout=600s || fail "bootstrap after the restore"
[ "$(ca_fp)" = "$FP1" ] || fail "bootstrap changed the DFSP CA of the restored store"
k rollout restart deploy/"$R-management-api" >/dev/null
k rollout status deploy/"$R-management-api" --timeout=600s || fail "management-api after the restore"
echo "bootstrap after the restore: CA unchanged, management-api up"

step "PASS ($KIND, redis $MODE)"
