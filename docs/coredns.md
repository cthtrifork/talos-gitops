# CoreDNS

CoreDNS runs as the Flux HelmRelease `kube-system/coredns` (`k8s/infra/coredns/`); Renovate bumps the chart and the image. Talos still renders its own CoreDNS (no `KubeCoreDNSConfig` patch): the release reuses the names, labels, selector and ClusterIP (`10.96.0.10`) of those objects, so Helm adopts them in place. A new cluster needs no extra bootstrap step: Talos provides DNS until Flux takes over.

## Talos and Flux

- Talos' boot-time controller applies an object only if it is missing from its inventory and does not exist, so it never reverts what Flux changes, also after a reboot.
- `talosctl upgrade-k8s` re-applies its rendered manifests (server-side apply, field manager `talos`) and can put its CoreDNS image and Corefile back until Flux reconciles (30m, drift detection on). Before each run use `upgrade-k8s --dry-run` and read the CoreDNS diff; afterwards check that `helmrelease/coredns` is Ready and the image is the pinned one.
- Do not disable Talos' CoreDNS without first removing its entries from `kube-system/talos-bootstrap-manifests-inventory` and the `config.k8s.io/owning-inventory` annotation from the six objects: `upgrade-k8s` prunes what Talos no longer renders, which would delete cluster DNS.
- `service.clusterIP` must stay the cluster DNS address Talos hands to kubelets (the 10th address of the service subnet).
