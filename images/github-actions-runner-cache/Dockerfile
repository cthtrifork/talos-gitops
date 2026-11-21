# The github-actions-runner image with a patched Runner.Worker.dll, for the runners that use the in-cluster cache server
# (k8s/apps/gha-cache). The stock runner overwrites ACTIONS_RESULTS_URL with GitHub's address before every action; the patch
# renames the string it assigns to (ACTIONS_RESULTS_URL becomes ACTIONS_RESULTS_ORL), so the value set on the pod stays.
# https://gha-cache-server.falcondev.io/getting-started#binary-patch
# renovate: datasource=docker depName=ghcr.io/cthtrifork/talos-gitops/github-actions-runner versioning=semver
FROM ghcr.io/cthtrifork/talos-gitops/github-actions-runner:2.338.2-20261115.5@sha256:f81f290854b872f0ef3bebf642d6d3148f9bdd6886136860a4102701382c7fd8

USER root

# Fail the build when the string is not found (a runner version that moved it) or the patch did not land
RUN set -eu; \
  f=/home/runner/bin/Runner.Worker.dll; \
  export LC_ALL=C; \
  grep -qaP 'A\x00C\x00T\x00I\x00O\x00N\x00S\x00_\x00R\x00E\x00S\x00U\x00L\x00T\x00S\x00_\x00U\x00R\x00L\x00' "$f"; \
  sed -i 's/\x41\x00\x43\x00\x54\x00\x49\x00\x4F\x00\x4E\x00\x53\x00\x5F\x00\x52\x00\x45\x00\x53\x00\x55\x00\x4C\x00\x54\x00\x53\x00\x5F\x00\x55\x00\x52\x00\x4C\x00/\x41\x00\x43\x00\x54\x00\x49\x00\x4F\x00\x4E\x00\x53\x00\x5F\x00\x52\x00\x45\x00\x53\x00\x55\x00\x4C\x00\x54\x00\x53\x00\x5F\x00\x4F\x00\x52\x00\x4C\x00/g' "$f"; \
  grep -qaP 'A\x00C\x00T\x00I\x00O\x00N\x00S\x00_\x00R\x00E\x00S\x00U\x00L\x00T\x00S\x00_\x00O\x00R\x00L\x00' "$f"; \
  ! grep -qaP 'A\x00C\x00T\x00I\x00O\x00N\x00S\x00_\x00R\x00E\x00S\x00U\x00L\x00T\x00S\x00_\x00U\x00R\x00L\x00' "$f"

USER runner
