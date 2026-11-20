#!/usr/bin/env bash
# Runs the ImageValidatingPolicy through the Kyverno CLI (the version the cluster runs): the CEL must compile and a pod with a
# signed image of this repo must pass, and fail against another workflow identity. Needs the internet (ghcr.io, Rekor, the Sigstore TUF root).
# Usage: scripts/ci/test-image-policy.sh [policy file]
set -euo pipefail

policy="${1:-k8s/infra/image-policies/imagevalidatingpolicy-cthtrifork-images.yaml}"
dir="$(dirname "${BASH_SOURCE[0]}")/kyverno"

run() {
  kyverno apply "$1" --resource "${dir}/pod-signed.yaml" --values-file "${dir}/values.yaml" 2>&1
}

out="$(run "${policy}")" || { echo "${out}"; exit 1; }
echo "${out}"
grep -Eq 'pass: 1, fail: 0, warn: 0, error: 0' <<<"${out}" || { echo "signed image did not pass" >&2; exit 1; }

# the same image must fail when the policy trusts another workflow: the check really compares the certificate subject
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
yq e '.spec.attestors[0].cosign.keyless.identities[0].subjectRegExp = "^https://github.com/example/other/.github/workflows/x.yaml@refs/heads/main$"' "${policy}" > "${tmp}"
out="$(run "${tmp}")" || true
echo "${out}"
grep -Eq 'fail: 1' <<<"${out}" || { echo "image from another workflow was not refused" >&2; exit 1; }
