#!/usr/bin/env bash
# Admission test of the image policy (k8s/infra/image-policies) against a cluster that runs it: every digest-pinned image of
# ours in k8s/ must be admitted, an unsigned one denied, and pods without our images unaffected.
set -euo pipefail

ns=verify-images
kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -

pod() {
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: verify\n  namespace: %s\nspec:\n  containers:\n    - name: c\n      image: %s\n' "$1" "$2"
}

fail=0
expect() { # <admit|deny> <namespace> <image>
  local out rc=0
  out=$(pod "$2" "$3" | kubectl create --dry-run=server -f - 2>&1) || rc=$?
  if { [ "$1" = admit ] && [ "${rc}" -eq 0 ]; } || { [ "$1" = deny ] && [ "${rc}" -ne 0 ] && grep -q "cthtrifork-images" <<<"${out}"; }; then
    echo "ok   ${1} ${3}"
  else
    echo "FAIL ${1} ${3}: ${out}"
    fail=1
  fi
}

mapfile -t images < <(grep -rhoE 'ghcr\.io/cthtrifork/(talos-gitops/|harper-pad-)[A-Za-z0-9_./-]+(:[A-Za-z0-9_.-]+)?@sha256:[a-f0-9]{64}' k8s | sort -u)
[ "${#images[@]}" -gt 0 ] || { echo "no images of ours found in k8s/"; exit 1; }

for image in "${images[@]}"; do expect admit "${ns}" "${image}"; done
expect deny "${ns}" ghcr.io/cthtrifork/talos-gitops/unsigned:test
expect deny "${ns}" ghcr.io/cthtrifork/harper-pad-unsigned:test
# no namespace is exempt, and other images never reach the webhook
expect deny kube-system ghcr.io/cthtrifork/talos-gitops/unsigned:test
expect admit "${ns}" mirror.gcr.io/library/busybox:latest
exit "${fail}"
