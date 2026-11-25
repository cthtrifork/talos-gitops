#!/bin/sh
# Marks the project of a workload inactive when no SbomReport names it and its last BOM upload is older than STALE_DAYS.
# Retention (config-configmap.yaml, maintenance/projects.retention.*) deletes inactive projects later; sbom-hook activates one again on its next upload.
# The workload name is derived exactly as in sbom-hook/redpanda-connect.yaml.
set -eu
DT_URL=${DT_URL:?}
STALE_DAYS=${STALE_DAYS:-2}
MIN_LIVE=${MIN_LIVE:-20} # a short list means the cluster read failed: retire nothing
cd /work

kubectl get sbomreports -A --show-labels --no-headers | awk '{print $NF}' | jq -R -r '
  split(",") | map(split("=") | {key: .[0], value: .[1]}) | from_entries
  | .["trivy-operator.resource.kind"] as $k | .["trivy-operator.resource.name"] as $n
  | (if $k == "ReplicaSet" then ($n | sub("-[^-]+$"; "")) elif $k == "Job" then ($n | sub("-[0-9a-f]{8,}$"; "")) else $n end) as $w
  | "\(.["trivy-operator.resource.namespace"])/\($w)/\(.["trivy-operator.container.name"])"' | sort -u > live.txt
live=$(wc -l < live.txt)
[ "$live" -ge "$MIN_LIVE" ] || { echo "only $live workloads in the SbomReports (minimum $MIN_LIVE): not retiring anything" >&2; exit 1; }
echo "$live workloads have a report"

dry=0
if [ -z "${DT_API_KEY:-}" ]; then dry=1; echo "DRY RUN: no API key yet"; DT_API_KEY=none; fi
if [ -n "${DRY_RUN:-}" ]; then dry=1; echo "DRY RUN: DRY_RUN is set"; fi
api() { curl -sS -H "X-Api-Key: $DT_API_KEY" "$@"; }

: > projects.jsonl
page=1
while :; do
  code=$(api -o page.json -w '%{http_code}' "$DT_URL/api/v1/project?excludeInactive=true&pageSize=100&pageNumber=$page") || code=000
  if [ "$dry" = 1 ] && [ "$code" != 200 ]; then echo "DRY RUN: cannot list projects ($code)"; exit 0; fi
  [ "$code" = 200 ] || { echo "listing projects failed ($code)" >&2; exit 1; }
  jq -c '.[] | {uuid, name, version, lastBomImport: (.lastBomImport // 0), tags: [(.tags // [])[].name]}' page.json >> projects.jsonl
  [ "$(jq length page.json)" -eq 100 ] || break
  page=$((page + 1))
done
echo "$(wc -l < projects.jsonl) active projects"

# only projects sbom-hook created (tag kubernetes)
cutoff=$(( ($(date +%s) - STALE_DAYS * 86400) * 1000 ))
jq -r --argjson cutoff "$cutoff" --rawfile live live.txt '
  ($live | split("\n")) as $l
  | select(.tags | index("kubernetes"))
  | select(.name as $n | $l | any(. == $n) | not)
  | select(.lastBomImport < $cutoff)
  | [.uuid, .name, .version] | @tsv' projects.jsonl > stale.tsv
echo "$(wc -l < stale.tsv) projects without a report and not updated for $STALE_DAYS days"

failed=0
while IFS="$(printf '\t')" read -r uuid name version; do
  if [ "$dry" = 1 ]; then echo "DRY RUN: would mark $name $version inactive"; continue; fi
  code=$(api -o /dev/null -w '%{http_code}' -X PATCH "$DT_URL/api/v1/project/$uuid" -H 'Content-Type: application/json' -d '{"active":false}') || code=000
  if [ "$code" = 200 ]; then echo "inactive: $name $version"; else echo "failed ($code): $name $version" >&2; failed=$((failed + 1)); fi
done < stale.tsv
[ "$failed" -eq 0 ]
