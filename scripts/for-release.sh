#!/usr/bin/env bash
# Prints repo manifests or values files for a Helm release other than "pm4ml",
# so several DFSPs can live in one namespace. Every name the repo derives from
# the release (pm4ml-redis, pm4ml-vault, pm4ml-tls, the chart's pm4ml-* Services
# and instance: pm4ml labels) follows.
#
#   ./scripts/for-release.sh dfsp2 redis/redis.yaml | kubectl -n $NS apply -f -
#   ./scripts/for-release.sh dfsp2 helm-values/values-pm4ml.yaml > helm-values/values-dfsp2.yaml
set -euo pipefail
R="${1:?usage: for-release.sh <release> <file>...}"; shift
[[ "$R" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { echo "release must be a DNS label" >&2; exit 1; }
sed -e "s/pm4ml-/${R}-/g" -e "s/instance: pm4ml\b/instance: ${R}/g" "$@"
