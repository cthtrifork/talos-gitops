## Summary
<!-- Explain what changed and why. Link the related issue (for example, Closes #123). -->

## Validation
<!-- Record relevant local checks and results, or explain why they were not run.
CI checks YAML formatting, anchors, encrypted Secrets, manifest filenames, shell scripts,
Actions workflows, Renovate config, manifest schemas, and Flux Kustomize builds.
Path-filtered workflows also run e2e, image builds, and Renovate dry runs when applicable.
Review the checks for the latest commit; a skipped check is not evidence of validation. -->

## Rollout and rollback
<!-- Describe operational impact, dependencies, manual steps, and rollback considerations.
For documentation-only or non-operational changes, write "Not applicable". -->

## Checklist
<!-- Check applicable items; mark others N/A. -->
- [ ] The PR title follows Conventional Commits (`type(scope): summary`, for example, `fix(flux): correct reconciliation path`).
- [ ] Application manifests under `k8s/apps/` use kind-based filenames and one resource kind per file, except approved groups such as `rbac.yaml`; affected Kustomize references are updated.
- [ ] Secrets are SOPS-encrypted, and related documentation is updated.
- [ ] Generated changes are reviewed, including any commits added by the Render manifests or Update KubeVirt operators workflows.
- [ ] For image changes, the Trivy vulnerability delta and applicable image build results are reviewed; vulnerability findings are informational and need human review.
