#!/usr/bin/env bash
# Deletes VulnerabilityReports (the operator rescans) when the vex-cache artifact is newer than the last one handled.
# Only a VEX change deletes just the reports of images with VEX statements; a changed ignore file or policy deletes all.
set -euo pipefail
art=/vex-cache
ns=trivy-system

# a run started by hand (Run jobs page, Job named <cronjob>-manual-<time>) always rescans; the stored timestamp stays as it is
if [[ "${JOB_NAME:-}" == *-manual-* ]]; then
  echo "manual run: deleting all VulnerabilityReports"
  kubectl delete vulnerabilityreports.aquasecurity.github.io --all-namespaces --all --wait=false
  exit 0
fi

built=$(cat "${art}/homelab-built-at")
[[ "${built}" =~ ^[0-9]+$ ]] || { echo "bad timestamp in the artifact: ${built}"; exit 1; }
art_ignore=$(cat "${art}/trivyignore.sha256")
art_policy=$(cat "${art}/ignore-policy.sha256")
state() { kubectl -n "${ns}" get configmap vex-cache-state -o "jsonpath={.data.$1}"; }
last=$(state built-at)

record() {
  kubectl -n "${ns}" patch configmap vex-cache-state --type merge \
    -p "{\"data\":{\"built-at\":\"${built}\",\"ignore-sha256\":\"${art_ignore}\",\"policy-sha256\":\"${art_policy}\"}}"
}

if [[ -z "${last}" ]]; then echo "first run, recording ${built}"; record; exit 0; fi
if (( built <= last )); then echo "artifact ${built} is not newer than ${last}"; exit 0; fi

# Flux may not have applied the ignore files of this build yet: wait for the next run
live_ignore=$(kubectl -n "${ns}" get configmap trivy-ignorefile -o jsonpath='{.data.\.trivyignore\.yaml}' | sha256sum | cut -d' ' -f1)
live_policy=$(kubectl -n "${ns}" get configmap trivy-ignorepolicy -o jsonpath='{.data.ignorePolicy}' | sha256sum | cut -d' ' -f1)
if [[ "${live_ignore}" != "${art_ignore}" || "${live_policy}" != "${art_policy}" ]]; then
  echo "the live ignore files differ from the artifact, retrying next run"
  exit 0
fi

# a missing stored hash (state from before this check) counts as changed
if [[ "$(state ignore-sha256)" != "${art_ignore}" || "$(state policy-sha256)" != "${art_policy}" ]]; then
  echo "artifact ${built} is newer than ${last} and the ignore file or policy changed: deleting all VulnerabilityReports"
  kubectl delete vulnerabilityreports.aquasecurity.github.io --all-namespaces --all --wait=false
  record
  exit 0
fi

# only VEX changed: select the reports whose image (<registry>/<repository>) has a statement in homelab-vexhub
echo "artifact ${built} is newer than ${last}, only VEX changed: deleting the VulnerabilityReports with VEX statements"
kubectl get vulnerabilityreports.aquasecurity.github.io --all-namespaces -o json |
  jq -r --slurpfile idx "${art}/repositories/homelab-vexhub/0.1/index.json" '
    ($idx[0].packages | map(.id | capture("repository_url=(?<r>[^&]*)").r | gsub("%2F"; "/"; "i"))) as $repos
    | .items[]
    | select((.report.registry.server + "/" + .report.artifact.repository) as $img | $repos | index($img) != null)
    | "\(.metadata.namespace) \(.metadata.name)"' |
  while read -r n r; do
    kubectl -n "${n}" delete vulnerabilityreports.aquasecurity.github.io "${r}" --wait=false
  done
record
