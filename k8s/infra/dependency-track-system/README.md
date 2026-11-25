# dependency-track-system

- `dependency-track/`: Dependency-Track 5 with a single-instance CNPG PostgreSQL (`dependency-track-db`, `k8s/infra/post-workloads/dependency-track-system/`).
- `sbom-hook/`: receives the trivy operator's webhook in `trivy-system` and uploads every SBOM to Dependency-Track, which queries `trivy-service.trivy-system:4954`.
  One project per image in a namespace and one version per tag, see "Projects" below.

## Network policies

`networkpolicy.yaml` denies all traffic in both directions for the namespace and then allows, per workload, what Hubble showed
it needs. Dependency-Track may reach Postgres (5432), `trivy-service` in `trivy-system` (4954) and the vulnerability feeds;
`sbom-hook` takes the webhook of the trivy operator (4195) and, like `dependency-track-config` and `dependency-track-vex-export`,
reaches `dependency-track-api-server` (8080). The VEX exporter also needs HTTPS egress to GitHub.

## Projects: one project per image in a namespace, one version per tag

`sbom-hook` names a project `namespace/repository` (for example `claude-system/cthtrifork/talos-gitops/claude-runner`, from the `SbomReport`)
and its version is the image tag (`v3.8.0`; the digest if there is no tag). A tag that moves to a new digest updates its version in place.

A tag seen for the first time starts as a clone of the newest version of the project (`POST /api/v2/projects/{uuid}/clone` with components, findings,
audit history, policy violations, properties and tags; the clone also becomes the latest version), and the BOM is then uploaded to it. The audit decisions
come along for components that stay the same, and a decision on a component whose version changed is a different finding, which the docs do not say more about
([project versions](https://dependencytrack.github.io/docs/next/guides/user/managing-project-versions/),
[findings](https://dependencytrack.github.io/docs/next/concepts/vulnerability-findings/)). If the clone fails, the upload still creates an empty version.
The registry host is not in the name (the retire job reads it from a table without it), so the same repository on two registries in one namespace shares a project.
Workloads of one namespace that run the same image share the project; with different tags they are different versions.

A version that is no longer running would stay active forever, so `dependency-track/retire-cronjob.yaml` (daily) marks it inactive when no
`SbomReport` has its namespace, repository and tag and it has had no upload for 2 days (it only touches projects tagged `kubernetes`, and retires nothing when the report list is short).
Dependency-Track retention (`maintenance/projects.retention.type=AGE`, `projects.retention.days=30`, set in `config-configmap.yaml`) then deletes inactive versions
after 30 days, with their decisions. A version that returns is activated again by its next upload (`isActive: true`). The key of the job is the team `project-retirer`;
the team `sbom-uploader` also needs `VIEW_PORTFOLIO` and `PORTFOLIO_MANAGEMENT_CREATE` for the clone.
The job fails until the config CronJob has created its key, and there is no dry run.

Earlier layouts (`registry/repo` with digests, `namespace/workload/container` and `namespace/repository` with `current`) are not migrated: they stop receiving uploads and the same job retires them.

## Assessing findings from the claude-rc pod

The `claude-triage` team (view portfolio and vulnerabilities, read/create/update analysis; no BOM upload, no admin) has its
key in the Secret `dependency-track-claude-api-key` of `claude-system`, created once by `config-cronjob.yaml` and exposed to
the pod as `DT_API_KEY` (with `DT_URL`). A session records its assessment with `PUT /api/v1/analysis` (state, justification,
response, comment); the daily VEX export then turns *not affected* decisions into a pull request. The key is never printed.

## The Dependency-Track KEK

The chart does not generate the key encryption key. External Secrets generates it once in the cluster store
(`k8s/infra/secret-store/`, never overwritten) and `dependency-track/external-secret-kek.yaml` copies the Secret
`dependency-track-kek` (key `kek`, 32 random characters, base64) here. The key is therefore
not in Git: if the Secret is lost, everything Dependency-Track stored encrypted in its database becomes unreadable. Back it
up (`kubectl -n dependency-track-system get secret dependency-track-kek`, needs Secret read access) if that matters.
Until the ExternalSecret has synced, the api-server pods wait in `CreateContainerConfigError` and then start on their own.

## Access

The UI is at `https://dtrack.portableinfo.cloud`: Cloudflare (with an Access policy) -> tunnel -> Traefik
(`post-workloads/dependency-track-system/dependency-track-ingressroute.yaml`: `/api` to the api-server, the rest to the frontend). The browser
calls the API on the same origin, so there is no CORS and no second hostname. In the tunnel's **Public hostname** tab add
`dtrack.portableinfo.cloud` with service `HTTP` `localhost:8000`, and put a Cloudflare Access policy on it in Zero Trust.

API clients on the LAN use `http://192.168.1.242:8080` through MetalLB (`dependency-track/service-lb.yaml`, plain HTTP,
not routed through Traefik). Check the address is free in the pool (`192.168.1.221-254`) before merging.

## KEV: turning bare CVEs into "is this exploited?"

Trivy itself has no KEV data, and trivy-operator reports (and its metrics) only carry severity/CVSS. KEV enrichment
comes from Dependency-Track 5, which has two relevant pieces. Both are stored in its database, so Helm values cannot set
them; `dependency-track/config-cronjob.yaml` (a CronJob every hour, and Reloader runs it when its ConfigMap changes) applies them through the REST API:

1. **KEV data sources**: CISA KEV and ENISA KEV are enabled. Dependency-Track then flags findings whose CVE (or alias) is
   known exploited, with the required action and a known-ransomware flag. It needs egress to `www.cisa.gov` and
   `raw.githubusercontent.com`. VulnCheck KEV needs a token and is not configured.
2. **Trivy vulnerability analyzer**: enabled with API URL `http://trivy-service.trivy-system.svc.cluster.local:4954`.
   It reuses the trivy server that trivy-operator runs, so the zot-mirrored database is used and the analyzer needs no
   internet access. The server has no token set. It scans libraries and OS packages (`scanOs`), so Debian and Alpine findings show up too.

The settings live in the ConfigMap `dependency-track-config` (`extensions.json`: extension point, extension name, config)
and are merged over the current settings; add entries there for other analyzers or data sources. Notifications, policies and
the NVD/GitHub/OSV sources are not managed (UI only, defaults kept).

The same Job bootstraps access, from desired state kept as data in the ConfigMap `dependency-track-config`
(`teams.json`, `properties.json`, `extensions.json`). The script is a generic loop over those files, so a change is an edit
of the JSON. `properties.json` lists config properties as strings (group, name, value); only declared ones are managed and
an unknown one fails the Job. The telemetry default is set with `DT_TELEMETRY_SUBMISSION_DEFAULT_ENABLED` in the HelmRelease;
it only seeds a fresh install. Dependency-Track has no declarative provisioning of the admin, teams or API keys
([upstream issue 6193](https://github.com/DependencyTrack/dependency-track/issues/6193)), hence the Job.

External Secrets generates the admin password once (`k8s/infra/secret-store/`) and `external-secret-admin.yaml` copies it into
`dependency-track-admin`, so it exists before the Job first runs. On the first run `config-cronjob.yaml` changes the built-in
`admin/admin` to it, creates the teams, stores their API keys and applies the settings above. To use your own password, change
the key `password` in the Secret `dependency-track-admin` of the namespace `secret-store`. An existing installation just logs in
with the Secret; the password is never reset. If the password was already changed by hand, the Job fails with a clear message:
put the current admin password in the `secret-store` Secret.

| Secret | Keys | Created by | Used by |
|---|---|---|---|
| `dependency-track-kek` | `kek` | `external-secret-kek.yaml` (generated in `secret-store`) | api-server |
| `dependency-track-admin` | `username`, `password` | `external-secret-admin.yaml` (generated in `secret-store`) | `config-cronjob.yaml` |
| `dependency-track-api-key` | `api-key` (team `sbom-uploader`) | `config-cronjob.yaml` | `sbom-hook` |
| `dependency-track-vex-api-key` | `api-key` (team `vex-exporter`) | `config-cronjob.yaml` | `vex-export-cronjob.yaml` |
| `dependency-track-vex-github` | `token` | `external-secret-vex-github.yaml` (minted from `dependency-track-vex-github-app`) | `vex-export-cronjob.yaml` |

Teams keep their permissions (`sbom-uploader`: `BOM_UPLOAD`, `PROJECT_CREATION_UPLOAD`; `vex-exporter`: `VIEW_PORTFOLIO`,
`VULNERABILITY_ANALYSIS_READ`); permissions are only added. A key is created only when its Secret does not exist, and is never
printed or overwritten. While the key Secret is missing, `sbom-hook` logs `DRY RUN: would upload ...` and the VEX export
prints that it has nothing to export.

**Key rotation / recovery.** Delete the key Secret; the next run (within an hour, or run it from the Elevate page) creates a new key and Secret. The old
key stays valid: revoke it in the UI (Administration, Access Management, Teams, the team's API keys). Reloader restarts the
consumers that read the key at start (`sbom-hook`, the claude-rc pod); the VEX export reads it
on each run. If the Job created a key but failed to store the Secret, the next run creates another; revoke the unused one.
A lost admin Secret is recovered by seeding it with the current admin password.

## Exporting Dependency-Track decisions to the VEX repository (suspended)

Suspended (`suspend: true`): it only exports projects versioned by digest, and the versions are now image tags, so it would export nothing.
To bring it back, version the projects by digest again or change the exporter.

`dependency-track/vex-export-cronjob.yaml` is a daily CronJob that turns the analysis decisions made in Dependency-Track (state
*not affected*, *false positive* or *resolved* on a finding) into OpenVEX documents in `vex/pkg/oci/<registry>/<repository>/`
of this repository, regenerates `vex/index.json` and opens a pull request from the branch `dependency-track/vex-export`.
Merge it and the `vex-cache` image is rebuilt from `vex/`; the next scan job hides those findings. The exporter only changes
files under `vex/`, never pushes to `main`, and rebuilds all of `vex/pkg/oci/` from the current Dependency-Track decisions
on every run. Any existing OCI documents not produced from those decisions are removed, regardless of author; Dependency-Track
is the only path for adding OCI assessments. Findings on components without a PURL are skipped.

It pushes as a GitHub App, so no long-lived token is stored: each run signs a JWT with the App's private key and trades it for a
one-hour installation token that the request narrows to this repository with Contents and Pull requests read/write.
Without the Secret the Job is a dry run that prints the documents it would write.

1. Create a separate App (not the one of `claude-system`, which also has Workflows): GitHub, Settings > Developer settings >
   GitHub Apps > New. Repository permissions **Contents** and **Pull requests**: read and write; **Metadata**: read; everything
   else off. Untick "Webhook active". Never make it a bypass actor in a ruleset.
2. Generate a private key (`.pem`), install the App only on `talos-gitops`, and note the **App ID** and the **installation ID**
   (the number at the end of the installation's URL, `https://github.com/settings/installations/<id>`).
3. The Secret `dependency-track-vex-github-app` in `dependency-track-system`, with the keys `app-id`, `installation-id` and
   `private-key.pem`, is the SOPS-encrypted `dependency-track/vex-github-app.enc.yaml` (same procedure as `claude-github-app`,
   "Secrets (SOPS)" in the root `readme.md`). External Secrets
   turns it into the one-hour token `dependency-track-vex-github` (`kubectl -n dependency-track-system get externalsecret dependency-track-vex-github`).
4. Run it once instead of waiting for the schedule:
   `kubectl -n dependency-track-system create job --from=cronjob/dependency-track-vex-export vex-first` and read its logs.

The API key comes from `config-cronjob.yaml` (team `vex-exporter`). Trivy identifies a scanned image by the PURL
`pkg:oci/<name>@<digest>?repository_url=<registry>/<repository>` and matches a statement only if the version is the same, so
`sbom-hook/` versions each Dependency-Track project by the image digest, not the tag. The export skips projects whose
version is not a digest. Decisions made on a project versioned by tag stay in Dependency-Track but are not exported;
repeat them on the digest project, or delete the old project. A moved tag creates a new project per digest, so old ones pile up until retention removes them.

Findings come from the projects/SBOMs uploaded to Dependency-Track. `sbom-hook/` (Redpanda Connect) receives every
`SbomReport` that trivy-operator produces or regenerates through its webhook (`operator.webhookBroadcastURL`) and uploads
it, one project per image; reports are regenerated after `scannerReportTTL`, so nothing needs a second upload path. It
uses the API key created by `config-cronjob.yaml`.
