# juicefs-system

Backends for a JuiceFS filesystem that gives the ARC runners ReadWriteMany caches across nodes. The CSI driver follows in a later change.

| Part | What | Where it lives |
|---|---|---|
| Garage | Object store for the data blocks, 3 nodes, `replication_factor = 3`, bucket `juicefs` | `garage/`, `lvm-bulk` 10 Gi and `lvm-fast` 1 Gi per node |
| `juicefs-meta` | PostgreSQL (CNPG) for the metadata, 3 instances, one synchronous standby, client-certificate login only (`issuer.yaml`, `certificate.yaml`) | `postgres-cluster.yaml`, `lvm-fast` 2 Gi per instance |
| CSI driver | JuiceFS CSI driver 0.34.0 in mount pod mode, StorageClass `juicefs` (ReadWriteMany) | `csi/`, `storageclass.yaml`; chart mirrored by `scripts/ci/helm/load-juicefs-charts.yaml` |

- A separate Garage from Renovate's: `replication_factor` is fixed when a cluster is created.
- Garage stays off `talos-tba-msi`, which has no `vg-bulk`.
- The sizes come from the peak use of the shared caches over 3 days (4.0 GiB, about 1.4k files). Overview, failure behaviour and how to grow a volume: `docs/storage.md`.
- No backups: the filesystem only holds CI caches.
- The S3 key, RPC secret and admin token are generated in `k8s/infra/secret-store/`.
