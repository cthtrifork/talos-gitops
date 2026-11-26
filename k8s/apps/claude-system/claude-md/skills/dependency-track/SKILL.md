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
- The Trivy report decides what to assess (`kubectl get vulnerabilityreport -n <ns> <name> -o json`, `.report.vulnerabilities`); it is already filtered (ignore policy, `trivyignore.yaml`, vendor `not_affected`/`will_not_fix`, VEX). DT holds more findings and is the metadata and the interface to record assessments: match on `(vulnId, component name)` and take the component and vulnerability uuids from the DT finding. DT findings missing from Trivy are not assessed.
- Triage each reported finding: it applies (stays open) or not for this image only, and a record needs a provable reason. Typical: a server-side CVE (krb5 KDC/kadmind, Ceph RGW/MON) where DT's component list shows only the client library (no `krb5-kdc`, `krb5-admin-server`, `radosgw`): `NOT_AFFECTED` with `CODE_NOT_PRESENT` and the reason in `analysisDetails`. Never record one only because the risk is low or the cluster mitigates it, and never from title guesses on ambiguous CVEs.
- Old versions stay in DT until the retire job removes them: take the live tag from the running pods (`kubectl get pods -A`). A project can also lag (no SBOM yet for the live tag): say so.
- DT severity is NVD's. For distro packages (deb, apk) Debian and Alpine rate many CVEs lower and have no fix: compare with Trivy (`vulnerabilityreports`: `severity`, `fixedVersion`).
- Conventions, in this order:
  1. A CVE that is not applicable to any image (wrong product, other OS, feature never used) goes in `k8s/infra/trivy-system/trivy-operator/ignore/trivyignore.yaml` (PR) and is not also assessed here.
  2. A finding that is not applicable to this image only (the component is present but the vulnerable code is not used or reachable) is assessed here as `NOT_AFFECTED` (with `analysisJustification`) or `FALSE_POSITIVE`, even when a bump would fix it. It reaches the VEX export PR.
  3. A finding that applies, whether or not a fix exists, is not assessed: it stays open (a fix is a bump).
- DT has no delete for an analysis: withdraw one with `analysisState` and `analysisResponse` `NOT_SET`. Reading one: `GET /api/v1/analysis?project=&component=&vulnerability=`.
