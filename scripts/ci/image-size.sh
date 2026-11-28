#!/usr/bin/env bash
# Prints the compressed linux/amd64 size of an image in bytes; nothing if it cannot be read.
set -uo pipefail
ref=$1
m=$(crane manifest "${ref}" 2>/dev/null) || exit 0
if jq -e '.manifests' <<<"${m}" > /dev/null 2>&1; then
  d=$(jq -r '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest // empty' <<<"${m}")
  [ -n "${d}" ] || exit 0
  m=$(crane manifest "${ref%%@*}@${d}" 2>/dev/null) || exit 0
fi
jq -r '[.layers[].size] | add // empty' <<<"${m}"
