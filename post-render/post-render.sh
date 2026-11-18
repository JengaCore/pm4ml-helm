#!/usr/bin/env bash
# helm --post-renderer: reads the rendered chart on stdin, writes the patched
# manifests on stdout.
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$dir"/*.yaml "$work/"
cat > "$work/all.yaml"
# Helm cannot unset a subchart value from the parent (a `null` override renders
# as the string "null"). Drop every env entry whose value is "null", so an
# overlay can remove a variable by setting it to null.
kubectl kustomize "$work" \
  | perl -0pe 's/^( *)- name: [A-Za-z0-9_]+\n\1  value: "null"\n//mg'
