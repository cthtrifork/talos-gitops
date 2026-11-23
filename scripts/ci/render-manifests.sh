#!/usr/bin/env bash
# Render the chart of the HelmRelease (helm-release.yaml) and its OCIRepository (helm-repository.yaml) into ./rendered.
# Run in the directory holding both files. ZOT_MIRROR_* in the environment pull the chart through zot (docs/registry-mirrors.md).
set -euo pipefail

echo "Rendering manifests for directory: $(pwd)"

HELM_REPOSITORY_FILE="./helm-repository.yaml"
HELM_RELEASE_FILE="./helm-release.yaml"

extract_and_validate() {
  local field="$1"
  local file="$2"
  local value
  value=$(yq eval "$field" "$file" | head -n 1)
  if [[ "$value" == "null" || -z "$value" ]]; then
    echo "Error: Missing or invalid value for $field in '$file'." >&2
    exit 1
  fi
  echo "$value"
}

# The OCIRepository url holds Flux variables, e.g. oci://${ZOT_MIRROR_GHCR:=ghcr.io}/org/charts/app: unset they render from the
# upstream registry, set (a runner in the cluster, scripts/zot/compose.yaml) through zot.
REPOSITORY_RESOLVED=$(mktemp)
VALUES_FILE=$(mktemp)
trap 'rm -f "$REPOSITORY_RESOLVED" "$VALUES_FILE"' EXIT
flux envsubst <"$HELM_REPOSITORY_FILE" >"$REPOSITORY_RESOLVED"

if [[ "$(yq eval '.kind' "$REPOSITORY_RESOLVED" | head -n 1)" != "OCIRepository" ]]; then
  echo "Error: '$HELM_REPOSITORY_FILE' is not an OCIRepository; HelmRepository sources are not supported." >&2
  exit 1
fi

HELM_REPOSITORY_URL=$(extract_and_validate '.spec.url' "$REPOSITORY_RESOLVED")
HELM_RELEASE_CHART_VERSION=$(extract_and_validate '.spec.ref.tag' "$REPOSITORY_RESOLVED")

# a local zot (scripts/zot/compose.yaml) speaks plain HTTP
HELM_OCI_ARGS=()
if [[ "$HELM_REPOSITORY_URL" =~ ^oci://(localhost|127\.0\.0\.1)(:|/) ]]; then
  HELM_OCI_ARGS+=(--plain-http)
fi

HELM_RELEASE_NAME=$(extract_and_validate '.metadata.name' "$HELM_RELEASE_FILE")
HELM_RELEASE_NAMESPACE=$(extract_and_validate '.spec.targetNamespace // .metadata.namespace' "$HELM_RELEASE_FILE")
extract_and_validate '.spec.chartRef.name' "$HELM_RELEASE_FILE" >/dev/null # the release must take its chart from the OCIRepository
export HELM_RELEASE_NAMESPACE

echo "Rendering ${HELM_RELEASE_NAME} (namespace ${HELM_RELEASE_NAMESPACE}) from ${HELM_REPOSITORY_URL}:${HELM_RELEASE_CHART_VERSION}"

# the Makefile tracks changes with .dummy
rm -rf ./rendered
mkdir ./rendered
touch ./rendered/.dummy

yq eval '.spec.values' "$HELM_RELEASE_FILE" | flux envsubst >"$VALUES_FILE"

helm template "$HELM_RELEASE_NAME" "$HELM_REPOSITORY_URL" \
  --version "$HELM_RELEASE_CHART_VERSION" \
  --namespace "$HELM_RELEASE_NAMESPACE" \
  --values "$VALUES_FILE" \
  --output-dir "./rendered" \
  --skip-tests \
  ${HELM_OCI_ARGS[@]+"${HELM_OCI_ARGS[@]}"}

# Ensure the namespace is set in all rendered manifests
find ./rendered -type f -name "*.yaml" | while read -r file; do
  yq '. |= (
      with(select(.metadata != null and .metadata.namespace == null);
        .metadata.namespace = env(HELM_RELEASE_NAMESPACE)
      )
    )' -i "$file"
done

helm show values "$HELM_REPOSITORY_URL" --version "$HELM_RELEASE_CHART_VERSION" \
  ${HELM_OCI_ARGS[@]+"${HELM_OCI_ARGS[@]}"} >>./rendered/helm-default-values.yaml

TEMPLATES_DIR="./rendered/$HELM_RELEASE_NAME/templates"
if ! [[ -d "$TEMPLATES_DIR" ]]; then
  echo "Templates directory $TEMPLATES_DIR not found / generated. Source dir: $(pwd)"
elif [[ $(find "./rendered/$HELM_RELEASE_NAME" -mindepth 1 -maxdepth 1 -type d | wc -l) -gt 1 ]]; then
  # subcharts: keep one directory per chart
  mv "$TEMPLATES_DIR"/* "./rendered/$HELM_RELEASE_NAME"
  rm -r "$TEMPLATES_DIR"
else
  mv "$TEMPLATES_DIR"/* ./rendered
  rm -r "./rendered/$HELM_RELEASE_NAME"
fi

# Ensure proper formatting
yq -i "./rendered/helm-default-values.yaml"

# Apply the post-render patches of the Helm release, if any
if [[ "$(yq eval '.spec.postRenderers' "$HELM_RELEASE_FILE")" != "null" ]]; then
  echo "Applying post-render patches from Helm release."
  PATCHES=$(yq '.spec.postRenderers[].kustomize' "$HELM_RELEASE_FILE")

  find rendered/ ! -name 'helm-default-values.yaml' -name '*.yaml' | sed 's|^rendered/||' | while IFS= read -r file; do
    # Build kustomization overlay from the extracted patch
    cat >"rendered/kustomization.yaml" <<EOF
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization
  sortOptions:
    order: fifo
  resources:
  - $file
  $PATCHES
EOF
    # Apply the kustomize overlay to the rendered manifests
    kustomize build "./rendered" -o "rendered/$file"

    rm rendered/kustomization.yaml
  done
fi

echo "Manifests rendered successfully in: ./rendered"
