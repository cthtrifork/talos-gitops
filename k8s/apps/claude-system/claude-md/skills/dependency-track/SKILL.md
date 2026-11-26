---
name: dependency-track
description: Query and assess vulnerability findings in Dependency-Track with the pod's read/triage key. Use when asked about CVEs, critical findings, or to assess or triage a vulnerability.
---

# Dependency-Track: query and assess

`$DT_URL` and `$DT_API_KEY` are already in the pod (PR #1021, team `claude-triage`). Never print or copy the key; pass it as
`-H "X-Api-Key: $DT_API_KEY"`. Check with `[ -n "$DT_API_KEY" ] && echo set`. Unset: the config CronJob has not made the key yet or the pod needs a restart; ask.

- Permissions: view portfolio and vulnerabilities, read/create/update analysis. No BOM upload, no admin.
- Projects are workload containers (name `namespace/repository`, version = image tag; a new tag is cloned from the previous version with its audit history): `curl -s -H "$H" "$DT_URL/api/v1/project?pageSize=100&pageNumber=1"`. Lists and findings return 100 rows per page (`X-Total-Count` has the total): loop over `pageNumber`, `limit` is ignored. Only some images are tracked, so a CVE in Trivy can be absent here: say so.
- A CVE: `GET /api/v1/vulnerability/source/NVD/vuln/<id>` (severity, CVSS, EPSS) and `.../projects` for the affected projects.
- Findings of a project: `GET /api/v1/finding/project/<uuid>?pageSize=100&pageNumber=N` (project `metrics.critical` matches the findings once paged). `searchText` on `/api/v1/finding` does not filter by CVE; do not trust it.
- Record an assessment: `PUT /api/v1/analysis` with `project`, `component`, `vulnerability` uuids, `analysisState`, `analysisJustification`, `analysisDetails`, `suppressed`.
  Only after the owner agrees. `NOT_AFFECTED`, `FALSE_POSITIVE` and `RESOLVED` end up in the daily VEX export PR.
- Assess from the data: DT severity and EPSS vs Trivy's, whether the vulnerable component (e.g. `sshd` vs a client-only package) is in the image, and whether a fix exists. Say what you did not verify.
- Trivy in-cluster: `kubectl get vulnerabilityreports -A` (summary `criticalCount`; the same CVE repeats per package).
- The Trivy report is already filtered (ignore policy, `trivyignore.yaml`, vendor `not_affected`/`will_not_fix`, VEX), DT is not: a DT project lists far more than its report. Diff them on `(vulnId, component name)`; DT findings missing from Trivy are not open findings, but the report does not say why one was dropped.
- Only write an analysis when the reason is provable (vendor or VEX `not_affected`, fixed version already installed, component absent). Never mark one `NOT_AFFECTED` just because Trivy hides it: policy rules that rest on risk (`linux-libc-dev`, minor or cluster-mitigated findings in `ignore-policy.rego`) are not "not affected" and would reach the VEX export PR as such. Say what you could not prove instead.
- Old versions stay in DT until the retire job removes them: take the live tag from the running pods (`kubectl get pods -A`). A project can also lag (no SBOM yet for the live tag): say so.
- DT severity is NVD's. For distro packages (deb, apk) Debian and Alpine rate many CVEs lower and have no fix: compare with Trivy (`vulnerabilityreports`: `severity`, `fixedVersion`).
- Conventions, in this order:
  1. A CVE that is not applicable to any image (wrong product, other OS, feature never used) goes in `k8s/infra/trivy-system/trivy-operator/ignore/trivyignore.yaml` (PR) and is not also assessed here.
  2. A finding that is not applicable to this image only (the component is present but the vulnerable code is not used or reachable) is assessed here as `NOT_AFFECTED` (with `analysisJustification`) or `FALSE_POSITIVE`, even when a bump would fix it. It reaches the VEX export PR.
  3. A finding that applies, whether or not a fix exists, is not assessed: it stays open (a fix is a bump).
- DT has no delete for an analysis: withdraw one with `analysisState` and `analysisResponse` `NOT_SET`. Reading one: `GET /api/v1/analysis?project=&component=&vulnerability=`.
