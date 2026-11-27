# Source: https://github.com/actions/runner/blob/main/images/Dockerfile
# Source: https://github.com/actions/runner/blob/main/images/Dockerfile
ARG RUNNER_VERSION=2.338.2@sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

# CUSTOM
USER root

# The cache-server wrapper (see the script) patches the runner binary when a scale set starts the runner through it
COPY --chmod=0755 use-cache-server /usr/local/bin/use-cache-server
RUN chown runner /home/runner/bin/Runner.Worker.dll

# Only what the jobs on these runners call: e2e.yaml (envsubst, skopeo; the other CLIs come from mise), and rootful or
# rootless podman for the bootc ISO and disk image jobs. Their tools (kubectl, helm, ...) are installed per job.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  curl git procps gettext-base skopeo \
  podman uidmap fuse-overlayfs iptables netavark slirp4netns \
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

WORKDIR /home/runner
