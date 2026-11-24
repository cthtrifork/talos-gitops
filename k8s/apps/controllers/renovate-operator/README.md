# Renovate in the cluster

[renovate-operator](https://github.com/mogenius/renovate-operator) runs Renovate for the `cthtrifork` repositories from
the namespace `renovate-system`, with a shared Valkey cache and a Garage S3 bucket for Renovate's repository cache.
The GitHub Actions workflow (`.github/workflows/renovate.yaml`) remains as a once-a-day fallback.

| Part | Where |
|---|---|
| Namespace, Renovate operator and CRDs, Valkey operator and cluster, network policies and ExternalSecrets | here (`app-controllers`, so the CRDs exist first) |
| Garage (one node, `lvm-fast` meta and `lvm-bulk` data) | `k8s/apps/renovate/garage/` |
| The `RenovateJob` | `k8s/apps/renovate/renovatejob.yaml` |

`k8s/apps/renovate/` has its own Flux Kustomization, `renovate` (`k8s/clusters/homelab/renovate.yaml`, after `app-controllers`), so
the `RenovateJob` waiting for the CRDs on the first reconcile does not hold back `app`.

## Secrets

Only one Secret is created by hand, in SOPS (`k8s/apps/renovate/github-app-credentials.enc.yaml`). Namespace
`renovate-system`, with the label `renovate-operator.mogenius.com/allow-ref: "true"`:

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

## Operating notes

- Flux installs the Valkey operator before creating `ValkeyCluster/renovate`. The Renovate HelmRelease waits for the cluster's
  current generation to report Ready before switching to `valkey-renovate`.
- The cluster needs three eligible Talos hosts for the intended placement. Each of its three shards has a replica on a
  different host. Initial primaries are spread across the hosts. Check the placement and live roles again after failover.
- The cutover starts with a cold cache and empty Valkey-backed logs and sessions. Replicas provide failover, and the
  data remains ephemeral. The operator uses an alpha API.
- The UI is exposed through the Omni service exposer (`Service/renovate-operator-ui`, port 50095, Omni login, LAN only).
- Every repository in `discoveryFilters` loads its `renovate.json5` as repo config here, so a global-only option in one
  (`allowedCommands`, `platform`, `hostRules`, ...) is an error: those live in the inline global config of the `RenovateJob` and,
  for the Actions fallback, in each repository's `.github/workflows/renovate-config.js`. Keep the two in step.

## Roll back

`git revert` the Valkey change to restore the bundled standalone Valkey. Expect a cold cache, empty logs and new sessions.

`spec.suspend: true` on the `RenovateJob` and raise the schedule of the Actions workflow (once a day). There is no data to migrate.
Garage v2.5.0 cannot be downgraded.
