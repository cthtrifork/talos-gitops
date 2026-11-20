#!/usr/bin/env bash
# Runs the ImageValidatingPolicy through the Kyverno CLI (the version the cluster runs): the CEL must compile and a pod with a
# signed image of this repo must pass. Needs the internet (ghcr.io, Rekor, the Sigstore TUF root).
# Usage: scripts/ci/test-image-policy.sh [policy file]
set -euo pipefail

policy="${1:-k8s/infra/image-policies/imagevalidatingpolicy-cthtrifork-images.yaml}"
dir="$(dirname "${BASH_SOURCE[0]}")/kyverno"

# the namespaceSelector needs the namespace labels, which the CLI does not have: check the policy for any namespace
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
yq e 'del(.spec.matchConstraints.namespaceSelector)' "${policy}" > "${tmp}"

out="$(kyverno apply "${tmp}" --resource "${dir}/pod-signed.yaml" --detailed-results 2>&1)" || { echo "${out}"; exit 1; }
echo "${out}"
grep -Eq 'pass: [1-9]' <<<"${out}" || { echo "signed image did not pass" >&2; exit 1; }
grep -Eq '(fail|error): [1-9]' <<<"${out}" && { echo "signed image failed the policy" >&2; exit 1; }
exit 0
