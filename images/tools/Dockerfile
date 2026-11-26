# Tools for in-cluster Jobs and init containers: curl, jq, yq, kubectl, bash, git, zip. Runs as non-root.
# Same package set as https://gitlab.com/gitlab-ci-utils/curl-jq, plus yq and kubectl, on the Alpine base of claude-runner.
ARG ALPINE_IMAGE=mirror.gcr.io/library/alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
FROM ${ALPINE_IMAGE}

# Keep within one minor version of the cluster. Not tracked by Renovate; it is also the image tag's version.
ARG KUBECTL_VERSION=1.37.2
# renovate: datasource=github-releases depName=mikefarah/yq
ARG YQ_VERSION=4.54.3

# coreutils for `date -d` and friends, as in curl-jq
RUN apk add --no-cache bash git curl jq ca-certificates coreutils zip
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl \
 && echo "$(curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256")  /usr/local/bin/kubectl" | sha256sum -c - \
 && chmod +x /usr/local/bin/kubectl

# yq (mikefarah), checksum verified against the release's checksums file. Its columns follow checksums_hashes_order;
# SHA-256 is the 18th hash, so field 19.
RUN base="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}" \
 && cd /tmp \
 && curl -fsSL "${base}/yq_linux_amd64" -o yq \
 && echo "$(curl -fsSL "${base}/checksums" | awk '$1=="yq_linux_amd64"{print $19}')  yq" | sha256sum -c - \
 && install -m 0755 yq /usr/local/bin/yq \
 && rm -f yq

USER 65532
