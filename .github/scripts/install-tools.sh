#!/usr/bin/env bash
# Installs the CI tools at pinned versions, each checked against a pinned SHA-256
# (no install scripts piped to a shell, no "latest"). Bump a version together with
# its checksum, taken from the release's own checksum file where it publishes one.
#   install-tools.sh <dir> helm kubeconform kube-linter helm-docs shellcheck actionlint kind docker
set -euo pipefail
DIR="$1"; shift; mkdir -p "$DIR"; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fetch() { # url sha256 file
  curl -sSfL --retry 3 -o "$W/$3" "$1"
  echo "$2  $W/$3" | sha256sum -c --quiet - || { echo "checksum mismatch: $1" >&2; exit 1; }
}
for t in "$@"; do
  case "$t" in
    helm)        fetch https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz \
                   f5355c79190951eed23c5432a3b920e071f4c00a64f75e077de0dd4cb7b294ea h.tgz
                 tar -xzf "$W/h.tgz" -C "$W" linux-amd64/helm && mv "$W/linux-amd64/helm" "$DIR/" ;;
    kubeconform) fetch https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-linux-amd64.tar.gz \
                   9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883 kc.tgz
                 tar -xzf "$W/kc.tgz" -C "$DIR" kubeconform ;;
    kube-linter) fetch https://github.com/stackrox/kube-linter/releases/download/v0.8.3/kube-linter-linux.tar.gz \
                   1a6d8419b11971372971fdbc22682b684ebfb7cf1c39591662d1b6ca736c41df kl.tgz
                 tar -xzf "$W/kl.tgz" -C "$DIR" kube-linter ;;
    helm-docs)   fetch https://github.com/norwoodj/helm-docs/releases/download/v1.14.2/helm-docs_1.14.2_Linux_x86_64.tar.gz \
                   a8cf72ada34fad93285ba2a452b38bdc5bd52cc9a571236244ec31022928d6cc hd.tgz
                 tar -xzf "$W/hd.tgz" -C "$DIR" helm-docs ;;
    shellcheck)  fetch https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz \
                   8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 sc.txz
                 tar -xJf "$W/sc.txz" -C "$W" && mv "$W/shellcheck-v0.11.0/shellcheck" "$DIR/" ;;
    actionlint)  fetch https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz \
                   8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 al.tgz
                 tar -xzf "$W/al.tgz" -C "$DIR" actionlint ;;
    kind)        fetch https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64 \
                   aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d kind
                 install -m 0755 "$W/kind" "$DIR/kind" ;;
    docker)      command -v docker >/dev/null && continue
                 fetch https://download.docker.com/linux/static/stable/x86_64/docker-28.5.2.tgz \
                   ea90cfd12e1eeb12aa1c971741adb8bd4ed88e2a574eaac13f5029a1dbc6300d d.tgz
                 tar -xzf "$W/d.tgz" -C "$W" docker/docker && mv "$W/docker/docker" "$DIR/" ;;
    *) echo "unknown tool $t" >&2; exit 1 ;;
  esac
  echo "installed $t"
done
