# Storage (OpenEBS LVM and JuiceFS)

Two tiers: node-local volumes for almost everything (OpenEBS LVM, ReadWriteOnce), and one shared ReadWriteMany filesystem for the runner caches (JuiceFS, built on the first tier).

```mermaid
flowchart TB
    subgraph talos["Talos, per node (patches/14-17-lvm-*.yaml)"]
        fast["vg-fast<br/>free NVMe regions<br/>all 4 nodes"]
        bulk["vg-bulk<br/>SATA SSD or 4 TB USB disk<br/>3 nodes, not talos-tba-msi"]
    end
    fast --> sf["StorageClass lvm-fast (default)<br/>xfs, RWO, node-local"]
    bulk --> sb["StorageClass lvm-bulk<br/>xfs, RWO, node-local"]
    sf --> apps["Databases, Prometheus, zot, runner scratch ..."]
    sb --> apps
    subgraph jfs["juicefs-system"]
        meta["juicefs-meta<br/>CNPG x3, 1 sync standby"]
        garage["Garage x3<br/>replication_factor 3"]
    end
    sf --> meta
    sb --> garage
    meta -->|"mTLS, no password"| fs["JuiceFS, RWX<br/>StorageClass juicefs<br/>mount pod per node, FUSE"]
    garage -->|"S3 key"| fs
    fs --> runners["Runner caches:<br/>dnf, cross-run"]
```

## OpenEBS LVM (`k8s/infra/openebs-system/`)

- The volume group is the tier: `vg-fast` is NVMe, `vg-bulk` slower disks. Talos builds them from free disk regions (`patches/14-lvm-2jc.yaml` to `17-lvm-11a.yaml`). `talos-tba-msi` has no `vg-bulk`.
- A volume lives on one node and has no redundancy and no thin provisioning. `WaitForFirstConsumer` lets the pod's node pick where it is created, and a pod cannot move to another node without its data. Check free space per group with `lvm_vg_free_size_bytes`; `openebs-system/prometheusrule.yaml` alerts below 20% (warning) and 10% (critical).
- Volumes expand (`allowVolumeExpansion`), never shrink.

## JuiceFS (`k8s/apps/juicefs-system/`)

- It gives the ARC runners caches that every runner shares, whichever node it lands on. Image storage stays on local volumes: overlay on FUSE is a bad idea.
- The ARC runners share two caches on it, `dnf-cache-jfs` and `cross-run-cache-jfs` (`k8s/apps/arc-runner/pvc.yaml`); a root init container owns the volume roots. Image storage (`/var/lib/containers`) is a per-runner volume on `lvm-fast`: two runners cannot share it, so no runner depends on one node and any of them can start anywhere, cold.
- Use it with `storageClassName: juicefs` and `ReadWriteMany`: each PVC is a subdirectory of one filesystem. The CSI driver runs in `juicefs-system` (privileged, with FUSE mount pods) and every image is pinned by digest, the mount image too (the driver's default is the moving `ce-nightly`).
- Metadata (files, directories) is in PostgreSQL, data blocks are in Garage. PostgreSQL takes a client certificate (mTLS), the role has no password. Garage cannot: S3 requests are signed with a key, generated in `secret-store`. Both run three copies on different nodes: one node lost keeps Garage's quorum (2 of 3) and CNPG promotes a replica; two lost stops Garage. No backups, the data is CI caches.
- Sizes follow the peak use of the shared caches over 3 days (4.0 GiB in about 1.4k files): Garage 10 Gi data and 1 Gi metadata per node, 2 Gi per PostgreSQL instance.
- Each node caches the blocks it reads in `/var/jfsCache`, capped at 5 Gi (the default is 100 GiB and 90% of the disk), so it shows up in the cockpit's `/var` row. The cache is safe to lose; the write cache stays off.
- Monitoring: the pods carry `prometheus-scrape: "true"`; `prometheusrule.yaml` alerts on a missing Garage node, lost quorum, a missing PostgreSQL instance and replication lag. `PersistentVolumeAlmostFull` covers the volumes.

### Growing a JuiceFS volume

Everything is a change in Git, nothing is run by hand.

- **PostgreSQL:** raise `storage.size` in `postgres-cluster.yaml`. The operator resizes every PVC, online on OpenEBS LVM.
- **Garage:** raise the three `data-garage-<n>` sizes in `garage/pvc.yaml` and `clusterConfig.layout.capacity` in `garage/helm-release.yaml`, in one PR. Flux expands the PVCs online and the configure hook assigns the new capacity. Each node holds a full copy, so the usable space is that of the smallest one.
- Never change `persistence.*.size` in the HelmRelease. Garage is a StatefulSet and its `volumeClaimTemplates` are immutable (Kubernetes v1.37), which a Helm retry does not fix (`docs/helmrelease-conventions.md`). That is why the claims are in `pvc.yaml`: the StatefulSet creates a claim only if it is missing and never resizes it, so a claim from Git with the template's name is used as is.
- Do not run `garage layout apply` by hand at the same time: two applies of the same `--version` leave the cluster inconsistent.

## Runners

Sized from the peaks of the last 3 days; volumes are per runner and `lvm-fast` unless noted.

| Scale set | Runners (min to max) | Volumes per runner |
|---|---|---|
| `arc-ubuntu` | 1 to 3 | `work` 16, `docker-lib` 8, `tmp-memory` 12, rootful storage 32, rootless storage 28, `var/tmp` 24 Gi |
| `arc-ubuntu-podman` | 0 to 3 | `work` 16, `tmp` 16, `var-tmp` 24, rootful storage 32, rootless storage 28 Gi |
| `arc-e2e-talos-gitops` | 0 to 3 | `work` 2, `docker-lib` 12 Gi |
| `arc-iso-bootc` | 0 to 1 | `bootc-iso-cache` 80 Gi on `lvm-bulk` (one runner: the cache is ReadWriteOnce) |
| `arc-files-bootc` | 0 to 1 | a 40 Gi emptyDir |
| Renovate (`RenovateJob`) | 3 in parallel for 6 repositories | scratch 2 Gi, containerbase 3 Gi |

The rootful storage stays at 32 Gi: the `homeserver-gui` build fails unless 20 GB are free at its start.

The `homeserver-gui` build keeps a layer cache in zot (`buildcache/homeserver-gui`, `homeserver-bootc`'s build workflow): every self-hosted runner reads it, only `main` writes it, and a weekly `CACHE_BUST` build argument expires the package layers so updates are never frozen. zot keeps a cache tag for 72 hours after its last push or pull (`buildcache/**` retention in `zot.json`). That cache, not a runner's local volume, is what makes a new runner start warm.

## Which to use

Default to `lvm-fast`; `lvm-bulk` for large, cold data. Use JuiceFS only where several pods on different nodes must write the same files, and not for databases or container image storage.
