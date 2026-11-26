# Patched third-party images

`copa.yaml` lists upstream images that [Copacetic](https://project-copacetic.github.io/copacetic/) patches (OS packages
only) and `.github/workflows/build-patched-images.yaml` publishes. See `docs/releasing.md`.

- Result: `ghcr.io/cthtrifork/talos-gitops/patched/<name>:<tag>-patched`, signed and attested by the workflow, which the
  `cthtrifork-images` Kyverno policy checks. Manifests pin its digest like any other image.
- The tag is reused by every run (weekly, and when this directory changes), so the digest moves and Renovate bumps it.
- Add an image only when its base has a package manager Copa supports (Debian, Ubuntu, Alpine, RHEL family) and Trivy
  shows fixable OS findings. Static Go and distroless images gain nothing.
- A pull request runs Copa without pushing; check that step before merging.
