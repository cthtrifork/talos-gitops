# The Claude images of this repo, from one Dockerfile so the tools and their versions are in one place:
#   --target runner          (the default, last stage) the Claude Code self-hosted environment runner, run as the claude-rc pod and as the image of the bare Substrate actors
#                            (https://code.claude.com/docs/en/self-hosted-environments-deploy). Anthropic publishes no runner image, so this wraps the claude binary. Runs as non-root.
#   --target kagent-harness  kagent's claude-harness (the Claude Code binary and kagent's adapter) plus the same tools, for the kagent agents (k8s/apps/kagent). The adapter pins an
#                            exact Claude Code version (2.1.285 for kagent 1.0.1) and refuses to start on any other, so this image does not follow the Claude Code of the runner.
# The tools stage holds the static binaries both carry (kubectl, kustomize, helm, flux, yq, kubeconform, crane, actionlint, gh); each target adds its own packages. Renovate bumps the
# versions here, once, and one pull request moves both images. The cluster tools of the runner (talosctl, omnictl, the Flux MCP server) are not in the harness: it has no cluster access.
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
# The kagent release of the harness image below (the chart's files/builtin-harness-images.json): bump the digest and this together with the kagent chart. Not tracked by Renovate.
ARG KAGENT_VERSION=1.0.1
# yamllint at the version CI pins, for both targets
# renovate: datasource=pypi depName=yamllint
ARG YAMLLINT_VERSION=1.38.0

# ---------------------------------------------------------------------------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS tools
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Keep within one minor version of the cluster
ARG KUBECTL_VERSION=v1.34.1
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=2.105.0
# renovate: datasource=github-releases depName=google/go-containerregistry
ARG CRANE_VERSION=0.22.1
# renovate: datasource=github-releases depName=mikefarah/yq
ARG YQ_VERSION=4.54.3
# renovate: datasource=github-releases depName=kubernetes-sigs/kustomize extractVersion=^kustomize/v(?<version>.+)$
ARG KUSTOMIZE_VERSION=5.8.3
# renovate: datasource=github-releases depName=yannh/kubeconform
ARG KUBECONFORM_VERSION=0.8.0
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=4.3.2
# renovate: datasource=github-releases depName=fluxcd/flux2
ARG FLUX_VERSION=2.10.1
# renovate: datasource=github-releases depName=rhysd/actionlint
ARG ACTIONLINT_VERSION=1.7.12

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /out/bin

RUN curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /out/bin/kubectl \
 && echo "$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256")  /out/bin/kubectl" | sha256sum -c - \
 && chmod +x /out/bin/kubectl

# GitHub CLI, checksum verified against the release's checksums file
RUN base="https://github.com/cli/cli/releases/download/v${GH_VERSION}" \
 && tarball="gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/gh_${GH_VERSION}_checksums.txt" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" \
 && install -m 0755 "gh_${GH_VERSION}_linux_amd64/bin/gh" /out/bin/gh \
 && rm -rf "${tarball}" "gh_${GH_VERSION}_linux_amd64"

# crane, for read-only inspection of image manifests, configs and layer sizes
RUN base="https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}" \
 && tarball="go-containerregistry_Linux_x86_64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/checksums.txt" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" crane \
 && install -m 0755 crane /out/bin/crane \
 && rm -rf "${tarball}" crane

# yq (mikefarah, the one the repo's CI scripts use). Its checksums file has the hashes in columns (checksums_hashes_order); SHA-256 is the 18th hash, so field 19.
RUN base="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/yq_linux_amd64" -o yq \
 && echo "$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/checksums" | awk '$1=="yq_linux_amd64"{print $19}')  yq" | sha256sum -c - \
 && install -m 0755 yq /out/bin/yq \
 && rm -f yq

# The kustomize tag contains a slash, so it is URL-encoded in the download path
RUN base="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}" \
 && tarball="kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/checksums.txt" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" kustomize \
 && install -m 0755 kustomize /out/bin/kustomize \
 && rm -rf "${tarball}" kustomize

RUN base="https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}" \
 && tarball="kubeconform-linux-amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/CHECKSUMS" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" kubeconform \
 && install -m 0755 kubeconform /out/bin/kubeconform \
 && rm -rf "${tarball}" kubeconform

RUN tarball="helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "https://get.helm.sh/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "https://get.helm.sh/${tarball}.sha256sum" | sha256sum -c - \
 && tar -xzf "${tarball}" linux-amd64/helm \
 && install -m 0755 linux-amd64/helm /out/bin/helm \
 && rm -rf "${tarball}" linux-amd64

RUN base="https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}" \
 && tarball="flux_${FLUX_VERSION}_linux_amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/flux_${FLUX_VERSION}_checksums.txt" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" flux \
 && install -m 0755 flux /out/bin/flux \
 && rm -rf "${tarball}" flux

RUN base="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}" \
 && tarball="actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/actionlint_${ACTIONLINT_VERSION}_checksums.txt" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" actionlint \
 && install -m 0755 actionlint /out/bin/actionlint \
 && rm -rf "${tarball}" actionlint

# ---------------------------------------------------------------------------------------------------------------------------------------------
# kagent's claude-harness of the release the charts install (digest from the chart's files/builtin-harness-images.json), plus the tools. The harness runs Claude Code with its Bash tool
# on and its permission prompts off, inside the Substrate sandbox, so a tool the agent should run has to be here. A Harness points at the published image with spec.workload.image,
# by digest (k8s/apps/kagent/README.md). GitHub: the gateway injects the credential; git and gh must send a placeholder header, which the Harness sets by environment (GIT_CONFIG_*, GH_TOKEN),
# not this image, because the runner of the same Dockerfile uses a real token.
FROM ghcr.io/kagent-dev/kagent/claude-harness@sha256:111d28bc8552469b028d91ecd2352c9d44811aba07be12b1e6868db7948f904e AS kagent-harness
ARG KAGENT_VERSION
ARG YAMLLINT_VERSION
SHELL ["/bin/sh", "-o", "errexit", "-c"]
USER root
RUN apk add --no-cache jq shellcheck python3 py3-pip \
 && pip install --no-cache-dir --break-system-packages "yamllint==${YAMLLINT_VERSION}" \
 && git config --system user.name "Claude" \
 && git config --system user.email "noreply@anthropic.com" \
 && git config --system --add safe.directory '*'
COPY --from=tools /out/bin/ /usr/local/bin/
LABEL org.opencontainers.image.source="https://github.com/cthtrifork/talos-gitops"
LABEL org.opencontainers.image.description="kagent's Claude harness with kustomize, helm, kubeconform and the other tools of this repo"
LABEL org.opencontainers.image.version="${KAGENT_VERSION}"
USER 65532:65532

# ---------------------------------------------------------------------------------------------------------------------------------------------
# The runner (last, so a plain build gives it)
FROM ${DEBIAN_IMAGE} AS runner
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Renovate bumps the version. The linux-x64 checksum is read from the release manifest at build time
# (https://downloads.claude.ai/claude-code-releases/<version>/manifest.json), so there is nothing to bump by hand.
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.326
# renovate: datasource=github-releases depName=controlplaneio-fluxcd/flux-operator
ARG FLUX_OPERATOR_VERSION=0.63.0
# renovate: datasource=github-releases depName=siderolabs/talos
ARG TALOSCTL_VERSION=1.14.6
# renovate: datasource=github-releases depName=siderolabs/omni
ARG OMNICTL_VERSION=1.13.3
ARG YAMLLINT_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates openssh-client jq python3 python3-pip shellcheck make \
 && rm -rf /var/lib/apt/lists/*

RUN base="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}" \
 && sha="$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/manifest.json" | jq -er '.platforms."linux-x64".checksum')" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/linux-x64/claude" -o /usr/local/bin/claude \
 && echo "${sha}  /usr/local/bin/claude" | sha256sum -c - \
 && chmod +x /usr/local/bin/claude

# The tools of the tools stage. The real gh lives outside PATH; the gh wrapper hands it the mounted token (see below), so tokens refreshed by the CronJob are picked up.
COPY --from=tools /out/bin/kubectl /out/bin/crane /out/bin/yq /out/bin/kustomize /out/bin/kubeconform /out/bin/helm /out/bin/flux /out/bin/actionlint /usr/local/bin/
COPY --from=tools /out/bin/gh /usr/local/libexec/gh
COPY gh-wrapper /usr/local/bin/gh
RUN chmod +x /usr/local/bin/gh

# Flux MCP server (https://fluxcd.control-plane.io/mcp/), checksum verified against the release's checksums file.
# The deployment registers it read-only; it talks to the cluster with the pod's ServiceAccount.
RUN base="https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v${FLUX_OPERATOR_VERSION}" \
 && tarball="flux-operator-mcp_${FLUX_OPERATOR_VERSION}_linux_amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/flux-operator_${FLUX_OPERATOR_VERSION}_checksums.txt" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" flux-operator-mcp \
 && install -m 0755 flux-operator-mcp /usr/local/bin/flux-operator-mcp \
 && rm -rf "${tarball}" flux-operator-mcp

# talosctl and omnictl, checksum verified against the releases' sha256sum.txt. The pod reaches the Talos API through Omni
# with a read-only service account (OMNI_SERVICE_ACCOUNT_KEY, see k8s/apps/claude-system/README.md).
RUN base="https://github.com/siderolabs/talos/releases/download/v${TALOSCTL_VERSION}" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/talosctl-linux-amd64" -o talosctl-linux-amd64 \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/sha256sum.txt" | grep -F "  talosctl-linux-amd64" | sha256sum -c - \
 && install -m 0755 talosctl-linux-amd64 /usr/local/bin/talosctl \
 && rm -f talosctl-linux-amd64

RUN base="https://github.com/siderolabs/omni/releases/download/v${OMNICTL_VERSION}" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/omnictl-linux-amd64" -o omnictl-linux-amd64 \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/sha256sum.txt" | grep -F "  omnictl-linux-amd64" | sha256sum -c - \
 && install -m 0755 omnictl-linux-amd64 /usr/local/bin/omnictl \
 && rm -f omnictl-linux-amd64

# yamllint at the version CI pins; Debian's pip is externally managed, hence --break-system-packages
RUN pip install --no-cache-dir --break-system-packages "yamllint==${YAMLLINT_VERSION}"

# GitHub access: a token mounted at /etc/github/token, handed to git only for github.com
COPY git-credential-github-token /usr/local/bin/git-credential-github-token
RUN chmod +x /usr/local/bin/git-credential-github-token \
 && git config --system credential.helper /usr/local/bin/git-credential-github-token \
 && git config --system user.name "Claude" \
 && git config --system user.email "noreply@anthropic.com" \
 && git config --system --add safe.directory '*'

RUN useradd --uid 65532 --create-home --home-dir /home/claude --shell /bin/bash claude \
 && mkdir -p /workspace && chown claude:claude /workspace
USER 65532
ENV HOME=/home/claude
WORKDIR /workspace
ENTRYPOINT ["claude"]
