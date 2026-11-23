# claude-vm on KubeVirt

[claude-vm-bootc](https://github.com/cthtrifork/homeserver-bootc) (docs/claude-vm) as a KubeVirt VM: 2 vCPU, 8 GiB, 60Gi `lvm-fast` disk,
UEFI, pod network with an SSH LoadBalancer at 192.168.1.246.

## Bring-up order

1. Run the homeserver-bootc workflow "Publish claude-vm containerDisk" (input `tag`). The `claude-vm-containerdisk` package is public today;
   the `ghcr-pull-cdi` Secret keeps the import working if it goes private.
2. Flux then installs the operators (`gitops-infra-kubevirt`), the `KubeVirt` and `CDI` resources (`gitops-infra-post`) and this VM
   (`gitops-virtualmachines`). CDI imports the disk once; `kubectl -n claude-vm get dv,vm,vmi` shows progress.
3. First-boot setup over SSH (signing key, Claude login; the GitHub App is seeded by cloud-init, see below): see "First-boot setup" in the homeserver-bootc docs.

## Things to know

- **Node selection:** the VM is pinned to the nodes KubeVirt labels `kubevirt.io/schedulable` (the ones with `/dev/kvm`).
  `lvm-fast` ties the disk to the node it was first scheduled on.
- **Images by digest:** the `require-image-digest` policy denies tag-only images, so `k8s/infra/kubevirt/kustomization.yaml` pins every image the
  operators start. Renovate bumps those pins together with `versions.env` (one `kubevirt` and one `cdi` PR), and the "Update KubeVirt operators"
  workflow regenerates the vendored manifests on that PR. `scripts/ci/update-kubevirt-operators.sh` fails if the pins and `versions.env` disagree.
- **GitHub App:** the VM acts as the same GitHub App as the claude pod. `externalsecret.yaml` copies `claude-system/claude-github-app` into a cloud-init
  user data Secret (through the `claude-vm-source` store, which can read only that Secret and `ghcr-pull`), and the first boot runs `claude-vm-seed-github-app`.
  The disk image must contain cloud-init. The Claude login and the signing key (`claude-vm-signing-key`) are done by hand over SSH.
- **Egress:** open to `world` at the pod level, because the VM's own egress gateway enforces the host allowlist. The `claude-vm` namespace is
  exempt from the `deny-world-egress` Kyverno policy for this (`k8s/infra/image-policies/`); every other namespace is still checked.
- **Update VMs button:** the VM polls `vm-upgrade.portableinfo.cloud` (the MetalLB address 192.168.1.244); the VM sends its `X-Upgrade-Token`, read from the virtiofs share `upgrade-token` (Secret `vm-upgrade-token`, mounted in the guest), so a rotated token needs no restart.
