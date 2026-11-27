# Source: https://github.com/actions/runner/blob/main/images/Dockerfile
# Source: https://github.com/actions/runner/blob/main/images/Dockerfile
ARG RUNNER_VERSION=2.338.2@sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

# CUSTOM
USER root

# The cache-server wrapper (see the script) patches the runner binary when a scale set starts the runner through it
COPY --chmod=0755 use-cache-server /usr/local/bin/use-cache-server
RUN chown runner /home/runner/bin/Runner.Worker.dll

ENV NONINTERACTIVE=1
ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  build-essential procps curl file git tree git wget \
  podman uidmap fuse-overlayfs iptables buildah slirp4netns \
  netavark dnsutils \
  skopeo gettext rsync \
  socat sqlite3 qemu-system-x86 qemu-utils \
  imagemagick \
  && rm -rf /var/lib/apt/lists/*

# Rootful storage config – no userns
RUN mkdir -p /etc/containers /var/lib/containers /run/containers/storage && \
  cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
[storage.options]
mount_program = "/usr/bin/fuse-overlayfs"
additionalimagestores = [ "/var/lib/shared",]
EOF


RUN mkdir -p /var/lib/shared && \
  chmod -R a+rx /var/lib/shared

# 65536 IDs: rootless podman unpacks images with files owned by high IDs (65532, 10001)
RUN echo runner:100000:65536 | tee /etc/subuid; \
  echo runner:100000:65536 | tee /etc/subgid;

USER runner
ENV DOCKER_BUILDKIT=1
ENV HOME=/home/runner
ENV PATH="/home/runner/.local/bin:${PATH}"
ENV XDG_RUNTIME_DIR=/run/user/1001

# Ensure the home tree exists and is owned by the runner
RUN mkdir -p /home/runner/.local/bin /home/runner/.cache /home/runner/.config /home/runner/.docker \
  && chown -R 1001:1001 /home/runner

# Ensure default docker config
RUN echo "{ \"auths\": {} }" > /home/runner/.docker/config.json

# Software list: https://github.com/actions/runner-images/blob/main/images/ubuntu-slim/ubuntu-slim-Readme.md
## We use Homebrew as the primary package manager
# Install Homebrew first
RUN /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
  && echo >> /home/runner/.bashrc \
  && echo "eval '$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)'" >> /home/runner/.bashrc

COPY Brewfile Brewfile
RUN eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && brew bundle

ENV HOME=/home/runner

# the private runners pull the databases through zot and pass their CA bundle as the secret "ca"
ARG TRIVY_DB_REGISTRY=ghcr.io

RUN --mount=type=secret,id=ca,required=false,mode=0444 \
  if [ -f /run/secrets/ca ]; then export SSL_CERT_FILE=/run/secrets/ca; fi \
  && mkdir -p "${HOME}/.cache/trivy/db" \
  && oras pull "${TRIVY_DB_REGISTRY}/aquasecurity/trivy-db:2" \
  && tar -xzf db.tar.gz -C "${HOME}/.cache/trivy/db" \
  && rm db.tar.gz

RUN --mount=type=secret,id=ca,required=false,mode=0444 \
  if [ -f /run/secrets/ca ]; then export SSL_CERT_FILE=/run/secrets/ca; fi \
  && mkdir -p "${HOME}/.cache/trivy/java-db" \
  && oras pull "${TRIVY_DB_REGISTRY}/aquasecurity/trivy-java-db:1" \
  && tar -xzf javadb.tar.gz -C "${HOME}/.cache/trivy/java-db" \
  && rm javadb.tar.gz

# Remove Haskell, android and dotnet
RUN rm -rf /usr/share/dotnet || true
RUN rm -rf /usr/local/lib/android || true
RUN rm -rf /opt/ghc || true
RUN rm -rf /usr/local/.ghcup || true

WORKDIR /home/runner
