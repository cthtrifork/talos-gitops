# Releasing

The four images in `images/` (`github-actions-runner`, `claude-runner`, `kagent-claude-harness`, `fileserver`) are built, signed and released
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
| `kagent-claude-harness` | `build-kagent-claude-harness.yaml` | merge to `images/kagent-claude-harness/**`, weekly, manual |
| `fileserver`            | `build-fileserver.yaml`            | merge to `images/fileserver/**`, manual              |

A build of `main` pushes `ghcr.io/cthtrifork/talos-gitops/<image>:<tag>` and `latest`, signs it (cosign), attests its
provenance and creates a release. A pull request, or a manual run on another branch, only builds the image to check it.
The weekly runs pick up new packages.

| Image                   | Tool version                                                        | Image tag                | Release                       |
| ----------------------- | ------------------------------------------------------------------- | ------------------------ | ----------------------------- |
| `github-actions-runner` | actions/runner of the base image (`ARG RUNNER_VERSION`)             | `2.338.2-20261114.58`    | `runner-2.338.2-20261114.58`  |
| `claude-runner`         | Claude Code (`ARG CLAUDE_CODE_VERSION`)                             | `2.1.311-20261114.58`    | `claude-2.1.311-20261114.58`  |
| `kagent-claude-harness` | kagent's claude-harness base (`ARG KAGENT_VERSION`, bumped with the chart) | `1.0.1-20261120.1` | `kagent-harness-1.0.1-20261120.1` |
| `fileserver`            | none: our own code, so `0.0.0`                                      | `0.0.0-20261114.58`      | `fileserver-0.0.0-20261114.58` |

The image tag is valid [semver](https://semver.org): the tool's version, then the build date and run number as the
prerelease, which compare numerically, so newer builds and newer tool versions sort higher. Renovate bumps the two tool
versions, so a bump produces a new tagged image and release on merge. The release name has a prefix. The notes list the
commits that touched the image since the previous release of the same image, and a release is never marked as the
repository's latest one. Deployments pin the tag plus digest, never `latest`.
