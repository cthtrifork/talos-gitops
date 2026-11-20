#!/usr/bin/env bash
# Regenerate the vendored KubeVirt and CDI operator manifests (k8s/infra/kubevirt/) at the versions pinned in
# k8s/infra/kubevirt/versions.env, which Renovate bumps. Renovate cannot edit the manifests itself: bumping only
# the image line leaves the CRDs, RBAC and versions of the release behind.
# Also regenerates image-pins.yaml (digests of the images the operators start). Needs yq (mikefarah) and docker buildx. Prints one line per updated file; changes nothing if already current.
set -euo pipefail

cd "$(dirname "$0")/../.."

# shellcheck source=/dev/null
source k8s/infra/kubevirt/versions.env

# repository | release asset | file | operator image | pinned version
TARGETS=(
  "kubevirt/kubevirt|kubevirt-operator.yaml|k8s/infra/kubevirt/kubevirt-operator.yaml|quay.io/kubevirt/virt-operator|${KUBEVIRT_VERSION}"
  "kubevirt/containerized-data-importer|cdi-operator.yaml|k8s/infra/kubevirt/cdi-operator.yaml|quay.io/kubevirt/cdi-operator|${CDI_VERSION}"
)

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for target in "${TARGETS[@]}"; do
  IFS='|' read -r repo asset file image version <<<"$target"

  current=$(sed -nE "s|^ +image: ${image}:([^@ ]+).*|\1|p" "$file" | head -n 1)
  if [[ -z "$current" || -z "$version" ]]; then
    echo "cannot determine versions for ${file} (current='${current}', version='${version}')" >&2
    exit 1
  fi
  [[ "$current" == "$version" ]] && continue

  digest=$(docker buildx imagetools inspect "${image}:${version}" --format '{{.Manifest.Digest}}')
  [[ "$digest" == sha256:* ]] || { echo "no digest for ${image}:${version}" >&2; exit 1; }

  curl -fsSL -o "$tmp" "https://github.com/${repo}/releases/download/${version}/${asset}"
  # Same formatting as the files in the repo (indented sequences, document start), pinned by digest like Renovate does
  {
    echo '---'
    yq e '.' "$tmp" | sed -E "s|^( +image: )${image}:.*|\1${image}:${version}@${digest}|"
  } >"$file"

  echo "${image##*/} ${current} -> ${version}"
done

# The operators start their own pods from the image references in env vars; the upstream manifests use tags, which the
# require-image-digest policy denies. Regenerate the pin patch (image-pins.yaml) from the pinned versions every run.
digest_of() {
  local ref=$1 digest
  digest=$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}')
  [[ "$digest" == sha256:* ]] || { echo "no digest for ${ref}" >&2; exit 1; }
  echo "$digest"
}

env_pin() { # <env name> <image name> <version>
  echo "            - name: $1"
  echo "              value: quay.io/kubevirt/$2:$3@$(digest_of "quay.io/kubevirt/$2:$3")"
}

pins=k8s/infra/kubevirt/image-pins.yaml
{
  sed -n '1,/^---$/p' "$pins" | sed '$d'
  echo '---'
  cat <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: virt-operator
  namespace: kubevirt
spec:
  template:
    spec:
      containers:
        - name: virt-operator
          env:
YAML
  env_pin VIRT_OPERATOR_IMAGE virt-operator "$KUBEVIRT_VERSION"
  env_pin VIRT_API_IMAGE virt-api "$KUBEVIRT_VERSION"
  env_pin VIRT_CONTROLLER_IMAGE virt-controller "$KUBEVIRT_VERSION"
  env_pin VIRT_HANDLER_IMAGE virt-handler "$KUBEVIRT_VERSION"
  env_pin VIRT_LAUNCHER_IMAGE virt-launcher "$KUBEVIRT_VERSION"
  env_pin VIRT_EXPORTPROXY_IMAGE virt-exportproxy "$KUBEVIRT_VERSION"
  env_pin VIRT_EXPORTSERVER_IMAGE virt-exportserver "$KUBEVIRT_VERSION"
  env_pin VIRT_SYNCHRONIZATIONCONTROLLER_IMAGE virt-synchronization-controller "$KUBEVIRT_VERSION"
  cat <<'YAML'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cdi-operator
  namespace: cdi
spec:
  template:
    spec:
      containers:
        - name: cdi-operator
          env:
YAML
  env_pin CONTROLLER_IMAGE cdi-controller "$CDI_VERSION"
  env_pin IMPORTER_IMAGE cdi-importer "$CDI_VERSION"
  env_pin CLONER_IMAGE cdi-cloner "$CDI_VERSION"
  env_pin OVIRT_POPULATOR_IMAGE cdi-importer "$CDI_VERSION"
  env_pin APISERVER_IMAGE cdi-apiserver "$CDI_VERSION"
  env_pin UPLOAD_SERVER_IMAGE cdi-uploadserver "$CDI_VERSION"
  env_pin UPLOAD_PROXY_IMAGE cdi-uploadproxy "$CDI_VERSION"
} >"${pins}.new"
mv "${pins}.new" "$pins"
