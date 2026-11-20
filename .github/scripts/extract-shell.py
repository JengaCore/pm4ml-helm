#!/usr/bin/env python3
"""Extract the shell scripts embedded in rendered manifests (ConfigMap *.sh keys
and `sh -c` container commands) so CI can run shellcheck on them.

Reads the manifests through `yq -o=json` (one JSON document per line), so only the
Python standard library is needed.

usage: extract-shell.py OUT_DIR rendered.yaml [rendered.yaml ...]
"""
import json
import os
import subprocess
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
n = 0
for path in sys.argv[2:]:
    base = os.path.splitext(os.path.basename(path))[0]
    lines = subprocess.run(["yq", "-o=json", "-I=0", ".", path], check=True,
                           capture_output=True, text=True).stdout.splitlines()
    for line in lines:
        d = json.loads(line) if line.strip() else None
        if not d:
            continue
        kind, name = d.get("kind"), d["metadata"]["name"]
        scripts = {}
        if kind == "ConfigMap":
            scripts = {k: v for k, v in (d.get("data") or {}).items() if k.endswith(".sh")}
        elif kind in ("CronJob", "Job", "Deployment", "StatefulSet"):
            spec = d["spec"]
            pod = spec["jobTemplate"]["spec"]["template"]["spec"] if kind == "CronJob" else spec["template"]["spec"]
            for c in pod.get("initContainers", []) + pod.get("containers", []):
                cmd = c.get("command") or []
                if len(cmd) >= 3 and cmd[0] == "sh" and cmd[1] in ("-c", "-ec"):
                    scripts[f"{c['name']}.sh"] = "#!/bin/sh\n" + cmd[2]
        for key, body in scripts.items():
            with open(os.path.join(out, f"{base}--{kind}-{name}--{key}"), "w") as f:
                f.write(body)
            n += 1
print(f"{n} scripts extracted")
