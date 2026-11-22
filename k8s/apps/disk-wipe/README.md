# disk-wipe

One-shot Jobs that wipe disks and partitions that are no longer used, because wiping a disk is a node change (`talosctl wipe`, a reset) that
is not done by hand here. One Job per node (`job.yaml`), the same script (`wipe.sh`, in the ConfigMap `disk-wipe-script`).

Safeguards, in the script: a target is matched by identity (the filesystem UUID of a partition, the model of a USB disk) and its exact size, and
a mismatch fails the Job instead of wiping something else; a device the host has mounted (read from the host mount namespace) is skipped; a
whole-disk wipe only touches USB disks. A target that is not found is reported as already gone, so a Job can run again.

Read the result with `kubectl -n disk-wipe-system logs job/disk-wipe-<node>-1`: lines start with WIPE, DONE, SKIP, GONE, REFUSE or FAILED.

- **SKIP (mounted):** a volume Talos still mounts (talos-11a-esj `local-storage` and `local-storage-cache`). Remove its patch from the machine
  config in Omni, reboot the node, rename the Job (`-2`) and run again.
- **Targets:** talos-tba-msi nvme0n1p1 (the old 200 GB local-path volume); talos-2jc-qux sda2 and sda3 (old partitions next to the live `local-path-sata`
  volume, which is not a target); talos-11a-esj `local-storage` and `local-storage-cache` (80 GB each, unused) and the 4 TB USB disk; talos-vt2-qp8 nvme0n1p3 (the old 200 GB local-path volume) and the 4 TB USB disk.
- **When done:** delete the app (the line in `k8s/clusters/homelab/kustomization.yaml`, `app-disk-wipe.yaml`, this directory and the Polaris exemption).
