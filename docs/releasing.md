# Releasing

There are two release streams:

- `claude-runner` and `fileserver` (in `images/`) are versioned together with [Semantic Versioning](https://semver.org).
  The version comes from the pull request titles (steps 1 to 3 below).
- `github-actions-runner` has its own stream, published automatically (see the end of this page).

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
grouped notes and the next version (`vX.Y.Z`).

## 3. Publish it

Publish the draft (tick *pre-release* for `vX.Y.Z-rc.1` style versions). GitHub creates the tag, and the tag triggers
`.github/workflows/build-image.yaml`, which builds, signs (cosign) and attests (SLSA) the two images.

| Trigger                    | Image tags                         |
| -------------------------- | ---------------------------------- |
| tag `v1.2.3`               | `v1.2.3`, `v1.2`, `v1`, `latest`   |
| tag `v1.3.0-rc.1`          | `v1.3.0-rc.1` only                 |
| manual run (tag prefix `rc`) | `rc-<short sha>`                 |
| pull request               | built, not pushed                  |

Deployments should pin an exact tag plus digest, never `latest` or a floating tag.

Note: a tag created with the default `GITHUB_TOKEN` does not trigger workflows, so publish the draft as a person
(UI or `gh release edit vX.Y.Z --draft=false`).

## The GitHub Actions runner image

`.github/workflows/build-runner-image.yaml` publishes `ghcr.io/cthtrifork/talos-gitops/github-actions-runner` on its own,
with no draft to publish:

| Trigger                                                | Result                                                          |
| ------------------------------------------------------ | --------------------------------------------------------------- |
| merge that changes `images/github-actions-runner/**`   | image `runner-YYYYMMDD-<run number>` and `latest`, and a release of that name |
| weekly run (Sunday), or a manual run                   | the same: it picks up new packages and the Trivy database baked into the image |
| pull request                                           | built, not pushed                                               |

The image is signed (cosign) and has a provenance attestation. The release notes list the commits that touched the image
since the previous `runner-` release, and the release is never marked as the repository's latest one: that stays the
`vX.Y.Z` release. Deployments pin the tag plus digest, never `latest`.
