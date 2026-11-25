#!/bin/sh
# Marks a project version inactive when no SbomReport has its image and tag and its last BOM upload is older than STALE_DAYS.
# Retention (config-configmap.yaml, maintenance/projects.retention.*) deletes inactive projects later; sbom-hook activates one again on its next upload.
# The project name (namespace/repository) is derived exactly as in sbom-hook/redpanda-connect.yaml.
set -eu
DT_URL=${DT_URL:?}
STALE_DAYS=${STALE_DAYS:-2}
MIN_LIVE=${MIN_LIVE:-20} # a short list means the cluster read failed: retire nothing
cd /work

# columns: NAMESPACE NAME REPOSITORY TAG ...; project name namespace/repository and version tag (without a repo: prefix), as in sbom-hook
kubectl get sbomreports -A --no-headers | awk '{t = $4; sub(/^.*:/, "", t); print $1 "/" $3 "\t" t}' | sort -u > live.txt
live=$(wc -l < live.txt)
[ "$live" -ge "$MIN_LIVE" ] || { echo "only $live image tags in the SbomReports (minimum $MIN_LIVE): not retiring anything" >&2; exit 1; }
echo "$live image tags have a report"

[ -n "${DT_API_KEY:-}" ] || { echo "no API key yet: config-cronjob.yaml creates the Secret dependency-track-retire-api-key within the hour" >&2; exit 1; }
api() { curl -sS -H "X-Api-Key: $DT_API_KEY" "$@"; }

: > projects.jsonl
page=1
while :; do
  code=$(api -o page.json -w '%{http_code}' "$DT_URL/api/v1/project?excludeInactive=true&pageSize=100&pageNumber=$page") || code=000
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
  | select((.name + "\t" + .version) as $k | $l | any(. == $k) | not)
  | select(.lastBomImport < $cutoff)
  | [.uuid, .name, .version] | @tsv' projects.jsonl > stale.tsv
echo "$(wc -l < stale.tsv) project versions without a report and not updated for $STALE_DAYS days"

failed=0
while IFS="$(printf '\t')" read -r uuid name version; do
  code=$(api -o /dev/null -w '%{http_code}' -X PATCH "$DT_URL/api/v1/project/$uuid" -H 'Content-Type: application/json' -d '{"active":false}') || code=000
  if [ "$code" = 200 ]; then echo "inactive: $name $version"; else echo "failed ($code): $name $version" >&2; failed=$((failed + 1)); fi
done < stale.tsv
[ "$failed" -eq 0 ]
