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
ca_fp() { store pki/cert/ca | jq -r .data.certificate | openssl x509 -noout -fingerprint -sha256; }

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
k rollout status deploy/"$R-management-api" --timeout=300s || fail "management-api not ready"
RH="$R-redis"; [ "$MODE" = ha ] && RH="$R-redis-ha-haproxy"
if [ "$MODE" = ha ]; then
  k rollout status statefulset/"$R-redis-ha-server" --timeout=300s
  k rollout status deploy/"$R-redis-ha-haproxy" --timeout=300s
  sleep 10   # HAProxy marks the master UP after its first health checks
else k rollout status statefulset/"$R-redis" --timeout=300s; fi
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
k wait --for=condition=ready pod/"$R-vault-0" --timeout=300s || true
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

step "PASS ($KIND, redis $MODE)"
