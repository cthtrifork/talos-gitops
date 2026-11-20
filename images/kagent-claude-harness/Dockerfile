# kagent's Claude harness (the Claude Code binary and kagent's adapter) plus the tools the agents of k8s/apps/kagent-agents use on this repo: kubectl, kustomize, helm, flux, yq, kubeconform, crane,
# actionlint, shellcheck, yamllint, gh, git, jq. The harness runs Claude Code with its built-in Bash tool enabled and its permission prompts off, inside the Substrate sandbox, so a tool the
# agent should run has to be in this image. The tool versions and checksum checks follow images/claude-runner/Dockerfile (the cluster tools talosctl, omnictl and the Flux MCP server are left out: the
# agent has no cluster access). A Harness points at this image with spec.workload.image, by digest (k8s/apps/kagent/README.md).
#
# Base: the claude-harness image of the kagent release the charts install (kagent 1.0.1, digest from the chart's files/builtin-harness-images.json). Bump it with the chart.
# The tag is x.y.z of kagent, so the release of this image is <kagent version>-YYYYMMDD.<run>. Every download retries: dl.k8s.io has dropped a TLS connection mid-build.
ARG KAGENT_VERSION=1.0.1
FROM ghcr.io/kagent-dev/kagent/claude-harness@sha256:111d28bc8552469b028d91ecd2352c9d44811aba07be12b1e6868db7948f904e
ARG KAGENT_VERSION
SHELL ["/bin/sh", "-o", "errexit", "-c"]
USER root

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
ARG FLUX_VERSION=2.10.0
# renovate: datasource=github-releases depName=rhysd/actionlint
ARG ACTIONLINT_VERSION=1.7.12
# renovate: datasource=pypi depName=yamllint
ARG YAMLLINT_VERSION=1.38.0

RUN apk add --no-cache curl jq shellcheck python3 py3-pip

RUN curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl \
 && echo "$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256")  /usr/local/bin/kubectl" | sha256sum -c - \
 && chmod +x /usr/local/bin/kubectl

# GitHub CLI, checksum verified against the release's checksums file
RUN base="https://github.com/cli/cli/releases/download/v${GH_VERSION}" \
 && tarball="gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/gh_${GH_VERSION}_checksums.txt" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" \
 && install -m 0755 "gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && rm -rf "${tarball}" "gh_${GH_VERSION}_linux_amd64"

RUN base="https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}" \
 && tarball="go-containerregistry_Linux_x86_64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/checksums.txt" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" crane \
 && install -m 0755 crane /usr/local/bin/crane \
 && rm -rf "${tarball}" crane

# yq (mikefarah): its checksums file lists the hashes in columns, SHA-256 being the 18th hash, so field 19
RUN base="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/yq_linux_amd64" -o yq \
 && echo "$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/checksums" | awk '$1=="yq_linux_amd64"{print $19}')  yq" | sha256sum -c - \
 && install -m 0755 yq /usr/local/bin/yq \
 && rm -f yq

# The kustomize tag contains a slash, so it is URL-encoded in the download path
RUN base="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}" \
 && tarball="kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/checksums.txt" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" kustomize \
 && install -m 0755 kustomize /usr/local/bin/kustomize \
 && rm -rf "${tarball}" kustomize

RUN base="https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}" \
 && tarball="kubeconform-linux-amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/CHECKSUMS" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" kubeconform \
 && install -m 0755 kubeconform /usr/local/bin/kubeconform \
 && rm -rf "${tarball}" kubeconform

RUN tarball="helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "https://get.helm.sh/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "https://get.helm.sh/${tarball}.sha256sum" | sha256sum -c - \
 && tar -xzf "${tarball}" linux-amd64/helm \
 && install -m 0755 linux-amd64/helm /usr/local/bin/helm \
 && rm -rf "${tarball}" linux-amd64

RUN base="https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}" \
 && tarball="flux_${FLUX_VERSION}_linux_amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/flux_${FLUX_VERSION}_checksums.txt" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" flux \
 && install -m 0755 flux /usr/local/bin/flux \
 && rm -rf "${tarball}" flux

RUN base="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}" \
 && tarball="actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
 && cd /tmp \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/${tarball}" -o "${tarball}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${base}/actionlint_${ACTIONLINT_VERSION}_checksums.txt" | grep -F "  ${tarball}" | sha256sum -c - \
 && tar -xzf "${tarball}" actionlint \
 && install -m 0755 actionlint /usr/local/bin/actionlint \
 && rm -rf "${tarball}" actionlint

# yamllint at the version CI pins; Alpine's pip is externally managed, hence --break-system-packages
RUN pip install --no-cache-dir --break-system-packages "yamllint==${YAMLLINT_VERSION}"

# GitHub access through the Substrate egress gateway: the actor holds no token. git and gh send a placeholder in the header the gateway replaces with the real credential
# (an EgressPolicy `authentication` on github.com and api.github.com, k8s/apps/kagent-agents/egresspolicy.yaml). The gateway replaces a header the request already carries and adds none,
# so git must send it: Basic for github.com (the credential is base64 of x-access-token:<token>), and gh sends its own Authorization header from GH_TOKEN, which the Harness sets to the same placeholder.
RUN git config --system http.https://github.com/.extraheader "Authorization: Basic kagent-credential-injected" \
 && git config --system user.name "Claude" \
 && git config --system user.email "noreply@anthropic.com" \
 && git config --system --add safe.directory '*'

LABEL org.opencontainers.image.source="https://github.com/cthtrifork/talos-gitops"
LABEL org.opencontainers.image.description="kagent's Claude harness with kustomize, helm, kubeconform and the other tools of this repo"
LABEL org.opencontainers.image.version="${KAGENT_VERSION}"

USER 65532:65532
