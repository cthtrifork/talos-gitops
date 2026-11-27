#!/usr/bin/env bash
# Print the image reference to pull: through the zot pull-through cache when REGISTRY_MIRROR (host:port) is set, else unchanged.
set -euo pipefail

ref="${1:?usage: mirror-ref.sh <image-ref>}"
mirror="${REGISTRY_MIRROR:-}"

[[ -n "${mirror}" ]] || { printf '%s\n' "${ref}"; exit 0; }

# same mapping as the trivy.registry.mirror values of trivy-operator
case "${ref}" in
  ghcr.io/cthtrifork/*) printf '%s\n' "${ref}" ;; # private, not cached
  mirror.gcr.io/*) printf '%s/docker-hub-cache/%s\n' "${mirror}" "${ref#mirror.gcr.io/}" ;;
  registry-1.docker.io/*) printf '%s/docker-hub-cache/%s\n' "${mirror}" "${ref#registry-1.docker.io/}" ;;
  docker.io/*) printf '%s/docker-hub-cache/%s\n' "${mirror}" "${ref#docker.io/}" ;;
  ghcr.io/*) printf '%s/ghcr-cache/%s\n' "${mirror}" "${ref#ghcr.io/}" ;;
  quay.io/*) printf '%s/quay-cache/%s\n' "${mirror}" "${ref#quay.io/}" ;;
  gcr.io/*) printf '%s/gcr-cache/%s\n' "${mirror}" "${ref#gcr.io/}" ;;
  registry.k8s.io/*) printf '%s/k8s-cache/%s\n' "${mirror}" "${ref#registry.k8s.io/}" ;;
  *) printf '%s\n' "${ref}" ;;
esac
