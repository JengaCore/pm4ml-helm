#!/bin/sh
# TEST ONLY. Build the connector image from a switch-connector-sdk checkout and copy its
# /app and /cli into the pods' "load" init containers (the image is not in a registry the
# Coder cluster can pull from).
#   SDK=~/switch-connector-sdk NS=default DFSP_ID=sdkhelm02 sh load-app.sh deployment|statefulset
# deployment: restarts the single connector. statefulset: loads every replica waiting in "load".
set -eu
KIND="${1:?deployment or statefulset}"; NS="${NS:?}"; DFSP_ID="${DFSP_ID:?}"; SDK="${SDK:?path to a switch-connector-sdk checkout}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
( cd "$SDK" && docker build -q --target connector -t "switch-connector-test:$DFSP_ID" . >/dev/null )
cid=$(docker create "switch-connector-test:$DFSP_ID"); docker cp "$cid:/app" - > "$T/app.tar"; docker cp "$cid:/cli" - > "$T/cli.tar"; docker rm "$cid" >/dev/null
[ "$KIND" = deployment ] && kubectl -n "$NS" rollout restart "deployment/$DFSP_ID" >/dev/null
loaded=0
for _ in $(seq 1 90); do
  for P in $(kubectl -n "$NS" get pods -l "dfsp=$DFSP_ID,app=switch-connector" -o jsonpath='{range .items[?(@.status.initContainerStatuses[0].state.running)]}{.metadata.name}{"\n"}{end}'); do
    kubectl -n "$NS" cp "$T/app.tar" "$P:/app/app.tar" -c load
    if kubectl -n "$NS" get pod "$P" -o jsonpath='{.spec.initContainers[0].volumeMounts[*].mountPath}' | grep -q /cli; then
      kubectl -n "$NS" cp "$T/cli.tar" "$P:/cli/cli.tar" -c load
      kubectl -n "$NS" exec "$P" -c load -- sh -c 'cd /cli && tar -xf cli.tar --strip-components=1 && rm cli.tar && touch .ready'
    fi
    kubectl -n "$NS" exec "$P" -c load -- sh -c 'cd /app && tar -xf app.tar --strip-components=1 && rm app.tar && touch .ready'
    loaded=$((loaded + 1)); echo "loaded $P"
  done
  want=$(kubectl -n "$NS" get pods -l "dfsp=$DFSP_ID,app=switch-connector" --no-headers 2>/dev/null | grep -c Init || true)
  [ "$loaded" -gt 0 ] && [ "$want" -eq 0 ] && break
  sleep 3
done
kubectl -n "$NS" get pods -l "dfsp=$DFSP_ID,app=switch-connector"
