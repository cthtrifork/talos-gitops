# claude-vm on KubeVirt

[claude-vm-bootc](https://github.com/cthtrifork/homeserver-bootc) (docs/claude-vm) as a KubeVirt VM: 4 vCPU, 8 GiB, 60Gi `local-path` disk,
UEFI, pod network with an SSH LoadBalancer at 192.168.1.246.

## Bring-up order

1. Merge the homeserver-bootc workflow "Publish claude-vm containerDisk", run it (input `tag`), and make the
   `claude-vm-containerdisk` package public (or CDI cannot pull it).
2. Flux then installs the operators (`gitops-infra-kubevirt`), the `KubeVirt` and `CDI` resources (`gitops-infra-post`) and this VM
   (`gitops-virtualmachines`). CDI imports the disk once; `kubectl -n claude-vm get dv,vm,vmi` shows progress.
3. First-boot setup over SSH (GitHub App, signing key, Claude login): see "First-boot setup" in the homeserver-bootc docs.

## Things to know

- **Node selection:** the VM is pinned to nodes KubeVirt labels `devices.kubevirt.io/kvm`. `talos-2ny-8tx` (a Proxmox VM) has no `/dev/kvm`.
  Drop the `nodeSelector` once every node is bare metal. `local-path` ties the disk to the node it was first scheduled on.
- **Images by digest:** the `require-image-digest` policy denies tag-only images, so `k8s/infra/kubevirt/image-pins.yaml` pins every image the
  operators start. `scripts/ci/update-kubevirt-operators.sh` regenerates it with the operator manifests.
- **Egress:** `networkpolicy.yaml` allows the hosts in the VM's own `egress-allowlist.txt` (names, because `toEntities: world` is denied). Keep the two in step.
- **Update VMs button:** the poll listener only lets `192.168.1.138` (the old VM) in. From the cluster the VM arrives from a node or pod address, so
  add it to `CiliumNetworkPolicy/claude-vm-upgrade` at cutover.
