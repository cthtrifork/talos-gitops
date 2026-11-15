# Releasing

Images in `images/` have two release streams:

- `fileserver` is versioned with [Semantic Versioning](https://semver.org). The version comes from the pull request
  titles, and you publish a draft release (steps 1 to 3 below).
- `github-actions-runner` and `claude-runner` are built and released automatically, because they wrap a tool whose
  version is the version of the image (see the end of this page).

## 1. Write Conventional Commit PR titles

`type(scope)!: summary`, enforced by `.github/workflows/pr-title.yaml`. Squash merge, so the title is the commit.

| Type                                                 | Release notes section  | Version bump |
| ---------------------------------------------------- | ---------------------- | ------------ |
| `!` after the type, e.g. `feat!:`                    | Breaking changes       | major        |
| `feat`                                               | New features           | minor        |
| `fix`, `security`, `perf`, `docs`, `deps`, `ci`, `build`, `refactor`, `test`, `chore`, `revert` | own sections | patch |

Renovate titles its PRs `deps: ...` (see `renovate.json5`). Add the `skip-changelog` label to keep a PR out of the notes.

## 2. Review the draft release

`.github/workflows/release-drafter.yaml` keeps a draft release on the Releases page up to date as PRs merge:
grouped notes and the next version (`vX.Y.Z`). It only looks at `vX.Y.Z` releases (`tag-prefix: v`), never at the
`runner-` and `claude-` releases of the runner images.

## 3. Publish it

Publish the draft (tick *pre-release* for `vX.Y.Z-rc.1` style versions). GitHub creates the tag, and the tag triggers
`.github/workflows/build-image.yaml`, which builds, signs (cosign) and attests (SLSA) the `fileserver` image.

| Trigger                    | Image tags                         |
| -------------------------- | ---------------------------------- |
| tag `v1.2.3`               | `v1.2.3`, `v1.2`, `v1`, `latest`   |
| tag `v1.3.0-rc.1`          | `v1.3.0-rc.1` only                 |
| manual run (tag prefix `rc`) | `rc-<short sha>`                 |
| pull request               | built, not pushed                  |

Deployments should pin an exact tag plus digest, never `latest` or a floating tag.

Note: a tag created with the default `GITHUB_TOKEN` does not trigger workflows, so publish the draft as a person
(UI or `gh release edit vX.Y.Z --draft=false`).

## The runner images

`.github/workflows/build-github-actions-runner.yaml` and `build-claude-runner.yaml` (both call
`build-release-image.yaml`) publish `github-actions-runner` and `claude-runner`
(`ghcr.io/cthtrifork/talos-gitops/<image>`) on their own, with no draft to publish:

| Trigger                                         | Result                                                                      |
| ----------------------------------------------- | --------------------------------------------------------------------------- |
| merge that changes `images/<image>/**`          | image tags `<tool version>-YYYYMMDD.<run number>` and `latest`, and a release `<prefix>-<tag>` |
| weekly run (Sunday), or a manual run            | the same: it picks up new packages (and the Trivy database in the runner)   |
| pull request, or a manual run on another branch | built, not pushed                                                           |

| Image                   | Tool version                                                        | Image tag example           | Release tag example                |
| ----------------------- | ------------------------------------------------------------------- | --------------------------- | ---------------------------------- |
| `github-actions-runner` | actions/runner of the base image (`ARG RUNNER_VERSION` in the Dockerfile) | `2.338.2-20261114.58` | `runner-2.338.2-20261114.58`       |
| `claude-runner`         | Claude Code (`ARG CLAUDE_CODE_VERSION` in the Dockerfile)           | `2.1.311-20261114.58`       | `claude-2.1.311-20261114.58`       |

The image tag is valid semver: the tool's version, then the build date and run number as the prerelease, which compare
numerically, so newer builds and newer tool versions sort higher. Renovate bumps both tool versions, so a bump produces a
new tagged image and release on merge. The notes list the commits that touched the image since the previous release of
the same image, and these releases are never marked as the repository's latest one. Deployments pin the tag plus digest,
never `latest`.
