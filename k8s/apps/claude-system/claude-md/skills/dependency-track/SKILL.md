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
- Consider usage first: what this cluster actually uses decides applicability, not the CVE title. Grep the repo (`git grep -i <feature>` in `k8s/`, the app README and values) for the feature behind the package (Kerberos/GSSAPI, Ceph, SSH, DTLS, image decoders, ...). Unused in every image: `trivyignore.yaml` PR with the reason, never a DT record (a server-only title such as KDC or kadmind is the wrong reason when the whole feature is unused). Unused in this image only: `NOT_AFFECTED` with `CODE_NOT_PRESENT` or `CODE_NOT_REACHABLE`. Used, or unclear: leave it open and say so. Never record one only because the risk is low, and never from title guesses or from an exposure claim you did not check (say "not verified" instead).
- Exposure from network policies: when asked to assess, or when the code path is unknown, read the CiliumNetworkPolicies first (`kubectl get ciliumnetworkpolicy -n <ns> -o yaml`) and the pod spec (`hostNetwork`). Default deny, ingress only from kube-apiserver, host or cluster, and egress only to named hosts (no untrusted input reaches the binary): after the owner agrees, record `NOT_AFFECTED` with `PROTECTED_BY_MITIGATING_CONTROL` and say in `analysisDetails` that linkage was not verified. Leave open: LAN or world ingress (`fromCIDR`, `world`), `hostNetwork` pods (Cilium policies do not apply), open internet egress, tools that process input you choose, namespaces whose policy you did not read, and projects whose DT version is not the live tag. Do not answer "cannot assess" when this evidence exists: do it, or list what is missing.
- Old versions stay in DT until the retire job removes them: take the live tag from the running pods (`kubectl get pods -A`). A project can also lag (no SBOM yet for the live tag): say so.
- DT severity is NVD's. For distro packages (deb, apk) Debian and Alpine rate many CVEs lower and have no fix: compare with Trivy (`vulnerabilityreports`: `severity`, `fixedVersion`).
- Conventions, in this order:
  1. A CVE that is not applicable to any image (wrong product, other OS, feature never used) goes in `k8s/infra/trivy-system/trivy-operator/ignore/trivyignore.yaml` (PR) and is not also assessed here.
  2. A finding that is not applicable to this image only (the component is present but the vulnerable code is not used or reachable) is assessed here as `NOT_AFFECTED` (with `analysisJustification`) or `FALSE_POSITIVE`, even when a bump would fix it. It reaches the VEX export PR.
  3. A finding that applies, whether or not a fix exists, is not assessed: it stays open (a fix is a bump).
- DT has no delete for an analysis: withdraw one with `analysisState` and `analysisResponse` `NOT_SET`. Reading one: `GET /api/v1/analysis?project=&component=&vulnerability=`.
