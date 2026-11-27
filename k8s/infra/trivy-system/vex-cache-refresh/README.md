# vex-cache-refresh

Rescans workloads when a new `vex-cache` artifact is published, so the reports follow a changed VEX document,
ignore file or ignore policy. The CronJob runs every 10 minutes in `trivy-system` (`cronjob.yaml`, script in `refresh.sh`).

## Flow

```mermaid
flowchart TB
    change["Merge to main:<br/>vex/, trivyignore.yaml<br/>or ignore-policy.rego"] --> ci["images.yaml builds and<br/>publishes vex-cache"]
    change --> flux["Flux applies the ConfigMaps<br/>trivy-ignorefile, trivy-ignorepolicy<br/>(every 30 min)"]
    ci --> artifact[("vex-cache artifact<br/>homelab-built-at<br/>trivyignore.sha256<br/>ignore-policy.sha256")]

    subgraph job["CronJob vex-cache-refresh (every 10 min)"]
        start["Job starts"] --> manual{"manual run?<br/>job name has -manual-"}
        manual -->|yes| delete
        manual -->|no| read["Read homelab-built-at from the<br/>artifact (image volume)"]
        read --> first{"vex-cache-state<br/>has a timestamp?"}
        first -->|"no: first run"| record
        first -->|yes| newer{"artifact newer<br/>than the stored one?"}
        newer -->|no| done["Exit"]
        newer -->|yes| scope{"ignore file or policy<br/>hash changed?"}
        scope -->|yes| guard{"live ConfigMap hashes ==<br/>hashes in the artifact?"}
        guard -->|"no: Flux is behind,<br/>retry next run"| done
        guard -->|yes| delete["Delete all VulnerabilityReports"]
        scope -->|"no: only VEX"| some["Delete the reports of images<br/>with a homelab-vexhub statement"]
        some --> record
        delete --> kind{"manual run?"}
        kind -->|no| record["Store the timestamp in<br/>ConfigMap vex-cache-state"]
        kind -->|yes| done
    end

    artifact -.->|"image volume"| read
    flux -.->|"hash of the live data"| guard
    delete --> operator["trivy-operator scans the<br/>deleted workloads again"]
    some --> operator
    operator --> reports["New VulnerabilityReports,<br/>sent to Dependency-Track by sbom-hook"]
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
