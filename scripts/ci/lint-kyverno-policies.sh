#!/usr/bin/env bash
# Lints the Kyverno policies with the Kyverno CLI (the version the cluster runs): each policy must load and its CEL must compile.
# The resource matches no policy, so nothing is evaluated and no network is needed.
# Usage: scripts/ci/lint-kyverno-policies.sh [directory, default k8s/infra/image-policies]
set -euo pipefail

dir="${1:-k8s/infra/image-policies}"
resource="$(mktemp)"
trap 'rm -f "${resource}"' EXIT
cat > "${resource}" <<'YAML'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: lint
  namespace: default
YAML

status=0
for policy in "${dir}"/*.yaml; do
  [[ "$(basename "${policy}")" == kustomization.yaml ]] && continue
  echo "== ${policy}"
  if out="$(kyverno apply "${policy}" --resource "${resource}" 2>&1)"; then
    echo "${out}"
    grep -Eq 'error: [1-9]' <<<"${out}" && status=1
  else
    echo "${out}"
    status=1
  fi
done
exit "${status}"
