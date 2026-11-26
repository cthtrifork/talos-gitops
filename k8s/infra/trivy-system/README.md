# trivy-system

The cluster-wide scanner (it reads every workload and starts scan jobs). Dependency-Track and `sbom-hook` are in
[`dependency-track-system`](../dependency-track-system/README.md).

- `trivy-operator/`: vulnerability scanning of running workloads, in client/server mode with one shared
  `trivy-service`. The trivy server pulls its vulnerability and Java databases (and the policy bundle) from the in-cluster
  zot registry (`ghcr-cache/aquasecurity/trivy-db` etc.), which syncs them on demand from `ghcr.io`. Scanned images are
  also pulled through zot via `trivy.registry.mirror`. Every report is POSTed to the `sbom-hook` in `dependency-track-system`, which uploads
  the SBOMs to Dependency-Track; Dependency-Track queries `trivy-service` (4954) for its Trivy analyzer.

## VEX hub, ignore file and ignore policy

Trivy filters its findings with three inputs, all generated into ConfigMaps by the `configMapGenerator` in
`trivy-operator/kustomization.yaml` (fixed names, no hash suffix) from files you edit in Git, and mounted into the
trivy server and the scan jobs:

- `trivy-operator/vex/repository.yaml` (`vex-repository-config`): the VEX repositories Trivy loads, the Trivy VEX hub
  (`default`) and our `vex/` directory (`homelab-vexhub`). The data is in the `vex-cache` image (`images/vex-cache`, built
  by `.github/workflows/images.yaml` from the hub and `vex/`), which the scan jobs mount read-only at
  `<cache-dir>/vex`. `skip-vex-repo-update` keeps Trivy from downloading anything at scan time, so the URLs in the file
  are not fetched. The image is rebuilt when `vex/` changes on `main` and when the workflow is run by hand; the Trivy VEX hub
  part only changes when it runs. VEX statements mark CVEs as not exploitable in a product.
- `trivy-operator/ignore/trivyignore.yaml` (`trivy-ignorefile`): CVEs that do not apply (no expiry) and accepted risk (with an expiry).
- `trivy-operator/ignore/ignore-policy.rego` (`trivy-ignorepolicy`): a Rego policy, `ignore` is false by default. Rules that rest on the cluster setup ignore only LOW and MEDIUM.

They are wired through the `configFile` in `trivy-operator/helm-release.yaml` (`vex`, `ignorefile`, `ignore-policy`).
A change takes effect for the next scan job; reports are regenerated after `scannerReportTTL`.

## Zot CA trust

zot's certificate comes from `certificate-cluster-issuer`. trust-manager's `portableinfo-internal-ca-bundle` Bundle
(`k8s/infra/post/trust-manager`) puts the root CA in a ConfigMap of that name in every namespace, and the Kyverno policy
`inject-trust-bundle` mounts it as `/etc/ssl/certs/ca-certificates.crt` in the trivy server, the scan jobs and the operator, so no
`dbRepositoryInsecure` is needed (`docs/security.md`, "Trust bundle injection"). They only talk to zot and each other, so
the internal-only bundle (the default) is enough, so they carry no annotation.
Reloader restarts the trivy server and the operator when the bundle changes (they read it at start); a scan job reads it when it starts.

## Network policies

`networkpolicy.yaml` denies all traffic in both directions for the namespace and then allows, per workload, what Hubble showed
it needs (one policy each for the trivy operator, the trivy server and the scan jobs). The scan jobs may reach only the trivy server
(4954) and zot (5000), no internet; clients reach `trivy-service` (4954): the operator, the scan jobs, zot and the
Dependency-Track api-server in `dependency-track-system`. The operator reaches `sbom-hook` in `dependency-track-system` (4195). Peers in other
namespaces carry their `k8s:io.kubernetes.pod.namespace` label in the rules on both sides (here, `dependency-track-system` and `registry-system`).
