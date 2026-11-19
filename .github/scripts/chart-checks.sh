#!/usr/bin/env bash
# Static checks of charts/pm4ml-dfsp and the repository's manifests and scripts. CI
# runs this; run it locally before pushing (tools: .github/scripts/install-tools.sh).
set -euo pipefail
CHART=charts/pm4ml-dfsp; K8S=1.31.0
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
step() { echo; echo "=== $*"; }
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

step "dependencies (verified against Chart.lock)"
helm dependency build "$CHART" >/dev/null

step "lint and render every CI values file"
for f in "$CHART"/ci/*-values.yaml; do
  n=$(basename "$f" .yaml)
  helm lint --strict "$CHART" -f "$f" >/dev/null
  helm template ci "$CHART" -n dfsp -f "$f" > "$OUT/$n.yaml"
  echo "ok $n"
done

step "the chart refuses unsafe or inconsistent values"
must_fail() { # message-fragment, helm args...
  local want="$1"; shift
  if out=$(helm template other "$CHART" -f "$CHART/ci/openbao-redis-ha-values.yaml" "$@" 2>&1); then
    echo "expected a failure ($want) for: $*" >&2; exit 1
  fi
  grep -q "$want" <<<"$out" || { echo "wrong failure for $*: $out" >&2; exit 1; }
  echo "refused: $*"
}
must_fail "set it to other-redis-auth"       --set redis-ha.existingSecret=pm4ml-redis-auth   # shared default password
must_fail "set redis.ha.enabled: false"      --set redis-ha.existingSecret=x --set redis.mode=single
must_fail "set redis.ha.enabled: true"       --set redis-ha.existingSecret=x --set redis.ha.enabled=false
must_fail "acceptDataLoss"                   --set redis-ha.existingSecret=x --set store.persistence.enabled=false
must_fail "dfspId is required"               --set redis-ha.existingSecret=x --set dfspId=

step "Kubernetes schemas ($K8S, CRDs from the datree catalog)"
kubeconform -strict -summary -kubernetes-version "$K8S" -schema-location default -schema-location "$CRDS" "$OUT"/*.yaml
kubeconform -strict -summary -kubernetes-version "$K8S" -ignore-missing-schemas \
  jobs/*.yaml secret-store/*/*.yaml secret-store/backup-cronjob.yaml redis/redis.yaml monitoring/*.yaml networking/*.yaml test-backend/*.yaml

step "kube-linter on this chart's manifests (subcharts excluded)"
for f in "$OUT"/*.yaml; do
  awk -v RS='\n---\n' -v ORS='\n---\n' '/# Source: pm4ml-dfsp\/templates\//' "$f" > "${f%.yaml}.own"
done
kube-linter lint "$OUT"/*.own

step "shellcheck: scripts in the repository and in the rendered manifests"
python3 .github/scripts/extract-shell.py "$OUT/sh" "$OUT"/*.yaml
find "$OUT/sh" -name '*redis-ha*' -delete     # third-party (dandydeveloper/redis-ha)
shellcheck -s sh -S warning "$OUT"/sh/*
shellcheck -S warning scripts/*.sh secret-store/*.sh test-backend/*.sh .github/scripts/*.sh post-render/*.sh

step "README values table is generated (helm-docs)"
helm-docs --chart-search-root "$CHART" --template-files README.md.gotmpl >/dev/null 2>&1
git diff --exit-code -- "$CHART/README.md" || { echo "run helm-docs and commit $CHART/README.md" >&2; exit 1; }

step "workflows (actionlint)"
actionlint

echo; echo "all checks passed"
