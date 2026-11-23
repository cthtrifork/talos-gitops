#!/usr/bin/env bash
# Validate every path the Flux Kustomizations in a cluster directory point at, as Flux builds them.
# Schema locations and skip rules are in .fluxschema.yml.
set -euo pipefail

export FLUX_SCHEMA_CONFIG="${0%/*}/../../.fluxschema.yml"
# paths are written relative to the cluster directory, but Flux resolves them from the repo root
yq -N '.spec.path | select(. != null) | sub("^(\.\./)+"; "")' "${1:-k8s/clusters/homelab}"/*.yaml |
  sort -u | xargs flux-schema validate
