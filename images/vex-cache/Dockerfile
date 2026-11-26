# Pre-warmed Trivy VEX cache, mounted read-only by the trivy-operator scan jobs (trivy-operator/helm-release.yaml).
# The build context is the repository root: vex/ is baked in too.
# homelab-built-at (epoch seconds) and the hashes of the ignore file and policy are read by the vex-cache-refresh CronJob (k8s/infra/trivy-system/vex-cache-refresh).
FROM ghcr.io/aquasecurity/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb AS trivy

# python: the trivy image has no httpd
FROM python:3.15-alpine@sha256:0f9552bb28711333da16915ec146f5e6bb44a7fdac9ced15dc17c2e0206346dd AS build
COPY --from=trivy /usr/local/bin/trivy /usr/local/bin/trivy
ENV HOME=/root
COPY images/vex-cache/repository.yaml /root/.trivy/vex/repository.yaml
COPY vex /src/vex
COPY k8s/infra/trivy-system/trivy-operator/ignore/trivyignore.yaml k8s/infra/trivy-system/trivy-operator/ignore/ignore-policy.rego /src/ignore/
# serve vex/ over HTTP: Trivy reads a non-GitHub repository from <url>/.well-known/vex-repository.json
# trivy creates 0700 directories and the scan jobs run as 65534, hence the chmod
# the 168h update_interval (24h upstream) only matters if skip-vex-repo-update is ignored
# GITHUB_TOKEN (a build secret, never in a layer) lifts the unauthenticated GitHub API rate limit that Trivy hits when it downloads the hub
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN set -eu; \
    mkdir -p /srv/homelab/.well-known; \
    tar -C /src -czf /srv/homelab.tar.gz vex; \
    sed 's#"url": "[^"]*"#"url": "http://127.0.0.1:8080/homelab.tar.gz//vex"#' /src/vex/vex-repository.json > /srv/homelab/.well-known/vex-repository.json; \
    python3 -m http.server 8080 --bind 127.0.0.1 --directory /srv >/dev/null 2>&1 & \
    sleep 2; \
    trivy vex repo download --cache-dir /out; \
    sed -i 's#"update_interval": *"24h"#"update_interval": "168h"#' /out/vex/repositories/*/vex-repository.json; \
    test -s /out/vex/repositories/default/0.1/index.json; \
    test -s /out/vex/repositories/homelab-vexhub/0.1/index.json; \
    date -u +%s > /out/vex/homelab-built-at; \
    sha256sum < /src/ignore/trivyignore.yaml | cut -d' ' -f1 > /out/vex/trivyignore.sha256; \
    sha256sum < /src/ignore/ignore-policy.rego | cut -d' ' -f1 > /out/vex/ignore-policy.sha256; \
    chmod -R a+rX /out

FROM scratch
COPY --from=build /out/vex/ /
