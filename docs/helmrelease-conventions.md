# HelmRelease conventions

Every HelmRelease must recover from a failed install or upgrade; without retries it goes `Stalled` and stays down until someone resets it by hand.

- `spec.upgrade.remediation.retries` is set (non-zero, `-1` retries forever).
- `spec.install.remediation.retries` is set, or `spec.install.strategy.name` is `RetryOnFailure`.

The Polaris custom check `helmReleaseRemediation` (`k8s/infra/policy-system/polaris/helm-release.yaml`) enforces this: the CI `polaris` job fails a PR that breaks it, and the dashboard reports it for the live HelmReleases. Nothing blocks a HelmRelease at admission.

Rollback and retry does not heal an immutable-field change (for example a StatefulSet `volumeClaimTemplates`). `remediation.strategy: uninstall` would, but it deletes the release's resources, so only opt in per release.
