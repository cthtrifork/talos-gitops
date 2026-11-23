#!/usr/bin/env bash
# Validate the manifests and kustomize overlays under the given paths (default: k8s) with flux-schema.
# Schema locations and skip rules are in .fluxschema.yml.
set -euo pipefail

export FLUX_SCHEMA_CONFIG="${0%/*}/../.fluxschema.yml"
flux-schema validate "${@:-k8s}"
