# trivy-system

Split out of `security-system` so the cluster-wide scanner (it reads every workload and starts scan jobs) and Reloader no longer share a
namespace, network policy set and Flux Kustomization with Dependency-Track and its database. Dependency-Track and `sbom-hook` stay in
[`security-system`](../security-system/README.md); Reloader is in `reloader-system`.

- `trivy-operator/`: vulnerability scanning of running workloads, in client/server mode with one shared
  `trivy-service`. The trivy server pulls its vulnerability and Java databases (and the policy bundle) from the in-cluster
  zot registry (`ghcr-cache/aquasecurity/trivy-db` etc.), which syncs them on demand from `ghcr.io`. Scanned images are
  also pulled through zot via `trivy.registry.mirror`. Every report is POSTed to the `sbom-hook` in `security-system`, which uploads
  the SBOMs to Dependency-Track; Dependency-Track queries `trivy-service` (4954) for its Trivy analyzer.

## VEX hub, ignore file and ignore policy

Trivy filters its findings with three inputs, all generated into ConfigMaps by the `configMapGenerator` in
`trivy-operator/kustomization.yaml` (fixed names, no hash suffix) from files you edit in Git, and mounted into the
trivy server and the scan jobs:

- `trivy-operator/vex/repository.yaml` (`vex-repository-config`): the VEX repositories Trivy loads, the Trivy VEX hub
  (`default`) and our `vex/` directory (`homelab-vexhub`). The data is in the `vex-cache` image (`images/vex-cache`, built
  by `.github/workflows/vex.yaml` from the hub and `vex/`), which the scan jobs mount read-only at
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
it needs (one policy each for the trivy operator, the trivy server and the scan jobs). The scan jobs may reach the trivy server
(4954), zot (5000) and the internet; clients reach `trivy-service` (4954): the operator, the scan jobs, zot and the
Dependency-Track api-server in `security-system`. The operator reaches `sbom-hook` in `security-system` (4195). Peers in other
namespaces carry their `k8s:io.kubernetes.pod.namespace` label in the rules on both sides (here, `security-system` and `registry-system`).
