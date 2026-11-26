# Releasing

The images `github-actions-runner`, `claude-runner` and `fileserver` in `images/` are built, signed and released
automatically. There is no draft to publish and no repo-wide version.

## Write Conventional Commit PR titles

`type(scope)!: summary`, enforced by `.github/workflows/pr-title.yaml`. Squash merge, so the title is the commit subject,
and the release notes list those subjects.

## How an image is released

Each image has a small workflow that calls `.github/workflows/build-release-image.yaml`:

| Image                   | Workflow                           | Runs on                                              |
| ----------------------- | ---------------------------------- | ---------------------------------------------------- |
| `github-actions-runner` | `build-github-actions-runner.yaml` | merge to `images/github-actions-runner/**`, weekly, manual |
| `claude-runner`         | `build-claude-runner.yaml`         | merge to `images/claude-runner/**`, weekly, manual   |
| `fileserver`            | `build-fileserver.yaml`            | merge to `images/fileserver/**`, manual              |

A build of `main` pushes `ghcr.io/cthtrifork/talos-gitops/<image>:<tag>` and `latest`, signs it (cosign), attests its
provenance and creates a release. A pull request, or a manual run on another branch, builds the image to check it, pushes only its `pr-<n>` tag (same-repository PRs) and comments a Trivy scan against `latest`.
The weekly runs pick up new packages.

| Image                   | Tool version                                                        | Image tag                | Release                       |
| ----------------------- | ------------------------------------------------------------------- | ------------------------ | ----------------------------- |
| `github-actions-runner` | actions/runner of the base image (`ARG RUNNER_VERSION`)             | `2.338.2-20261114.58`    | `runner-2.338.2-20261114.58`  |
| `claude-runner`         | Claude Code (`ARG CLAUDE_CODE_VERSION`)                             | `2.1.311-20261114.58`    | `claude-2.1.311-20261114.58`  |
| `fileserver`            | none: our own code, so `0.0.0`                                      | `0.0.0-20261114.58`      | `fileserver-0.0.0-20261114.58` |

The image tag is valid [semver](https://semver.org): the tool's version, then the build date and run number as the
prerelease, which compare numerically, so newer builds and newer tool versions sort higher. Renovate bumps the two tool
versions, so a bump produces a new tagged image and release on merge. The release name has a prefix. The notes list the
commits that touched the image since the previous release of the same image, and a release is never marked as the
repository's latest one. Deployments pin the tag plus digest, never `latest`.

## Patched third-party images

`images/patched/copa.yaml` lists upstream images that [Copacetic](https://project-copacetic.github.io/copacetic/) patches
(OS packages, comprehensive update, `linux/amd64`). `.github/workflows/build-patched-images.yaml` runs on a change to that
directory, weekly and by hand, and pushes `ghcr.io/cthtrifork/talos-gitops/patched/<name>:<tag>-patched`. A build of `main`
signs it (cosign) and attests its provenance, so the `cthtrifork-images` policy admits it; the summary shows the fixable
HIGH/CRITICAL findings before and after. A pull request from this repository pushes `<tag>-patched-pr<number>` (unsigned,
so it cannot run in the cluster) and scans it; delete the test tags in GHCR when done. Manifests pin the digest of the
patched image, and Renovate bumps it. See `images/patched/README.md`.
