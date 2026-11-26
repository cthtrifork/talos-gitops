#!/usr/bin/env bash
# Regenerates vex/pkg/oci from the decisions made in Dependency-Track and opens a pull request.
# Everything under vex/pkg/oci is owned by this script: it is rebuilt from scratch on every run.
# Env: DT_URL, API_KEY, REPO, GIT_URL, GITHUB_API, BRANCH. Optional file: /github/token.
set -euo pipefail

FINDINGS=/work/findings   # <image>/<project uuid>.json: the statements of one project (image tag)
PREVIOUS=/work/previous   # vex/pkg/oci as it was on main
DOCS=vex/pkg/oci          # <image>/oci.openvex.json: one OpenVEX document per image, <image>/oci.images.json: its digests
GITHUB_TOKEN=$(cat /github/token 2>/dev/null || true)

# zot sync destinations (k8s/infra/registry-system/zot/zot.json) -> the registry named in the pod spec
UPSTREAM='{"docker-hub-cache":"mirror.gcr.io","ghcr-cache":"ghcr.io","ghcr-private":"ghcr.io","gcr-cache":"gcr.io","quay-cache":"quay.io","k8s-cache":"registry.k8s.io","google-ar-cache":"us-docker.pkg.dev"}'

dt_get() { local path=$1; shift; curl -fsS "$@" -H "X-Api-Key: $API_KEY" "$DT_URL/$path"; }
github() { curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

prepare_repo() {
  cd /work
  if [ -n "$GITHUB_TOKEN" ]; then
    echo "==> Cloning main"
    # the token goes to git through the environment, not the command line
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
    export GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
    git clone -q --depth 1 --branch main --sparse "$GIT_URL" repo
    cd repo
    git sparse-checkout set vex scripts
    git config user.name "dependency-track-vex-export"
    git config user.email "noreply@users.noreply.github.com"
  else
    echo "==> No GitHub token, dry run without a clone"
    mkdir repo
    cd repo
  fi
  mkdir -p "$DOCS" "$FINDINGS"
}

# Every project, 100 per page (DT caps pageSize at 100; X-Total-Count has the total)
all_projects() {
  local page=1 total=0 seen=0 body
  while :; do
    body=$(dt_get "api/v1/project?pageSize=100&pageNumber=$page" -D /work/headers) || return 1
    printf '%s\n' "$body"
    total=$(awk 'tolower($1)=="x-total-count:"{print $2+0}' /work/headers)
    seen=$((seen + $(printf '%s' "$body" | jq length)))
    [ "$seen" -lt "$total" ] && [ "$(printf '%s' "$body" | jq length)" -gt 0 ] || break
    page=$((page + 1))
  done | jq -s 'add // []'
}

export_findings() {
  echo "==> Exporting decisions from Dependency-Track"
  # Only the latest deployed version of each project (namespace/repository): the one marked latest, else the newest upload.
  # Older tags are not exported, so their digests are not scanned and their decisions do not linger.
  all_projects |
    jq -r '[.[] | select(.active != false and (.purl // "") != "")]
      | group_by(.name) | map(sort_by([(.isLatest // false), (.lastBomImport // 0)]) | last) | .[]
      | [.uuid, .name, (.version // "-"), .purl] | @tsv' |
    while IFS=$'\t' read -r uuid name version purl; do
      # The product is the image repository, not a digest: the project PURL without version and arch
      product=$(jq -rn --arg p "$purl" '$p | sub("@sha256(%3A|:)[0-9a-f]+"; "") | sub("arch=[^&]*&?"; "") | sub("[?&]$"; "") | gsub("%3A"; ":")')
      image=$(jq -rn --arg p "$product" '$p | capture("repository_url=(?<u>[^&]*)").u | gsub("%2F"; "/")') || continue
      [ -n "$image" ] || continue
      # Trivy scans through the zot mirror (its PURLs name zot), the pod and CI use the upstream registry: both products
      upstream=$(jq -rn --argjson m "$UPSTREAM" --arg i "$image" '$i | capture("^zot\\.registry-system\\.svc\\.cluster\\.local:5000/(?<c>[^/]+)/(?<r>.+)$") | if $m[.c] then "\($m[.c])/\(.r)" else $i end' || echo "$image")
      alias=$(jq -rn --arg u "$upstream" '"pkg:oci/\($u | split("/") | last)?repository_url=\($u | gsub("/"; "%2F"))"')

      statements=$(dt_get "api/v1/vex/cyclonedx/project/$uuid" | jq -c -f /scripts/vex-export.jq --arg product "$product" --arg alias "$alias")
      count=$(printf '%s' "$statements" | jq length)
      [ "$count" -gt 0 ] || continue

      echo "$name:$version -> $upstream: $count statements"
      mkdir -p "$FINDINGS/$upstream"
      printf '%s\n' "$statements" > "$FINDINGS/$upstream/$uuid.json"
      # the scanned digest lets CI pull the image the decisions were made on
      jq -rn --arg p "$purl" --arg u "$upstream" '$p | capture("@(?<d>sha256(%3A|:)[0-9a-f]+)") | "\($u)@\(.d | gsub("%3A"; ":"))"' > "$FINDINGS/$upstream/$uuid.ref" || true
    done
}

write_documents() {
  echo "==> Writing $DOCS"
  mv "$DOCS" "$PREVIOUS"
  mkdir -p "$DOCS"
  for dir in $(find "$FINDINGS" -name '*.json' -exec dirname {} \; | sort -u); do
    image=${dir#"$FINDINGS"/}
    mkdir -p "$DOCS/$image"

    # keep timestamp and version of the existing document, bump_changed_documents updates them
    old=$(cat "$PREVIOUS/$image/oci.openvex.json" 2>/dev/null || echo '{}')

    jq -s --arg image "$image" --arg now "$(date -u +%FT%TZ)" --argjson old "$old" '{
      "@context": "https://openvex.dev/ns/v0.2.0",
      "@id": "https://github.com/cthtrifork/talos-gitops/vex/pkg/oci/\($image)",
      author: "Dependency-Track",
      role: "Automated export from Dependency-Track",
      timestamp: ($old.timestamp // $now),
      version: ($old.version // 1),
      statements: (map(.[]) | unique | sort_by(.vulnerability.name, .products[0]."@id"))
    }' "$dir"/*.json > "$DOCS/$image/oci.openvex.json"
    cat "$dir"/*.ref 2>/dev/null | sort -u | jq -R . | jq -s . > "$DOCS/$image/oci.images.json"
  done
}

bump_changed_documents() {
  echo "==> Bumping the version of changed documents"
  for doc in $(git diff --name-only --diff-filter=M -- "$DOCS" | grep '\.openvex\.json$' || true); do
    jq --arg now "$(date -u +%FT%TZ)" '.version += 1 | .timestamp = $now' "$doc" > /work/bumped.json
    mv /work/bumped.json "$doc"
  done
}

push_branch() {
  echo "==> Pushing $BRANCH"
  git checkout -q -b "$BRANCH"
  git add vex
  git commit -q -m "feat(vex): export Dependency-Track analysis decisions"
  git push -q --force origin "$BRANCH"
}

open_pull_request() {
  echo "==> Opening a pull request if none is open"
  open=$(github "$GITHUB_API/repos/$REPO/pulls?head=$(dirname "$REPO"):$BRANCH&state=open" | jq length)
  [ "$open" -eq 0 ] || return 0

  jq -n --arg branch "$BRANCH" '{
    title: "feat(vex): export Dependency-Track analysis decisions",
    head: $branch,
    base: "main",
    body: "OpenVEX documents generated from the analysis decisions (not affected, false positive, resolved) in Dependency-Track by the CronJob `dependency-track-vex-export`. Only files under `vex/` change. Merge to let Trivy hide these findings (the vex-cache image is rebuilt from vex/); close to discard until the next run."
  }' | github -X POST -d @- "$GITHUB_API/repos/$REPO/pulls" | jq -r .html_url
}

if [ -z "${API_KEY:-}" ]; then
  echo "DRY RUN: Secret dependency-track-vex-api-key is missing (config-job creates it), nothing to export"
  exit 0
fi

prepare_repo
export_findings
write_documents

if [ -z "$GITHUB_TOKEN" ]; then
  echo "DRY RUN: Secret dependency-track-vex-github is not synced (see k8s/infra/dependency-track-system/README.md). Would write:"
  find "$DOCS" -name oci.openvex.json | sort
  exit 0
fi

if [ -z "$(git status --porcelain vex)" ]; then
  echo "VEX documents are up to date"
  exit 0
fi

bump_changed_documents
./scripts/vex-index.sh
push_branch
open_pull_request
