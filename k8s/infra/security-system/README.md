# security-system

- `trivy-operator/`: vulnerability scanning of running workloads, in client/server mode with one shared
  `trivy-service`. The trivy server pulls its vulnerability and Java databases (and the policy bundle) from the in-cluster
  zot registry (`ghcr-cache/aquasecurity/trivy-db` etc.), which syncs them on demand from `ghcr.io`. Scanned images are
  also pulled through zot via `trivy.registry.mirror`.
- `dependency-track/`: Dependency-Track 5 with a single-instance CNPG PostgreSQL (`dependency-track-db`).

## VEX hub, ignore file and ignore policy

Trivy filters its findings with three inputs, all generated into ConfigMaps by the `configMapGenerator` in
`trivy-operator/kustomization.yaml` (fixed names, no hash suffix) from files you edit in Git, and mounted into the
trivy server and the scan jobs:

- `trivy-operator/vex/repository.yaml` (`vex-repository-config`): the VEX repositories Trivy loads, the Trivy VEX hub
  (`default`) and our `vex/` directory (`homelab-vexhub`). The data is in the `vex-cache` image (`images/vex-cache`, built
  by `.github/workflows/build-vex-cache.yaml` from the hub and `vex/`), which the scan jobs mount read-only at
  `<cache-dir>/vex`. `skip-vex-repo-update` keeps Trivy from downloading anything at scan time, so the URLs in the file
  are not fetched. The image is rebuilt when `vex/` changes on `main` and when the workflow is run by hand; the Trivy VEX hub
  part only changes when it runs. VEX statements mark CVEs as not exploitable in a product.
- `trivy-operator/ignore/trivyignore.yaml` (`trivy-ignorefile`): accepted findings, with an expiry.
- `trivy-operator/ignore/ignore-policy.rego` (`trivy-ignorepolicy`): a Rego policy, `ignore` is false by default.

They are wired through the `configFile` in `trivy-operator/helm-release.yaml` (`vex`, `ignorefile`, `ignore-policy`).
A change takes effect for the next scan job; reports are regenerated after `scannerReportTTL`.

## Zot CA trust

zot's certificate comes from `certificate-cluster-issuer`. trust-manager's `portableinfo-ca-bundle` Bundle
(`k8s/infra/post/trust-manager`) puts the root CA in a ConfigMap of that name (key `ca-bundle.crt`) in every namespace; the
trivy server, the scan jobs and the operator mount it as `/etc/ssl/certs/zot-ca.crt` (Go reads extra files there), so no
`dbRepositoryInsecure` is needed. Reloader restarts the trivy server and the operator when the bundle changes (they read
it at start); a scan job reads it when it starts.

## Network policies

`networkpolicy.yaml` denies all traffic in both directions for the namespace and then allows, per workload, what Hubble showed
it needs (one policy each for Dependency-Track, `sbom-hook`, the trivy operator, the trivy server, the scan jobs and
the Dependency-Track jobs). The scan jobs may reach the trivy server (4954), zot (5000) and the internet;
clients reach `trivy-service` (4954).

## The Dependency-Track KEK

The chart does not generate the key encryption key. External Secrets generates it once in the cluster store
(`k8s/infra/secret-store/`, never overwritten) and `dependency-track/external-secret-kek.yaml` copies the Secret
`dependency-track-kek` (key `kek`, 32 random characters, base64) here. The key is therefore
not in Git: if the Secret is lost, everything Dependency-Track stored encrypted in its database becomes unreadable. Back it
up (`kubectl -n security-system get secret dependency-track-kek`, needs Secret read access) if that matters.
Until the ExternalSecret has synced, the api-server pods wait in `CreateContainerConfigError` and then start on their own.

## Access

The UI is at `https://dtrack.portableinfo.cloud`: Cloudflare (with an Access policy) -> tunnel -> Traefik
(`post/security-system/dependency-track-ingressroute.yaml`: `/api` to the api-server, the rest to the frontend). The browser
calls the API on the same origin, so there is no CORS and no second hostname. In the tunnel's **Public hostname** tab add
`dtrack.portableinfo.cloud` with service `HTTP` `localhost:8000`, and put a Cloudflare Access policy on it in Zero Trust.

API clients on the LAN use `http://192.168.1.242:8080` through MetalLB (`dependency-track/service-lb.yaml`, plain HTTP,
not routed through Traefik). Check the address is free in the pool (`192.168.1.221-254`) before merging.

## KEV: turning bare CVEs into "is this exploited?"

Trivy itself has no KEV data, and trivy-operator reports (and its metrics) only carry severity/CVSS. KEV enrichment
comes from Dependency-Track 5, which has two relevant pieces. Both are stored in its database, so Helm values cannot set
them; `dependency-track/config-job.yaml` (a CronJob every 20 minutes) applies them through the REST API:

1. **KEV data sources**: CISA KEV and ENISA KEV are enabled. Dependency-Track then flags findings whose CVE (or alias) is
   known exploited, with the required action and a known-ransomware flag. It needs egress to `www.cisa.gov` and
   `raw.githubusercontent.com`. VulnCheck KEV needs a token and is not configured.
2. **Trivy vulnerability analyzer**: enabled with API URL `http://trivy-service.security-system.svc.cluster.local:4954`.
   It reuses the trivy server that trivy-operator runs, so the zot-mirrored database is used and the analyzer needs no
   internet access. The server has no token set.

The settings live in the ConfigMap `dependency-track-config` (`extensions.json`: extension point, extension name, config)
and are merged over the current settings; add entries there for other analyzers or data sources. Notifications, policies and
the NVD/GitHub/OSV sources are not managed (UI only, defaults kept).

The same Job bootstraps access, from desired state kept as data in the ConfigMap `dependency-track-config`
(`teams.json`, `properties.json`, `extensions.json`). The script is a generic loop over those files, so a change is an edit
of the JSON. `properties.json` lists config properties as strings (group, name, value); only declared ones are managed and
an unknown one fails the Job. The telemetry default is set with `DT_TELEMETRY_SUBMISSION_DEFAULT_ENABLED` in the HelmRelease;
it only seeds a fresh install. Dependency-Track has no declarative provisioning of the admin, teams or API keys
([upstream issue 6193](https://github.com/DependencyTrack/dependency-track/issues/6193)), hence the Job.

On the first run `config-job.yaml` generates a random admin password and stores it in `dependency-track-admin`
**before** it changes the built-in `admin/admin` (so a crash in between loses nothing), creates the teams, stores their API
keys and applies the settings above. To use your own password, create the Secret before the first run:
`kubectl -n security-system create secret generic dependency-track-admin --from-literal=username=admin --from-literal=password=<password>`.
An existing installation just logs in with the Secret; the password is never reset. If the Secret is missing but the
password was already changed by hand, the Job deletes the password it just generated and fails with a clear message: create
the Secret with the current admin password.

| Secret | Keys | Created by | Used by |
|---|---|---|---|
| `dependency-track-kek` | `kek` | `external-secret-kek.yaml` (generated in `secret-store`) | api-server |
| `dependency-track-admin` | `username`, `password` | `config-job.yaml` (or by hand) | `config-job.yaml` |
| `dependency-track-api-key` | `api-key` (team `sbom-uploader`) | `config-job.yaml` | `sbom-hook` |
| `dependency-track-vex-api-key` | `api-key` (team `vex-exporter`) | `config-job.yaml` | `vex-export.yaml` |
| `dependency-track-vex-github` | `token` | by hand | `vex-export.yaml` |

Teams keep their permissions (`sbom-uploader`: `BOM_UPLOAD`, `PROJECT_CREATION_UPLOAD`; `vex-exporter`: `VIEW_PORTFOLIO`,
`VULNERABILITY_ANALYSIS_READ`); permissions are only added. A key is created only when its Secret does not exist, and is never
printed or overwritten. While the key Secret is missing, `sbom-hook` logs `DRY RUN: would upload ...` and the VEX export
prints that it has nothing to export.

**Key rotation / recovery.** Delete the key Secret; the next run (within 20 minutes) creates a new key and Secret. The old
key stays valid: revoke it in the UI (Administration, Access Management, Teams, the team's API keys). Then restart the
consumer, which reads the key at start: `kubectl -n security-system rollout restart deploy/sbom-hook` (the VEX export reads it
on each run). If the Job created a key but failed to store the Secret, the next run creates another; revoke the unused one.
A lost admin Secret is recovered by seeding it with the current admin password.

## Exporting Dependency-Track decisions to the VEX repository

`dependency-track/vex-export.yaml` is a daily CronJob that turns the analysis decisions made in Dependency-Track (state
*not affected*, *false positive* or *resolved* on a finding) into OpenVEX documents in `vex/pkg/oci/<registry>/<repository>/`
of this repository, regenerates `vex/index.json` and opens a pull request from the branch `dependency-track/vex-export`.
Merge it and the `vex-cache` image is rebuilt from `vex/`; the next scan job hides those findings. It only changes files under `vex/`, never pushes to `main`,
and only deletes documents whose author is `Dependency-Track`. Findings on components without a PURL are skipped.

It needs the Secret `dependency-track-vex-github` (key `token`), seeded by hand: a fine-grained personal access token (or
GitHub App installation token) for this repository only, with Contents and Pull requests read/write.
`kubectl -n security-system create secret generic dependency-track-vex-github --from-literal=token=<token>`.
The API key comes from `config-job.yaml` (team `vex-exporter`). Trivy identifies a scanned image by the PURL
`pkg:oci/<name>@<digest>?repository_url=<registry>/<repository>` and matches a statement only if the version is the same, so
`sbom-hook/` versions each Dependency-Track project by the image digest, not the tag. The export skips projects whose
version is not a digest. Decisions made on projects created before
that change (versioned by tag) stay in Dependency-Track but are not exported; repeat them on the digest project, or
delete the old projects. A moved tag creates a new project per digest, so old ones pile up until retention removes them.

Findings come from the projects/SBOMs uploaded to Dependency-Track. `sbom-hook/` (Redpanda Connect) receives every
`SbomReport` that trivy-operator produces or regenerates through its webhook (`operator.webhookBroadcastURL`) and uploads
it, one project per image; reports are regenerated after `scannerReportTTL`, so nothing needs a second upload path. It
uses the API key created by `config-job.yaml`; until the Secret exists its uploads fail with a 401.

The default-deny network policies allow Dependency-Track to Postgres (5432),
trivy-service (4954), and the vulnerability feeds; allow `sbom-hook`, `dependency-track-config` and
`dependency-track-vex-export` to reach `dependency-track-api-server` (8080). The VEX exporter also needs HTTPS egress.
