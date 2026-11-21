# Storage plan

The four nodes exist only for this cluster. The plan uses every disk for PVCs and ephemeral volumes, with **no redundancy**: a lost disk or node loses
its volumes, and data loss and short instability during the move are accepted. No snapshots.

## Layout

Talos builds LVM volume groups from the disks (`LVMVolumeGroupConfig`, Talos 1.14), and the OpenEBS LVM LocalPV CSI driver (`local.csi.openebs.io`,
`k8s/infra/openebs-system`) creates one logical volume per PVC in them. A PVC is a logical volume of exactly its requested size (XFS), expandable
online, on the node where it is used: no network hop, a real size limit (local-path has none), and the scheduler places a pod only on a node whose group
has room (CSI storage capacity tracking). Two tiers, two StorageClasses:

| Tier | Class | Disks | Use |
|---|---|---|---|
| fast | `lvm-fast` (becomes the default) | NVMe | databases, registry, runner and build scratch, caches |
| bulk | `lvm-bulk` | SATA SSD and USB HDD | large, cold or sequential data (fileserver, archives) |

| Node | System disk, EPHEMERAL | `vg-fast` | `vg-bulk` |
|---|---|---|---|
| `talos-11a-esj` | 256 GB NVMe, EPHEMERAL 254 GB | the whole 1 TB data NVMe | the 4 TB USB disk |
| `talos-tba-msi` | 256 GB SATA, EPHEMERAL 254 GB | the whole 1 TB NVMe | none |
| `talos-vt2-qp8` | 512 GB NVMe, EPHEMERAL 150 GB | about 360 GB (the NVMe behind EPHEMERAL) | the 4 TB USB disk |
| `talos-2jc-qux` | 1 TB NVMe, EPHEMERAL 200 GB | about 800 GB (the NVMe behind and between the partitions) | the 256 GB SATA SSD |

About 3.2 TB fast and 8.3 TB bulk, against 1.3 TB of local-path today.

**EPHEMERAL keeps its headroom.** It holds the container images, logs and the kubelet's emptyDirs, and a full one means DiskPressure and evictions. It is
not shrunk: 254 GB on the two nodes with a dedicated system disk, 150 GB on `vt2` (5% used) and 200 GB on `2jc` (8% used), where it shares the NVMe with
`vg-fast`. Rule for any new node: EPHEMERAL at least 150 GB and at least three times its steady use. The large emptyDirs of the CI runners move to generic
ephemeral volumes on `lvm-fast`, which takes that load off EPHEMERAL (on `talos-11a-esj` it is at 70% with 182 GiB of emptyDir limits on it).

## Phases

**0. Pilot on `talos-2jc-qux`** (it holds nothing but a half-imported VM disk that another session is fixing). `patches/14-lvm-2jc.yaml` replaces its two
local-path volumes by `vg-fast` and `vg-bulk`; the OpenEBS LVM LocalPV app and the two classes are in `k8s/infra/openebs-system`. Steps:
1. Merge this PR (Flux deploys the driver and the classes; no volume group exists yet, so nothing uses them).
2. In Omni, apply `patches/14-lvm-2jc.yaml` to `talos-2jc-qux` and reboot it (the first two documents delete the old user volumes so they unmount).
3. Wipe the old partitions with the Job in `k8s/apps/disk-wipe` (nvme0n1p3 `236d4dad-14e1-4fc2-9e07-7c0ed5b75554`, 200000000000 bytes; sda4 `683e163f-8d7f-440c-806d-eeb7dff16d18`, 178120556544 bytes). Talos then creates the raw partitions and the groups.
4. Acceptance: `talosctl -n 192.168.1.173 get pvs,vgs` show `vg-fast` (about 800 GB) and `vg-bulk` (about 255 GB) with no `lvmvalidationerrors`; the node plugin pod is `Running` on all four nodes; a test PVC of each class binds and mounts; a PVC expands online; a runner ephemeral volume works; the alerts below load and the target is up.
5. If the driver does not work on Talos (LVM is new in Talos 1.14, and the driver is not documented for it: kernel modules, `/dev` handling), stop here: the node goes back to local-path by removing the patch.

**1. `talos-tba-msi`, then `talos-vt2-qp8`.** Per node: remove patch 03 for that machine (a machine patch with `$patch: delete`), the same `RawVolumeConfig` and `LVMVolumeGroupConfig` documents for its disks (`vt2` also the USB disk as `vg-bulk`, and its stale `openebs` user volume is removed), reboot, wipe, check as above. Its PVCs are recreated (data loss accepted).

**2. `talos-11a-esj`, last** (it holds the most: `zot`, the runner caches). Remove patches 03, 06 and 09 for it, wipe `nvme0n1` and the USB disk, build both groups. Its PVCs are recreated.

**3. Workloads and clean-up.** Flip every PVC to the class and size of the table below (a `storageClassName` cannot change in place: the PVCs are deleted and recreated, with the Flux Kustomizations `force: true` or by hand), make `lvm-fast` the default class, move the runner emptyDirs to generic ephemeral volumes on `lvm-fast`, then remove the local-path provisioner and the OpenEBS hostpath provisioner and patches 03, 06 and 09.

## PVCs

A volume's size is now a hard limit, but it can be expanded online (`allowVolumeExpansion`), so sizes are generous without being padded. Per-PVC usage was not measured (no disk scans of the nodes); the sizes come from the current requests, the observed node totals (`talos-tba-msi` 22 GB, `talos-vt2-qp8` almost nothing, `talos-11a-esj` 477 GB used of 700 GB with 309 GiB requested) and the role.

| PVC | Now | Target | Why |
|---|---|---|---|
| `arc-runners-system/container-storage-rootful`, `container-rootless-storage` | 32Gi local-path | 64Gi `lvm-fast` | image build storage; local-path let them grow past the request, a volume does not |
| `arc-runners-system/container-shared-storage`, `dnf-cache`, `podman-tmp` | 24Gi, 25Gi, 15Gi | 32Gi `lvm-fast` each | same |
| `arc-runners-system/cross-run-cache` | 5Gi | 10Gi `lvm-fast` | downloaded release binaries shared between builds |
| `arc-runners-system/bootc-iso-cache` | 40Gi | 80Gi `lvm-fast` | installer RPMs and the OS image |
| `claude-system/claude-workspace`, `claude-home` | 10Gi, 5Gi | 50Gi, 10Gi `lvm-fast` | many git clones and worktrees live in the workspace |
| `claude-vm/claude-vm-rootdisk` | about 64 GB | 60Gi `lvm-fast` | keep in step with `config-claude-vm.toml` (CDI adds the filesystem overhead) |
| `fileserver-system/fileserver-data` | 20Gi | 100Gi `lvm-bulk` | disk images and ISOs (an 8 GiB file plus a temporary copy); sequential, no need for NVMe |
| `gha-cache-system/gha-cache-data-v2` | 20Gi | 100Gi `lvm-fast`, cache cap 80 GiB | a bigger cache is a faster build |
| `harper-pad/harper-pad-db-1` | 2Gi | 5Gi `lvm-fast` | database |
| `kube-prometheus-stack-system/prometheus-...-db` | 5Gi | 20Gi `lvm-fast` | metrics (retention is by size) |
| `registry-system/zot-pvc-zot-0` | 60Gi OpenEBS hostpath | 150Gi `lvm-fast` | the pull-through caches of every node; reads must be fast |
| `renovate-system/data-garage-0`, `meta-garage-0` | 10Gi, 1Gi OpenEBS hostpath | 20Gi `lvm-bulk`, 2Gi `lvm-fast` | Renovate's repository cache; the metadata wants speed, the data does not |
| `security-system/dependency-track-db-1`, `dependency-track-storage` | 8Gi, 5Gi | 20Gi, 10Gi `lvm-fast` | database and BOM storage |
| `security-system/data-trivy-server-0`, `trivy-system/data-trivy-server-0` | 5Gi each | 10Gi `lvm-fast` each | vulnerability database |
| `trivy-system/scan-...-trivy-cache` (one per scan Job) | 10Gi local-path | 10Gi `lvm-fast` (ephemeral) | created by the operator per scan |
| `adguard-system/...-adguard-config`, `...-adguard-data` | 1Gi, 10Gi | 1Gi, 10Gi `lvm-fast` | unchanged: the data is tiny |
| `homeserver-vm/homeserver-vm-rootdisk` | 270 GiB | not part of this plan | being fixed in another session |

## Monitoring

The LVM node plugin exports `lvm_vg_*`, `lvm_pv_*` and `lvm_lv_*` on 9500: a ServiceMonitor (from the chart, label `release: kube-prometheus-stack`), the pod label
`prometheus-scrape` and port 9500 in the cluster-wide Cilium policy `prometheus-scrape` open it to Prometheus. Alerts (`openebs-lvm-alerts`): node plugin
unavailable on a node, controller down, a volume group under 10% free for 30 minutes, a volume group missing a disk (the USB disks are the likely ones). The
node filesystem alerts of kube-prometheus-stack keep covering EPHEMERAL.

## Not verified

LVM in Talos 1.14 and the OpenEBS LVM LocalPV driver on Talos (kernel modules, the plugin running `lvm` against the host's `/dev`) are not tested: the pilot is the
test. Whether Talos creates the two raw partitions in the two free regions of `talos-2jc-qux`, and the CEL selectors of the patch, are from the Talos documentation.
