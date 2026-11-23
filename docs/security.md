# Security posture

Facts about this cluster for deciding whether a vulnerability is exploitable here (VEX decisions in Dependency-Track, Trivy findings).
Every statement is read from the manifests; the file is named next to it. Things that live in Cloudflare, GitHub or Omni are not
visible in the repo and are marked *outside the repo*: they come from the README or comment cited.

## Cluster

- Three nodes, all control plane (`patches/13-lb-node-labels.yaml`, `docs/registry-mirrors.md`). Workloads run on the control-plane nodes.
- Talos Linux, managed through Omni (`omniconfig.yaml`).
- No CNI from Talos and no kube-proxy; Cilium replaces both (`patches/01-cni.yaml`, `k8s/infra/cilium/helm-release.yaml`: `kubeProxyReplacement: true`).
- KubePrism on 7445 and Talos hostDNS on (`patches/05-kubeprism.yaml`, `patches/07-hostdns.yaml`).
- The `UserNamespacesSupport` feature gate is on (`patches/08-feature-gate.yaml`); no manifest sets `hostUsers`.
- Flux reconciles `main` of `cthtrifork/talos-gitops` (`k8s/clusters/homelab/flux-instance.yaml`). `main` needs a PR with a code-owner approval (`docs/branch-protection.md`, ruleset *outside the repo*).

## What is reachable

### From the internet

All public traffic arrives through a Cloudflare tunnel (outbound connection from the `cloudflared` sidecar in the Traefik pod). Traefik has `type: ClusterIP`,
and its CiliumNetworkPolicy has no ingress rule (`k8s/infra/controllers/ingress-system/`). TLS ends at Cloudflare; Traefik listens on plain HTTP on `localhost:8000`.
Access logs are off.

| Hostname | Routed to | Control in front of it |
|---|---|---|
| `dtrack.portableinfo.cloud` | Dependency-Track frontend, and `/api` to the api-server | Cloudflare Access policy (*outside the repo*; `k8s/infra/dependency-track-system/README.md`) plus Dependency-Track's own login and API keys |
| `harper-sync.portableinfo.cloud` | `harper-pad-sync` | Traefik middlewares for headers, rate limit and body size; the API demands a DPoP proof (`k8s/apps/harper-pad/`). `/readyz` is not routed |
| `flux-hook.portableinfo.cloud` | Flux `webhook-receiver`, only `/hook/` | No Cloudflare Access by design. The path is derived from the token and GitHub's HMAC signature is required; 5 requests/s (burst 10) per `Cf-Connecting-Ip`, 25 MiB body (`k8s/infra/flux-system/`, `k8s/infra/post-workloads/flux-system/`) |
| harper-pad admin | `harper-pad-admin` on loopback, through its own `cloudflared` sidecar | Cloudflare Access with OIDC (*outside the repo*). No Service, no Traefik route (`k8s/apps/harper-pad/README.md`) |
| `shared-files.portableinfo.cloud` | Cloudflare R2 bucket, not the cluster | Public downloads; `r2-sync` in `fileserver-system` copies `public/` to the bucket (`k8s/apps/fileserver/README.md`) |

Traefik: `kubernetesCRD` only, `allowCrossNamespace: false`, `kubernetesIngress` off, dashboard off, `forwardedHeaders` trusted from `127.0.0.1/32` only (`k8s/infra/controllers/ingress-system/traefik/helm-release.yaml`).

### From the LAN (192.168.1.0/24)

MetalLB L2 pool `192.168.1.221-254`, `autoAssign: false` (`k8s/infra/post/metallb/ipaddresspool.yaml`). Cilium LB-IPAM and L2 announcements are off (`k8s/infra/cilium/helm-release.yaml`).

| Address | Service | Port | Admitted by the network policy |
|---|---|---|---|
| `192.168.1.240` | zot registry (`registry-system`) | 5000, TLS from the internal CA | `world`, host, remote-node, kube-apiserver. `zot.json` has no `auth` or `accessControl` block |
| `192.168.1.242` | Dependency-Track API (`dependency-track-system`) | 8080, plain HTTP | `world`, host, remote-node, kube-apiserver. API keys and logins are Dependency-Track's own |
| `192.168.1.243` | Prometheus (`prometheus-otlp-lb`) | 80, plain HTTP | `fromCIDR 192.168.1.0/24` on 9090. The whole Prometheus HTTP API, admin API off; no authentication (`k8s/apps/claude-system/README.md`) |
| `192.168.1.244` | `claude-vm-upgrade` poll listener | 80 (pod 8081) | The two VM pods, host and remote-node. No token; plain HTTP (`k8s/apps/claude-system/README.md`) |
| `192.168.1.245` | `claude-urlshare` API | 80 (pod 8081) | `fromCIDR 192.168.1.0/24` |
| `192.168.1.246` / `.247` | SSH to `claude-vm` / `homeserver-vm` | 22 | `fromCIDRSet 192.168.1.0/24` |
| `192.168.1.253` | AdGuard Home DNS | 53, 853, 443 | `world` and `cluster` |

Policy files: `k8s/infra/registry-system/networkpolicy.yaml`, `k8s/infra/dependency-track-system/networkpolicy.yaml`, `k8s/infra/kube-prometheus-stack/networkpolicy.yaml`,
`k8s/apps/claude-system/networkpolicy.yaml`, `k8s/apps/adguard/networkpolicy.yaml`, `k8s/virtualmachines/*/networkpolicy.yaml`.

### From the Omni service exposer

Services annotated `omni-kube-service-exposer.sidero.dev/*` are published by Omni's exposer, which runs on the host network, so its traffic arrives as the `host` or `remote-node` entity.
The access control is Omni's login (*outside the repo*; `k8s/apps/claude-system/README.md` states "behind Omni login" for the VM-upgrade page).
Annotated services: AdGuard web, Renovate UI, `claude-elevate`, `claude-usage`, `claude-cockpit`, `claude-urlshare`, `claude-vm-upgrade` page, fileserver admin, Hubble UI,
Flux Operator web UI, Prometheus, Polaris dashboard, zot.

`claude-elevate` is the page that grants break-glass RBAC (see *Identity and RBAC*).

## Network

- `policyEnforcementMode: always`, `policyAuditMode: false` (`k8s/infra/cilium/helm-release.yaml`). Host-network pods are not endpoints and are not covered by any policy.
- WireGuard encryption is on (`encryption.type: wireguard`). Native routing, `ipv4NativeRoutingCIDR: 10.244.0.0/16`, BPF masquerade. `egressGateway` is off. No `hostFirewall` value is set.
- Hubble relay uses mTLS; certificates come from cert-manager (`certificate-cluster-issuer`).

### Default deny

Every namespace manifest in the repo has a CiliumNetworkPolicy with `endpointSelector: {}`, `ingress: [{}]`, `egress: [{}]`, followed by per-workload allows, with these exceptions:

- `kube-system` and `flux-system` are not created by a manifest here; their default-deny policies are in `k8s/infra/post/kube-system/ciliumnetworkpolicy.yaml` and `k8s/infra/flux-system/ciliumnetworkpolicy.yaml`.
- `harper-pad` uses Kubernetes NetworkPolicies (`k8s/apps/harper-pad/networkpolicy.yaml`) whose default deny selects only pods labelled `app: harper-pad-sync` or `harper-pad-admin`, plus `db-egress` for the CNPG pods (`ciliumnetworkpolicy.yaml`). The CNPG database pods are covered by `db-ingress`.

Cluster-wide policies (`CiliumClusterwideNetworkPolicy`):

- `prometheus-scrape` (`k8s/infra/kube-prometheus-stack/cilium-clusterwide-networkpolicy.yaml`): pods labelled `prometheus-scrape: "true"` accept Prometheus on a fixed list of metrics ports.
- `cilium-health` (`k8s/infra/post/cilium/ciliumclusterwidenetworkpolicy.yaml`): host and remote-node for the health endpoint.

### Egress

Egress is an allowlist: DNS to kube-dns, the Kubernetes API where needed, and named hosts with `toFQDNs` (the kube-dns rule carries a `dns` rule so Cilium learns the addresses).
Examples: Dependency-Track api-server reaches only its feed hosts on 443 (`k8s/infra/dependency-track-system/networkpolicy.yaml`); Trivy scan jobs reach only the Trivy server and zot (`k8s/infra/trivy-system/README.md`).

Broader egress, all stated in the files:

| Workload | Egress | File |
|---|---|---|
| `claude-vm`, `homeserver-vm` and their CDI importer pods | `toEntities: world`, all ports. `claude-vm`'s own gateway (nftables, nginx, dnsmasq inside the VM; *outside the repo*) restricts the agent users to a host list; `homeserver-vm` has none | `k8s/virtualmachines/*/networkpolicy.yaml` |
| `claude-urlshare` | `0.0.0.0/0` except private and reserved ranges, TCP 80 and 443 (it fetches user-approved URLs) | `k8s/apps/claude-system/networkpolicy.yaml` |
| `harper-pad-admin` | Non-RFC1918 addresses on TCP/UDP 7844 and TCP 443 (Kubernetes NetworkPolicy) | `k8s/apps/harper-pad/networkpolicy.yaml` |
| `arc-runners-system` | About 80 named hosts: GitHub, container registries, package and tool hosts, Fedora and Ubuntu mirrors, Sigstore, VS Code marketplace | `k8s/apps/arc-runner/networkpolicy.yaml` |
| AdGuard Home | DoH upstreams, bootstrap resolvers and `192.168.1.0/24` on 53 by CIDR | `k8s/apps/adguard/networkpolicy.yaml` |

The `deny-world-egress` Kyverno policy (below) rejects `world` and `all` entities in Cilium policies, outside `claude-vm` and `homeserver-vm`. CIDR rules and Kubernetes NetworkPolicies are not checked.

### Ingress admitted from outside the pod network

- `world`: zot, Dependency-Track api-server, AdGuard (see the LAN table).
- `host` and `remote-node`: Omni exposer targets, kubelet probes and some node-to-pod flows, in most namespaces.
- `kube-apiserver`: webhook receivers (cert-manager, external-secrets, kubevirt, prometheus operator, Kyverno, and others).
- `cluster`: Flux (`9080`, `8080`, `9292`), AdGuard DNS.
- `192.168.1.0/24`: Prometheus 9090, `claude-urlshare` 8081, VM SSH 22.

## Pod security

### Pod Security Admission labels

| Level | Namespaces |
|---|---|
| `restricted`, enforce + audit + warn | `claude-system`, `renovate-system`, `fileserver-system`, `gha-cache-system`, `harper-pad`, `cert-manager-system`, `traefik-system`, `storage-system`, `reloader-system` |
| `restricted`, enforce only | `external-secrets-system`, `external-dns-system`, `secret-store` |
| `baseline` enforce, `restricted` audit + warn | `policy-system`, `dependency-track-system`, `arc-controller-system` (pods created at runtime by CNPG, ARC and Kyverno are not in the repo), `cdi` (label patched over the upstream manifest in `k8s/infra/kubevirt/kustomization.yaml`; CDI creates its pods at runtime) |
| `baseline`, enforce + audit + warn | `adguard-system` (file capability needs `allowPrivilegeEscalation`), `trivy-system` (scan jobs are created at runtime), `kubevirt-system` |
| `baseline`, enforce + warn | `claude-vm`, `homeserver-vm` (virt-launcher needs `NET_BIND_SERVICE` and `/dev/kvm`) |
| `privileged`, enforce | `arc-runners-system`, `metallb-system` (both also audit + warn), `openebs-system`, `registry-system`, `kubevirt`, `kube-prometheus-stack-system` (warn `baseline`) |
| no PSA label in the repo | `kube-system` (exempt) and `flux-system`; the default in `patches/19-pod-security.yaml` applies: `enforce: baseline`, `audit` and `warn: restricted` |

### Container baseline

Workloads written in this repo and the charts configured to match set `runAsNonRoot`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]` and `seccompProfile: RuntimeDefault`. The CI job `polaris` (`.github/workflows/validate.yaml`) audits `k8s/` and fails below a score of 100;
every exception is an explicit exemption in `k8s/infra/policy-system/polaris/helm-release.yaml` (`missingNetworkPolicy` and `automountServiceAccountToken` checks are ignored there).

`automountServiceAccountToken: false` is set on: claude-cockpit, elevate, urlshare, usage, vm-upgrade, fileserver, harper-pad, AdGuard Home and its exporter, Dependency-Track api-server, frontend, vex-export and sbom-hook, trivy-server, valkey, hubble-relay, node-exporter, zot, `secret-store`.
Other pods get the default token.

### Exceptions to the baseline

| Workload | Deviation | File |
|---|---|---|
| Cilium agent and Envoy | Host network; hostPath `/proc`, `/sys/fs/bpf`, `/sys/fs/cgroup`; agent adds `NET_ADMIN`, `SYS_ADMIN`, `SYS_RESOURCE`, `CHOWN`, `KILL`, `NET_RAW`, `IPC_LOCK`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID`; seccomp `Unconfined`; `mount-bpf-fs` init container is privileged | `k8s/infra/cilium/rendered/` |
| `cilium-operator` | Host network | `k8s/infra/cilium/rendered/` |
| MetalLB speaker and `frr-k8s` | Host network; `frr` adds `NET_ADMIN`, `NET_RAW`, `SYS_ADMIN`, `NET_BIND_SERVICE`; speaker and `frr-k8s` run as root | `k8s/infra/controllers/metallb/rendered/`, Polaris exemptions |
| `node-exporter` | Host network and PID; hostPath `/`, `/proc`, `/sys`; still non-root with a read-only root filesystem | `k8s/infra/kube-prometheus-stack/` |
| Spegel | Root; hostPath containerd socket, content store and `/etc/cri/conf.d/hosts` | `k8s/infra/registry-system/spegel/` |
| OpenEBS LVM node plugin | Privileged, root, hostPath (`/dev`, kubelet directory) | `k8s/infra/openebs-system/`, Polaris exemptions |
| KubeVirt `virt-handler` | Privileged, root, host PID, hostPath (`/dev/kvm`, kubelet) | Polaris exemptions |
| Omni service exposer | Host network, root, writable root filesystem; manifest generated by Omni | Polaris exemptions |
| Talos static pods and CoreDNS | kube-apiserver, kube-controller-manager and kube-scheduler use host network and hostPath; CoreDNS has no seccomp profile and may run as root | Polaris exemptions |
| AdGuard Home | Adds `NET_BIND_SERVICE` with `allowPrivilegeEscalation: true` (file capability on the binary) | `k8s/apps/adguard/` |

| `virt-operator`, `cdi-operator` and the CDI pods | Writable root filesystem | Polaris exemptions |

### CI runners (`arc-runners-system`, namespace `privileged`)

The runner pod specs are in HelmRelease values (`k8s/apps/arc-runner/`), not in `rendered/`.

| Scale set | Repo | Privileged | Reads `FILESERVER_TOKEN` |
|---|---|---|---|
| `arc-ubuntu` (`helm-release.yaml`) | `homeserver-bootc` | runner and `dind` sidecar; hostPath `/dev`, `/run/udev`; the `tmp-perms` init container runs as root (no capabilities, read-only root filesystem) | yes |
| `arc-ubuntu-podman` (`helm-release-podman.yaml`) | `homeserver-bootc` | runner; hostPath `/dev`, `/run/udev`; `tmp-perms` init container as for `arc-ubuntu` | yes |
| `arc-iso-bootc` (`helm-release-bootc-iso.yaml`) | `github-runner-bootc` (public) | runner; hostPath `/dev`, `/run/udev` | yes |
| `arc-files-bootc` (`helm-release-bootc-files.yaml`) | `github-runner-bootc` | no: non-root, drop ALL, no privilege escalation | yes (upload-only job) |
| `arc-e2e-talos-gitops` (`helm-release-talos-gitops-e2e.yaml`) | `talos-gitops` (public) | `dind` sidecar; the runner runs as 1001 with default capabilities and privilege escalation, because `run.sh` calls `sudo update-ca-certificates` | no |

- All scale sets set pod `seccompProfile: RuntimeDefault` (privileged containers run unconfined regardless) and `fsGroup: 1001`. The `data-retention`, `init-dind-externals` and `tmp-perms` init containers drop all capabilities and set `readOnlyRootFilesystem`; `data-retention` and `init-dind-externals` run as 1001. The listeners run non-root with all capabilities dropped and no privilege escalation.
- The runner container has a writable root filesystem and no probes in every scale set: the image writes to `/etc` and patches `Runner.Worker.dll`, and the chart has no probe values for runner pods. Polaris exempts these in `k8s/infra/policy-system/polaris/helm-release.yaml`.
- A privileged pod with hostPath `/dev` is root on the node. The files state this for `arc-iso-bootc` (`SECURITY:` comment) and name the controls *outside the repo*: write access limited to the owner, approval for outside collaborators' runs, `environment: file-upload` on uploads.
- `FILESERVER_TOKEN` is the fileserver upload token, rotated every 30 days by External Secrets (`k8s/apps/fileserver/README.md`).
- Runner namespaces `arc-runners-system` and `arc-controller-system` are excluded from Trivy scanning (`excludeNamespaces`, `k8s/infra/trivy-system/trivy-operator/helm-release.yaml`).
- Runner egress is the FQDN allowlist above. Runner ingress is default deny with no allow rule.

### Virtual machines

- `claude-vm` and `homeserver-vm` run in KubeVirt on namespaces labelled `baseline`. Pod network with masquerade; for `claude-vm` only port 22 is forwarded (`k8s/virtualmachines/claude-vm/virtualmachine.yaml`).
- Both namespaces opt in to the `ops` and `storage` elevate tiers.
- `claude-vm` holds the same GitHub App credential as the `claude-rc` pod, seeded through cloud-init (`k8s/virtualmachines/claude-vm/README.md`).

## Admission control

| Policy | Action | On Kyverno outage | Checks |
|---|---|---|---|
| `cthtrifork-images` | Deny | Blocks (`failurePolicy: Fail`; `matchConditions` limit the webhook to pods with these images) | Images under `ghcr.io/cthtrifork/talos-gitops/**` and `ghcr.io/cthtrifork/harper-pad-*` carry a keyless cosign signature from `build-*.yaml@refs/heads/main` of `talos-gitops` (or `release.yml@refs/heads/main` of `harper-pad`), verified against Rekor. No namespace is exempt. The expression verifies `images.containers` |
| `deny-world-egress` | Deny | Allows (`failurePolicy: Ignore`) | Cilium (cluster-wide) policies may not allow `toEntities` `world`, `world-ipv4`, `world-ipv6` or `all`. Not applied in `claude-vm` and `homeserver-vm` |
| `require-helmrelease-remediation` | Deny | Allows | HelmReleases set retries. Operational only |

- All three set `evaluation.background.enabled: false`: they run at admission, running pods are not re-evaluated. Kyverno runs the admission controller only, with two replicas (`k8s/infra/kyverno/helm-release.yaml`).
- Files: `k8s/infra/image-policies/`.
- Images built in this repo (`claude-runner`, `fileserver`, `github-actions-runner`, `vex-cache`) are pushed with an SBOM and provenance, signed keyless with cosign and attested (`.github/workflows/build-release-image.yaml`).

ValidatingAdmissionPolicies for the elevate page (`k8s/apps/claude-system/elevate/validatingadmissionpolicy.yaml`, all `failurePolicy: Fail`): token lifetime per tier, RoleBinding limited to the tier's ServiceAccount in an opted-in namespace,
the flux tier limited to `reconcile.fluxcd.io/*` annotations, Jobs created from a CronJob only in namespaces labelled `claude-elevate/jobs` (only `dependency-track-system`).

`require-namespace-psa-enforce` (`k8s/infra/policy-system/`, native ValidatingAdmissionPolicy, `failurePolicy: Fail`, evaluated by the API server without Kyverno): creating or updating a Namespace is denied unless `pod-security.kubernetes.io/enforce` is `privileged`, `baseline` or `restricted`. `default`, `kube-system`, `kube-public`, `kube-node-lease` and `flux-system` are exempt.

`require-image-digest` (`k8s/infra/image-policies/`, native ValidatingAdmissionPolicy, `failurePolicy: Fail`, evaluated by the API server without Kyverno): a Pod create or update is denied unless every container, init and ephemeral image contains `@sha256:`. Exempt in `kube-system` only: the apiserver, controller-manager and scheduler images, CoreDNS and `ghcr.io/siderolabs/kube-service-exposer`. It matches `pods`, not the `pods/ephemeralcontainers` subresource, so `kubectl debug` with a tag is not denied.

The Pod Security Admission default for unlabelled namespaces is set in `patches/19-pod-security.yaml`: `enforce: baseline`, `audit` and `warn: restricted`, `kube-system` exempt.

## Identity and RBAC

- Flux runs with cluster-admin: `cluster.multitenant: false` (`k8s/clusters/homelab/flux-instance.yaml`); the Polaris exemptions call the bindings `cluster-reconciler-flux-system` and `flux-operator-cluster-admin` "cluster-admin by design".
- `pods/exec`-capable roles that the Polaris exemptions name (`k8s/infra/policy-system/polaris/helm-release.yaml`): the Flux cluster-admin bindings, `flux-web-admin` and `flux-web-user` (wildcard read), the `cloudnative-pg` operator (it execs into its database pods) and the `claude-debug` tier.
- `claude-rc` ServiceAccount `claude`: built-in `view` (no Secrets) plus read of nodes, PVs, StorageClasses, CRDs, ClusterRoles and bindings, and listed CRD groups. No write verbs, no `pods/exec` (`k8s/apps/claude-system/rbac.yaml`).
- The `claude-rc` pod also holds: the claude.ai login on a PVC; a one-hour GitHub App installation token (the App has Contents, Pull requests and Workflows read/write on its installed repositories); an Omni service account with role Reader (TTL 365 days); the Dependency-Track key of the `claude-triage` team (analysis read/create/update, no BOM upload, no admin); optionally a `read:packages` GHCR token and a read-only Cloudflare API token. Source: `k8s/apps/claude-system/README.md`, `k8s/infra/dependency-track-system/README.md`.
- Elevate tiers are ClusterRoles bound per namespace by `claude-elevator` for a short-lived token (limits in minutes: `ops` 60, `debug` 15, `storage` 15, `flux` 15; `k8s/apps/claude-system/elevate/configmap.yaml`). No role can patch workloads (`k8s/apps/claude-system/clusterrole-elevated.yaml`).

  | Tier | Verbs | Namespaces opted in |
  |---|---|---|
  | `ops` | delete and evict pods, delete StatefulSets, delete Trivy reports | 15 namespaces labelled `claude-elevate/ops`, including the VM namespaces; not `claude-system`, `secret-store`, `cert-manager-system`, `storage-system` and others without the label |
  | `debug` | `pods/exec`, `pods/attach`, `pods/portforward`, ephemeral containers | `adguard-system` only |
  | `storage` | delete PVCs, CNPG Clusters, CDI DataVolumes | namespaces with a `claude-elevate/storage` label |
  | `flux` | patch HelmReleases and Kustomizations (annotations only, by admission) | namespaces with a `claude-elevate/flux` label |

- `claude-elevator` can create ServiceAccounts, RoleBindings, Jobs and tokens cluster-wide; `bind`, `patch`, `delete` and `token` are pinned to the four tier names, and the policies above bound who is bound where.

## Secrets

- Committed secrets are SOPS/age encrypted (`.sops.yaml`: YAML `data` and `stringData`, JSON whole). 16 `*.enc.yaml` files. CI runs `scripts/ci/check-secrets-encrypted.sh` (`.github/workflows/validate.yaml`).
- Flux decrypts with `flux-system/sops-age`. The age private key is kept outside Git and the cluster's copy is the Secret (`readme.md`, "Secrets (SOPS)").
- Generated secrets never enter Git: the Dependency-Track KEK and admin password, the fileserver upload token, and the Garage keys are created by External Secrets in the `secret-store` namespace (`k8s/infra/secret-store/`) and copied out.
- The `secret-store` ClusterSecretStore is usable only from `secret-store`, `renovate-system`, `dependency-track-system`, `fileserver-system`, `arc-runners-system` (`k8s/infra/secret-store/clustersecretstore.yaml`). Its ServiceAccount can read, create and update Secrets in `secret-store`.
- Dependency-Track encrypts stored secrets with the KEK; losing the KEK makes them unreadable (`k8s/infra/dependency-track-system/README.md`).
- Certificates: an internal CA (`certificate-cluster-issuer`, root `portableinfo-root-ca`) for zot, Hubble and runners' trust bundle; Let's Encrypt DNS-01 through Cloudflare for AdGuard (`k8s/infra/post/cert-manager/`).
- harper-pad's database uses client-certificate authentication, no passwords (`k8s/apps/harper-pad/README.md`).

## Supply chain

- Renovate keeps digests current: `pinDigests: true`, patch and digest updates automerge; Cilium and KubeVirt/CDI updates, major and minor Flux updates, Renovate-operator majors and Garage do not (`renovate.json5`).
- Images are pulled containerd, then Spegel (peer nodes), then zot (`192.168.1.240`, internal CA pinned), then the upstream registry (`docs/registry-mirrors.md`, `patches/11-zot-mirrors.yaml`). Digests are pinned in manifests, so the mirror path cannot change the content that runs.
- zot syncs on demand from ghcr.io, gcr.io, quay.io, registry.k8s.io, us-docker.pkg.dev and Docker Hub with `tlsVerify: true` (`k8s/infra/registry-system/zot/zot.json`).
- CI: `yamllint`, `actionlint`, `shellcheck`, `kubeconform`, a Polaris audit and an SOPS check (`.github/workflows/validate.yaml`). Images built here are scanned with Trivy (`.github/workflows/images.yaml`).

### Vulnerability data flow

```text
Trivy operator (SBOM + vuln scan) -> sbom-hook -> Dependency-Track (one project per image digest)
Dependency-Track analysis (not affected, false positive, resolved) -> daily vex-export Job -> PR to vex/ -> vex-cache image -> Trivy scan jobs hide those findings
```

- Trivy operator scans running workloads with `scanners: [vuln]`; exposed-secret scanning is off. `arc-runners-system` and `arc-controller-system` are excluded (`k8s/infra/trivy-system/trivy-operator/helm-release.yaml`).
- Severity source is `redhat`, then `auto`. Trivy ignores findings with status `will_not_fix` and `not_affected`. The ignore file and Rego ignore policy are empty (`k8s/infra/trivy-system/trivy-operator/ignore/`).
- Scan jobs are offline: databases come from zot, VEX data from the `vex-cache` image, and they may reach only the Trivy server and zot.
- Dependency-Track enriches with CISA and ENISA KEV, the Trivy analyzer (against the in-cluster Trivy server), and its NVD, GitHub and OSV sources at their defaults (`k8s/infra/dependency-track-system/README.md`).
- VEX statements: `vex/README.md`. Only `Dependency-Track`-authored documents are exported automatically; the export pushes as a GitHub App to a branch and opens a PR, and `main` still needs review.
- Trivy matches a statement by PURL and digest; a decision on a tag-versioned project is not exported.

## Using this for a CVE

| If the vulnerability needs | Repo fact | Where |
|---|---|---|
| Network access to the service from the internet | Only the five entries under *From the internet* are reachable; everything else has default-deny ingress | Reachable table, network policies |
| Network access from the LAN | Only the LAN table; other services accept pod and node traffic as listed | LAN table |
| A connection out to an attacker host | FQDN allowlist for most namespaces; open for `claude-vm`, `homeserver-vm`, `claude-urlshare`, `harper-pad-admin`; broad list for runners | Egress table |
| Writing to the container filesystem | `readOnlyRootFilesystem: true` except the exceptions table and runners | Exceptions table |
| Root, extra capabilities or a privileged container | Non-root with all capabilities dropped except the exceptions table and the runners | Exceptions table, runners |
| A service account token | `automountServiceAccountToken: false` on the listed pods; otherwise check the pod's ServiceAccount and its RBAC | Container baseline |
| Reading Secrets across namespaces | The `claude` ServiceAccount cannot read Secrets; the `secret-store` ServiceAccount can read Secrets in `secret-store` only | Identity and RBAC |
| A shell in a pod | `pods/exec` is in the `debug` tier (granted on request, `adguard-system` only), Flux, `flux-web-*` and the CloudNativePG operator | Identity and RBAC |
| Pulling an image or tag that changed | Digests are required at admission (fail-open on Kyverno outage); our own images also need a cosign signature (fail-closed) | Admission control |
| Node access from a container | Only the privileged and host-level workloads in the exceptions table and the runners | Exceptions table, runners |

## Gaps and exceptions, stated as facts

- `kube-system` and `flux-system` carry no PSA label in the repo; the default in `patches/19-pod-security.yaml` applies to `flux-system` (`kube-system` is exempt).
- `deny-world-egress` allows everything while Kyverno is unavailable. Only `cthtrifork-images` blocks.
- `cthtrifork-images` and the other policies are admission-only: a running pod is not re-checked.
- `deny-world-egress` does not see CIDR rules or Kubernetes NetworkPolicies; the `claude-urlshare` and `harper-pad-admin` rules are of that kind.
- Host-network pods (Cilium, MetalLB speaker and `frr-k8s`, node-exporter, Omni exposer, the control-plane static pods) are outside Cilium policy enforcement.
- zot is unauthenticated according to `zot.json` and is reachable from the LAN. Dependency-Track's API is served in plain HTTP on the LAN; Prometheus on `192.168.1.243` has no authentication.
- The VM-upgrade poll listener has no token: any host that can reach `192.168.1.244:80`, or any host-network process on a node, can poll or claim (`k8s/apps/claude-system/README.md`).
- Privileged runners can read `FILESERVER_TOKEN`; protection of the repositories that use them is configured in GitHub (*outside the repo*).
- Workloads and Talos nodes share hardware: the three nodes are control plane and run all workloads.
- The Trivy operator does not scan `arc-runners-system` or `arc-controller-system`. No scan of the Talos OS or of the VM guest operating systems is configured in this repo.
