#!/usr/bin/env bash
# Deletes all VulnerabilityReports (the operator rescans) when the vex-cache artifact is newer than the last one handled.
set -euo pipefail
art=/vex-cache
ns=trivy-system

built=$(cat "${art}/homelab-built-at")
[[ "${built}" =~ ^[0-9]+$ ]] || { echo "bad timestamp in the artifact: ${built}"; exit 1; }
last=$(kubectl -n "${ns}" get configmap vex-cache-state -o jsonpath='{.data.built-at}')

record() { kubectl -n "${ns}" patch configmap vex-cache-state --type merge -p "{\"data\":{\"built-at\":\"${built}\"}}"; }

if [[ -z "${last}" ]]; then echo "first run, recording ${built}"; record; exit 0; fi
if (( built <= last )); then echo "artifact ${built} is not newer than ${last}"; exit 0; fi

# Flux may not have applied the ignore files of this build yet: wait for the next run
live_ignore=$(kubectl -n "${ns}" get configmap trivy-ignorefile -o jsonpath='{.data.\.trivyignore\.yaml}' | sha256sum | cut -d' ' -f1)
live_policy=$(kubectl -n "${ns}" get configmap trivy-ignorepolicy -o jsonpath='{.data.ignorePolicy}' | sha256sum | cut -d' ' -f1)
if [[ "${live_ignore}" != "$(cat "${art}/trivyignore.sha256")" || "${live_policy}" != "$(cat "${art}/ignore-policy.sha256")" ]]; then
  echo "the live ignore files differ from the artifact, retrying next run"
  exit 0
fi

echo "artifact ${built} is newer than ${last}: deleting all VulnerabilityReports"
kubectl delete vulnerabilityreports.aquasecurity.github.io --all-namespaces --all --wait=false
record
