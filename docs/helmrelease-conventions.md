# HelmRelease conventions

Every HelmRelease must recover from a failed install or upgrade; without retries it goes `Stalled` and stays down until someone resets it by hand.

- `spec.upgrade.remediation.retries` is set (non-zero, `-1` retries forever).
- `spec.install.remediation.retries` is set, or `spec.install.strategy.name` is `RetryOnFailure`.

The Kyverno ValidatingPolicy `require-helmrelease-remediation` (`k8s/infra/image-policies/`) denies a HelmRelease that breaks this when it is created or updated.

Rollback and retry does not heal an immutable-field change (for example a StatefulSet `volumeClaimTemplates`). `remediation.strategy: uninstall` would, but it deletes the release's resources, so only opt in per release.
