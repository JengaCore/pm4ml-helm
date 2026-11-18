#!/usr/bin/env bash
# helm --post-renderer: reads the rendered chart on stdin, writes the patched
# manifests on stdout.
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$dir"/*.yaml "$work/"
cat > "$work/all.yaml"
# The patches name this release's Secrets <release>-tls, <release>-runtime...
# They are written for the release "pm4ml"; any other release name is read from
# the chart output and substituted, so several DFSPs can share a namespace.
release="$(sed -n 's/^ *app.kubernetes.io\/instance: *"\{0,1\}\([a-z0-9-]*\)"\{0,1\} *$/\1/p' "$work/all.yaml" | head -n1)"
if [ -n "$release" ] && [ "$release" != "pm4ml" ]; then
  for f in "$work"/sdk-scheme-adapter.yaml "$work"/management-api.yaml "$work"/pdb.yaml; do
    sed -i.bak -e "s/pm4ml-/${release}-/g" -e "s/instance: pm4ml$/instance: ${release}/" "$f" && rm -f "$f.bak"
  done
fi
# Helm cannot unset a subchart value from the parent (a `null` override renders
# as the string "null"). Drop every env entry whose value is "null", so an
# overlay can remove a variable by setting it to null.
kubectl kustomize "$work" \
  | perl -0pe 's/^( *)- name: [A-Za-z0-9_]+\n\1  value: "null"\n//mg'
