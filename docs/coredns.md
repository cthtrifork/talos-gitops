# CoreDNS

CoreDNS runs as the Flux HelmRelease `kube-system/coredns` (`k8s/infra/coredns/`); Renovate bumps the chart and the image. The release reuses the names, labels, selector and ClusterIP (`10.96.0.10`) of the objects Talos created, so Helm adopts them in place. `patches/23-coredns.yaml` stops Talos from rendering its own.

## Handover (once, by a person)

Talos tracks its CoreDNS objects in the `kube-system/talos-bootstrap-manifests-inventory` ConfigMap. `talosctl upgrade-k8s` prunes what it no longer renders, which would delete cluster DNS.

1. Merge the PR and wait for `helmrelease/coredns` to be Ready; the Deployment rolls to the new image, names, UIDs and the ClusterIP stay.
2. Remove the six CoreDNS keys from the inventory ConfigMap (`kube-system_coredns__ConfigMap`, `..._ServiceAccount`, `kube-system_coredns_apps_Deployment`, `kube-system_kube-dns__Service`, `_system__coredns_rbac.authorization.k8s.io_ClusterRole` and `..._ClusterRoleBinding`) and the `config.k8s.io/owning-inventory` annotation from those objects.
3. Apply `patches/23-coredns.yaml` in Omni.
4. `talosctl upgrade-k8s --dry-run` must show no `Pruned` action and no CoreDNS object. Until step 2 is done, run every `upgrade-k8s` with `--manifests-no-prune`.

## Rebuild

With Talos' CoreDNS off, a new cluster has no DNS until CoreDNS is installed, and Flux needs DNS to fetch Git. The readme's bootstrap installs the chart with `helm install coredns`, from the chart version and values of this directory, after Cilium and before Flux; the HelmRelease has the same name, so Flux adopts that release.

- Apply `patches/23-coredns.yaml` before that step: `helm install` does not take over objects Talos already rendered and fails on them.
- `service.clusterIP` must be the cluster DNS address Talos hands to kubelets (the 10th address of the service subnet); change it with the subnet.
