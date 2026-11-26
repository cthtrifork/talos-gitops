#!/usr/bin/env bash
# Regenerates vex/pkg/oci from the decisions made in Dependency-Track and opens a pull request.
# Everything under vex/pkg/oci is owned by this script: it is rebuilt from scratch on every run.
# Env: DT_URL, API_KEY, REPO, GIT_URL, GITHUB_API, BRANCH. Optional file: /github/token.
set -euo pipefail

FINDINGS=/work/findings   # <image>/<project uuid>.json: the statements of one project (image tag)
PREVIOUS=/work/previous   # vex/pkg/oci as it was on main
DOCS=vex/pkg/oci          # <image>/oci.openvex.json: one OpenVEX document per image
GITHUB_TOKEN=$(cat /github/token 2>/dev/null || true)

dt_get() { curl -fsS -H "X-Api-Key: $API_KEY" "$DT_URL/$1"; }
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

export_findings() {
  echo "==> Exporting decisions from Dependency-Track"
  dt_get "api/v1/project?pageSize=1000" |
    jq -r '.[] | select(.active != false and (.purl // "") != "") | [.uuid, .name, (.version // "-"), .purl] | @tsv' |
    while IFS=$'\t' read -r uuid name version purl; do
      # The product is the image repository, not a digest: the project PURL without version and arch
      product=$(jq -rn --arg p "$purl" '$p | sub("@sha256(%3A|:)[0-9a-f]+"; "") | sub("arch=[^&]*&?"; "") | sub("[?&]$"; "") | gsub("%3A"; ":")')
      image=$(jq -rn --arg p "$product" '$p | capture("repository_url=(?<u>[^&]*)").u | gsub("%2F"; "/")') || continue
      [ -n "$image" ] || continue

      statements=$(dt_get "api/v1/vex/cyclonedx/project/$uuid" | jq -c -f /scripts/vex-export.jq --arg product "$product")
      count=$(printf '%s' "$statements" | jq length)
      [ "$count" -gt 0 ] || continue

      echo "$name:$version -> $product: $count statements"
      mkdir -p "$FINDINGS/$image"
      printf '%s\n' "$statements" > "$FINDINGS/$image/$uuid.json"
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
  done
}

bump_changed_documents() {
  echo "==> Bumping the version of changed documents"
  for doc in $(git diff --name-only --diff-filter=M -- "$DOCS"); do
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
