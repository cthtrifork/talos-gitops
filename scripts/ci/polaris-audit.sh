#!/usr/bin/env bash
# Audit the manifests that Flux Kustomizations build with Polaris, using the same checks and exemptions as the in-cluster
# dashboard (spec.values.config of k8s/infra/policy-system/polaris/helm-release.yaml, merged with Polaris' defaults).
# Covers workloads written in this repository; pods that operators or Helm charts create at run time are only seen by the
# dashboard. Usage: scripts/ci/polaris-audit.sh [cluster-dir] [minimum-score]
# Needs polaris, kustomize and yq on the PATH. Fails on any danger finding or a score below the minimum.
set -euo pipefail

cluster_dir="${1:-k8s/clusters/homelab}"
min_score="${2:-95}"
release=k8s/infra/policy-system/polaris/helm-release.yaml

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/manifests"

yq e '.spec.values.config' "$release" >"$work/polaris.yaml"

# same paths as build-flux-paths.sh: Flux generates a kustomization.yaml when there is none, so those are skipped
n=0
while IFS= read -r path; do
    path="$(echo "$path" | sed -E 's#^(\.\./)+##')"
    [[ -f "$path/kustomization.yaml" ]] || continue
    n=$((n + 1))
    kustomize build "$path" --load-restrictor=LoadRestrictionsNone >"$work/manifests/$n.yaml"
done < <(yq e '.spec.path | select(. != null)' "$cluster_dir"/*.yaml | grep -v '^---' | sort -u)

polaris audit --config "$work/polaris.yaml" --merge-config --audit-path "$work/manifests" \
    --format json --output-file "$work/report.json"

python3 - "$work/report.json" <<'PY'
import collections
import json
import sys

report = json.load(open(sys.argv[1]))
findings = collections.defaultdict(list)


def collect(controller, results):
    for check, result in (results or {}).items():
        if not result.get("Success"):
            findings[(result.get("Severity"), check)].append(controller)


for r in report.get("Results", []):
    name = f'{r.get("Kind")}/{r.get("Namespace")}/{r.get("Name")}'
    collect(name, r.get("Results"))
    pod = r.get("PodResult") or {}
    collect(name, pod.get("Results"))
    for c in pod.get("ContainerResults") or []:
        collect(name, c.get("Results"))

for (severity, check), controllers in sorted(findings.items()):
    print(f"{severity}: {check} ({len(controllers)}): {', '.join(sorted(set(controllers))[:5])}")
PY

score="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Score"])' "$work/report.json")"
echo "Polaris score: $score (minimum $min_score)"
danger="$(python3 -c '
import json,sys
r = json.load(open(sys.argv[1]))
def n(rs): return sum(1 for v in (rs or {}).values() if not v.get("Success") and v.get("Severity") == "danger")
t = 0
for x in r.get("Results", []):
    p = x.get("PodResult") or {}
    t += n(x.get("Results")) + n(p.get("Results")) + sum(n(c.get("Results")) for c in p.get("ContainerResults") or [])
print(t)' "$work/report.json")"
if [[ "$danger" != 0 || "$score" -lt "$min_score" ]]; then
    echo "ERROR - Polaris: $danger danger finding(s), score $score" >&2
    exit 1
fi
