#!/usr/bin/env bash
# Point containerd in the kind node at the in-cluster zot pull-through caches, like patches/11-zot-mirrors.yaml does for
# the Talos nodes, with no fallback to the upstream registries: the `server` of every registry is zot itself, so a
# missing cache fails the pull. Usage: zot-mirror.sh <node-container> <ca-file>
set -euo pipefail

node="${1:?node container}"
ca="${2:?CA file}"
zot="zot.registry-system.svc.cluster.local:5000"
dir=/etc/containerd/certs.d # config_path in scripts/kind.yaml

docker cp "${ca}" "${node}:${dir}/zot-ca.crt" 2>/dev/null || { docker exec "${node}" mkdir -p "${dir}"; docker cp "${ca}" "${node}:${dir}/zot-ca.crt"; }

# registry host and zot cache repository, the same mapping as patches/11-zot-mirrors.yaml
while read -r host cache; do
  docker exec -i "${node}" sh -c "mkdir -p ${dir}/${host} && cat > ${dir}/${host}/hosts.toml" <<TOML
server = "https://${zot}"

[host."https://${zot}/v2/${cache}"]
  capabilities = ["pull", "resolve"]
  override_path = true
  ca = "${dir}/zot-ca.crt"
TOML
done <<'MIRRORS'
docker.io docker-hub-cache
mirror.gcr.io docker-hub-cache
ghcr.io ghcr-cache
gcr.io gcr-cache
registry.k8s.io k8s-cache
quay.io quay-cache
us-docker.pkg.dev google-ar-cache
MIRRORS

echo "containerd in ${node} pulls through ${zot} only"
