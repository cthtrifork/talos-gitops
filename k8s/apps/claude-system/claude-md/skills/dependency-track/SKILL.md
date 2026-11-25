---
name: dependency-track
description: Query and assess vulnerability findings in Dependency-Track with the pod's read/triage key. Use when asked about CVEs, critical findings, or to assess or triage a vulnerability.
---

# Dependency-Track: query and assess

`$DT_URL` and `$DT_API_KEY` are already in the pod (PR #1021, team `claude-triage`). Never print or copy the key; pass it as
`-H "X-Api-Key: $DT_API_KEY"`. Check with `[ -n "$DT_API_KEY" ] && echo set`. Unset: the config CronJob has not made the key yet or the pod needs a restart; ask.

- Permissions: view portfolio and vulnerabilities, read/create/update analysis. No BOM upload, no admin.
- Projects are workload containers (name `namespace/repository`, version = image tag; a new tag is cloned from the previous version with its audit history): `curl -s -H "$H" "$DT_URL/api/v1/project?limit=200"`. Only some images are tracked, so a CVE in Trivy can be absent here: say so.
- A CVE: `GET /api/v1/vulnerability/source/NVD/vuln/<id>` (severity, CVSS, EPSS) and `.../projects` for the affected projects.
- Findings of a project: `GET /api/v1/finding/project/<uuid>`. `searchText` on `/api/v1/finding` does not filter by CVE; do not trust it.
- Record an assessment: `PUT /api/v1/analysis` with `project`, `component`, `vulnerability` uuids, `analysisState`, `analysisJustification`, `analysisDetails`, `suppressed`.
  Only after the owner agrees. `NOT_AFFECTED`, `FALSE_POSITIVE` and `RESOLVED` end up in the daily VEX export PR.
- Assess from the data: DT severity and EPSS vs Trivy's, whether the vulnerable component (e.g. `sshd` vs a client-only package) is in the image, and whether a fix exists. Say what you did not verify.
- Trivy in-cluster: `kubectl get vulnerabilityreports -A` (summary `criticalCount`; the same CVE repeats per package).
