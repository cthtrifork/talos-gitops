# vex-cache-refresh

Rescans workloads when a new `vex-cache` artifact is published, so the reports follow a changed VEX document,
ignore file or ignore policy. The CronJob runs every 10 minutes in `trivy-system` (`cronjob.yaml`, script in `refresh.sh`).

## Flow

```mermaid
flowchart LR
    change["Merge to main:<br/>vex/, trivyignore.yaml<br/>or ignore-policy.rego"] --> ci["images.yaml publishes<br/>the vex-cache artifact"]
    change --> flux["Flux applies the ConfigMaps<br/>trivy-ignorefile, trivy-ignorepolicy"]
    ci --> job["CronJob vex-cache-refresh<br/>(every 10 min)"]
    flux -.->|"guard: live hashes"| job
    job -->|"deletes reports"| operator["trivy-operator scans<br/>those workloads again"]
    operator --> reports["New VulnerabilityReports,<br/>sent to Dependency-Track by sbom-hook"]
```

## What one run does

A run started from the Run jobs page skips all of this and deletes all reports.

```mermaid
flowchart TB
    start["Read homelab-built-at<br/>from the artifact"] --> first{"vex-cache-state<br/>has a timestamp?"}
    first -->|"no: first run"| record
    first -->|yes| newer{"artifact newer than<br/>the stored one?"}
    newer -->|no| done["Exit"]
    newer -->|yes| scope{"ignore file or policy<br/>hash changed?"}
    scope -->|"no: only VEX"| some["Delete the reports of images<br/>with a homelab-vexhub statement"]
    scope -->|yes| guard{"live ConfigMap hashes ==<br/>hashes in the artifact?"}
    guard -->|"no: Flux is behind,<br/>retry next run"| done
    guard -->|yes| all["Delete all VulnerabilityReports"]
    some --> record["Store timestamp and hashes in<br/>ConfigMap vex-cache-state"]
    all --> record
```

## Why the guard

CI and Flux are independent: the artifact can be published minutes before Flux applies the new ignore ConfigMaps, which the scan
jobs read. Deleting then would rescan with the old rules and record the new timestamp as handled, so the change would never apply.
The artifact therefore carries the sha256 of the ignore file and policy it was built from, and the job deletes only when the live
ConfigMaps hash to the same values. Otherwise it exits and checks again on the next run. The guard applies only when the ignore file or policy changed; a change to `vex/` only skips it, since those ConfigMaps are the same as in the last handled build.

## Scope of a rescan

An ignore file or policy change can affect any report, so it deletes all of them. When only the hashes in the state match, the
change is in `vex/`: the job deletes the reports whose `<registry>/<repository>` is a `repository_url` in the `homelab-vexhub`
index of the artifact (the same index lists the zot mirror names). A missing stored hash counts as changed. Statements from the
upstream VEX Hub are not matched by image name, so a Hub-only update does not trigger a scoped delete; those reports follow
`scannerReportTTL` or a manual run.

## State and permissions

- `vex-cache-state` (`configmap-state.yaml`): `data.built-at`, `data.ignore-sha256` and `data.policy-sha256` are written by the job. The annotation `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` makes Flux create it once and never apply it again: without it each Flux reconcile removed `data.built-at`, so the job recorded "first run" and never rescanned.
- Run it now: the Run jobs page in the cockpit lists it (namespace label `claude-jobs/run`, annotation `claude-jobs/description` in `cronjob.yaml`); a manual run skips the checks and always deletes all reports.
- `rbac.yaml`: list and delete `vulnerabilityreports` cluster-wide; get and patch only the three ConfigMaps above in `trivy-system`.
- The first run records the timestamp and deletes nothing.
- A run started from the Run jobs page always deletes all reports, without the artifact or the guard, and leaves the stored timestamp alone (the next scheduled run may rescan once more).

## Check it

- `kubectl -n trivy-system get cronjob,jobs`, then `kubectl -n trivy-system logs job/<name>` says why the last run deleted or waited.
- `kubectl -n trivy-system get configmap vex-cache-state -o jsonpath='{.data.built-at}'` is the last artifact handled.
- A new artifact by hand: run the `Images` workflow (`workflow_dispatch`); a rebuild also follows a change to `vex/`, `trivyignore.yaml` or `ignore-policy.rego` on `main`.
