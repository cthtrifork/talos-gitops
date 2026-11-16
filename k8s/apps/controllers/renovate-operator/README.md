# Renovate in the cluster

[renovate-operator](https://github.com/mogenius/renovate-operator) runs Renovate for the `cthtrifork` repositories from
the namespace `renovate-system`, with a shared Valkey cache and a Garage S3 bucket for Renovate's repository cache.
The GitHub Actions workflow (`.github/workflows/renovate.yaml`) stays as the fallback.

| Part | Where |
|---|---|
| Namespace, operator (CRDs, bundled Valkey), network policy, the Job that creates the generated Secrets | here (`app-controllers`, so the CRDs exist first) |
| Garage (one node, `local-path`) | `k8s/apps/renovate/garage/` |
| The `RenovateJob` (suspended) | `k8s/apps/renovate/renovatejob.yaml` |

`k8s/apps/renovate/` has its own Flux Kustomization, `renovate` (`k8s/clusters/homelab/renovate.yaml`, after `app-controllers`), so
the `RenovateJob` waiting for the CRDs on the first reconcile does not hold back `app`.

## Secrets

Only one Secret is created by hand, in SOPS (`k8s/apps/renovate/github-app-credentials.enc.yaml`, add it to
`k8s/apps/renovate/kustomization.yaml`). Namespace `renovate-system`, with the label
`renovate-operator.mogenius.com/allow-ref: "true"`:

| Key | Value |
|---|---|
| `APP_ID` | the GitHub App's id |
| `INSTALL_ID` | the installation id on the `cthtrifork` repositories |
| `PEM` | the App's private key |

External Secrets creates the rest once and never overwrites it (generated in the cluster store, `k8s/infra/secret-store/`, copied by
`external-secrets.yaml`): `garage-s3-key` (`access-key-id`, `secret-access-key`, used by Garage and the operator) and
`garage-secrets` (`rpcSecret`, `adminToken`).
Valkey has no password and there is no registry token: a private package on ghcr.io would need a `hostRules` entry
with a token in the global config of the `RenovateJob`.

## Turn it on

1. Merge, check that `app-controllers` and `renovate` reconcile and that the operator, Valkey and Garage pods are Ready and the
   Garage configure Job completed (bucket `renovate`). The UI is exposed through the Omni service exposer (`Service/renovate-operator-ui`, port 50095, Omni login, LAN only).
2. Dry run: add `extraEnv` `RENOVATE_DRY_RUN=full` to the `RenovateJob`, set `suspend: false`, and compare the report with the last
   Actions run. Check that a second run is faster (Valkey keys, objects under `renovate-cache/` in Garage) and that the
   drop metrics show nothing (skill `cilium-drops`).
3. Remove the dry run for one full cycle with `talos-gitops` only, then add the other repositories to `discoveryFilters` one at
   a time. Their `renovate.json5` files load as the global config in the Actions workflows; here they are repo config, so
   global-only options (`allowedCommands`, `platform`, `hostRules`, ...) have to move to the inline config first.
4. Slow the Actions fallback (`17 */2 * * *` to `47 */6 * * *`) in each repository.

## Roll back

`spec.suspend: true` on the `RenovateJob` and restore the old crons in the workflows. There is no data to migrate.
Garage v2.5.0 cannot be downgraded.
