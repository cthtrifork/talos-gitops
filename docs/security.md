# Security posture

Facts for judging whether a vulnerability is exploitable here (Dependency-Track VEX, Trivy findings). Read from the manifests; paths are named. What lives in Cloudflare, GitHub, Omni or the router is *outside the repo*.

## Cluster

- Three control-plane nodes run all workloads. Talos through Omni. Cilium replaces the CNI and kube-proxy; KubePrism and hostDNS are on.
- `UserNamespacesSupport` is on (`patches/08-feature-gate.yaml`) but no pod sets `hostUsers: false` (Cilium sets `true`): container UIDs are host UIDs.
- Flux reconciles `main` with cluster-admin (`cluster.multitenant: false`). `main` needs a PR with a code-owner approval (`docs/branch-protection.md`, *outside the repo*).

## Reachability

### Internet

Only through a Cloudflare tunnel (outbound `cloudflared` sidecar in the Traefik pod). Traefik is `ClusterIP`, serves plain HTTP on `:8000` on all pod addresses, and its network policy admits no ingress (isolation is the policy, not a loopback bind). `kubernetesCRD` only, no cross-namespace references, no dashboard, access logs off (`k8s/infra/controllers/ingress-system/`).

| Hostname | Routed to | Control in front |
|---|---|---|
| `dtrack.portableinfo.cloud` | Dependency-Track frontend, `/api` to the api-server | Cloudflare Access (*outside the repo*), then Dependency-Track login or API key |
| `harper-sync.portableinfo.cloud` | `harper-pad-sync` | Traefik middlewares (headers, rate limit, body size); DPoP proof. `/readyz` not routed |
| `flux-hook.portableinfo.cloud` | Flux `webhook-receiver`, `/hook/` only | No Access by design. Token-derived path, GitHub HMAC, 5 req/s (burst 10) per `Cf-Connecting-Ip`, 25 MiB body |
| harper-pad admin | `harper-pad-admin` via its own sidecar | Cloudflare Access with OIDC (*outside the repo*). No Service, no Traefik route |
| `shared-files.portableinfo.cloud` | R2 bucket, not the cluster | Public downloads; `r2-sync` copies `public/` |

### LAN (192.168.1.0/24)

MetalLB L2 pool `192.168.1.221-254`, `autoAssign: false`. Cilium LB-IPAM and L2 announcements are off.

| Address | Service | Port | Admitted by the network policy |
|---|---|---|---|
| `.240` | zot registry | 5000, TLS (internal CA) | `world`, host, remote-node, kube-apiserver. No `auth` or `accessControl` |
| `.242` | Dependency-Track API | 8080, HTTP | `world`, host, remote-node, kube-apiserver. Own keys and logins |
| `.243` | Prometheus | 80, HTTP | `192.168.1.0/24`. Whole HTTP API (admin API off), no authentication |
| `.244` | `claude-vm-upgrade` poll listener | 80, HTTP | The two VM pods, host, remote-node. VM API paths need the per-VM token (*Virtual machines*), else 401; `/healthz` needs none |
| `.245` | `claude-urlshare` API | 80 | `192.168.1.0/24` |
| `.246` / `.247` | SSH to `claude-vm` / `homeserver-vm` | 22 | `192.168.1.0/24` |
| `.253` | AdGuard Home DNS | 53, 853, 443 | `world`, `cluster` |

Host-network pods listen on node addresses and no pod policy covers them; node-exporter serves plain HTTP on `<node IP>:9100`. LAN reach to node addresses is the router's call (*outside the repo*).
Policies: `k8s/infra/{registry-system,dependency-track-system,kube-prometheus-stack}/networkpolicy.yaml`, `k8s/apps/{claude-system,adguard}/networkpolicy.yaml`, `k8s/virtualmachines/*/networkpolicy.yaml`.

### Omni service exposer

Services annotated `omni-kube-service-exposer.sidero.dev/*` (grep for it) are published by Omni's exposer on the host network (traffic arrives as `host` or `remote-node`). Access control is Omni's login (*outside the repo*). `claude-elevate` is one of them and grants break-glass RBAC.

## Network

- Cilium enforces policy on every endpoint, with WireGuard. No `hostFirewall`, no `egressGateway`.
- Not endpoints, so no policy: Cilium, MetalLB speaker and `frr-k8s`, node-exporter, Omni exposer, control-plane static pods.
- Namespaces start from default deny (`endpointSelector: {}`) plus per-workload allows. Own shapes: `k8s/infra/post/kube-system/`, `k8s/infra/flux-system/`, `k8s/apps/harper-pad/`.
- Egress is an allowlist (kube-dns, the API where needed, `toFQDNs`), except:
  - `claude-vm`, `homeserver-vm` and CDI importer pods: any destination. `claude-vm`'s own gateway (*outside the repo*) limits the agent users to a host list; `homeserver-vm` has none.
  - `claude-urlshare`: any public address on TCP 80 and 443. `harper-pad-admin`: any public address on 7844 and 443.
  - `arc-runners-system`: about 80 named hosts (GitHub, registries, package hosts, mirrors, Sigstore).
- Ingress from outside the pod network: `world` to zot, Dependency-Track api-server, AdGuard; `host` and `remote-node` to the Omni exposer, kubelet probes and some node-to-pod flows; `kube-apiserver` to webhooks; `cluster` to Flux and AdGuard DNS; `192.168.1.0/24` to Prometheus, `claude-urlshare`, VM SSH.

## Pod security

### Pod Security Admission

Labels are on each namespace (`grep -r pod-security.kubernetes.io k8s`). Enforced level:

- `restricted`: application namespaces, `cert-manager-system`, `traefik-system`, `cnpg-system`, `reloader-system`, `external-secrets-system`, `external-dns-system`, `secret-store`, `cilium-secrets`.
- `baseline`: `policy-system`, `dependency-track-system`, `arc-controller-system`, `cdi`, `adguard-system`, `trivy-system`, `kubevirt-system`, `claude-vm`, `homeserver-vm`.
- `privileged`: `arc-runners-system`, `metallb-system`, `openebs-system`, `registry-system`, `kubevirt`, `kube-prometheus-stack-system`.
- Unlabelled: `kube-system`, `flux-system`. They get Talos's built-in default (enforce `baseline`, audit and warn `restricted`, `kube-system` exempt), set *outside the repo*.

Pods created at runtime (CNPG, ARC, Kyverno, CDI, Trivy scan jobs) are not in the repo; their namespace's level applies.

### Container baseline

Workloads written here, and charts configured to match, set `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`. CI fails below a 100 Polaris score (`.github/workflows/validate.yaml`); each deviation is an exemption with its reason in `k8s/infra/policy-system/polaris/helm-release.yaml`.
A read-only root filesystem does not cover volumes: check `volumeMounts` before ruling out a write (`claude-rc` mounts `/home/claude`, `/workspace`, `/tmp` writable).
Service account tokens are not mounted on most workloads written here (`automountServiceAccountToken: false`); other pods get the default token.

### Exceptions

Root, privileged, host network or host paths (reasons in the Polaris exemptions; Cilium in `k8s/infra/cilium/rendered/`):

- Cilium agent, Envoy, operator: host network. The agent has `NET_ADMIN`, `SYS_ADMIN`, `SYS_RESOURCE` and more, seccomp `Unconfined`, hostPath `/proc`, `/sys/fs/bpf`, `/sys/fs/cgroup`; its `mount-bpf-fs` init container is privileged.
- MetalLB speaker, `frr-k8s`, node-exporter, Omni exposer, Talos static pods: host network. node-exporter also reads host `/`, `/proc`, `/sys`.
- OpenEBS LVM node plugin, KubeVirt `virt-handler`: privileged, root, hostPath `/dev`; `virt-handler` also host PID.
- Spegel: root, containerd socket and content store.
- Root without host access: CoreDNS, MetalLB speaker, `frr-k8s`, Omni exposer. `frr-k8s` and Omni exposer also allow privilege escalation. AdGuard Home allows it for a file capability.
- Writable root filesystem: `virt-operator`, `cdi-operator`, CDI pods, `frr-k8s`, Omni exposer.

### CI runners (`arc-runners-system`, `privileged`)

Pod specs are in HelmRelease values (`k8s/apps/arc-runner/`), not `rendered/`.

- Every scale set except `arc-files-bootc` has a privileged container; `arc-ubuntu`, `arc-ubuntu-podman`, `arc-iso-bootc` also mount hostPath `/dev` (root on the node).
- `arc-iso-bootc` and `arc-e2e-talos-gitops` serve public repositories.
- All scale sets except `arc-e2e-talos-gitops` can read `FILESERVER_TOKEN` (fileserver upload).
- Controls *outside the repo*: owner-only write access, approval for outside collaborators' runs, `environment: file-upload`.

### Virtual machines

- `claude-vm` and `homeserver-vm` run in KubeVirt (masquerade; `claude-vm` forwards only port 22). Both namespaces opt in to the `ops` and `storage` elevate tiers.
- `claude-vm` holds the same GitHub App credential as the `claude-rc` pod, via cloud-init.
- The VMs poll `claude-vm-upgrade` over plain HTTP. Their egress policy sends port 80 to `192.168.1.244` through Cilium's Envoy, which sets `X-Upgrade-Token` from a Secret in `cilium-secrets`, overwriting what the VM sent. The token is not in the VM.
  On VM API paths the listener answers 401 unless the header matches the token of the VM in the path, so a VM acts only as itself. `/healthz` needs no token; sources the network policy rejects get no answer.
  Anything inside a VM can still make requests that get its token injected; a host in the path could answer `{"upgrade": true}`; the token is compared with `==` (`k8s/apps/claude-system/README.md`).

## Admission control

| Policy | Engine | On outage | Checks |
|---|---|---|---|
| `cthtrifork-images` | Kyverno | Blocks | Images `ghcr.io/cthtrifork/talos-gitops/**` and `ghcr.io/cthtrifork/harper-pad-*` carry a keyless cosign signature from `main` of their repo, verified against Rekor. No namespace exempt |
| `deny-world-egress` | Kyverno | Allows | Cilium policies may not allow `world`, `world-ipv4`, `world-ipv6`, `all`. Not applied in the VM namespaces. CIDR rules and Kubernetes NetworkPolicies not checked |
| `require-helmrelease-remediation` | Kyverno | Allows | HelmReleases set retries. Operational only |
| `require-namespace-psa-enforce` | Native VAP | Blocks | A Namespace sets `pod-security.kubernetes.io/enforce` to `privileged`, `baseline` or `restricted`. Exempt: system namespaces, `flux-system` |
| `require-image-digest` | Native VAP | Blocks | Every container, init and ephemeral image has `@sha256:` (`pods` and `pods/ephemeralcontainers`). Exempt in `kube-system`: Talos and Omni generated pods |

Kyverno policies run at admission only (`evaluation.background.enabled: false`); running pods are not re-evaluated. Files: `k8s/infra/{image-policies,policy-system}/`.
The elevate page adds VAPs, all blocking, that bound its grants (`k8s/apps/claude-system/elevate/`).

## Identity and RBAC

- Flux is cluster-admin. Roles that can `pods/exec` (named in the Polaris exemptions): the Flux cluster-admin bindings, `flux-web-admin`, `flux-web-user` (wildcard read), the `cloudnative-pg` and `kubevirt-operator` operators, the `claude-debug` tier.
- `claude-rc` ServiceAccount `claude`: built-in `view` (no Secrets) plus read of nodes, PVs, StorageClasses, CRDs, ClusterRoles and bindings. No write verbs, no `pods/exec` (`k8s/apps/claude-system/rbac.yaml`).
- The `claude-rc` pod also holds: the claude.ai login on a PVC; a one-hour GitHub App installation token (Contents, Pull requests, Workflows read/write on installed repositories); an Omni service account with role Reader (TTL 365 days); the Dependency-Track key of the `claude-triage` team (analysis read/create/update; no BOM upload, no admin); optionally a `read:packages` GHCR token and a read-only Cloudflare API token.
- Elevate tiers (`ops`, `debug`, `storage`, `flux`) are ClusterRoles that `claude-elevator` binds per opted-in namespace (`claude-elevate/<tier>` label) for a short-lived token (`k8s/apps/claude-system/elevate/configmap.yaml`). No tier patches workloads except `debug` on `pods/ephemeralcontainers`; `flux` patches annotations on HelmReleases and Kustomizations only. `debug` (`pods/exec`, `attach`, `portforward`, ephemeral containers) is opted in by `adguard-system` only. Jobs from a CronJob are allowed only in `dependency-track-system`.
- `claude-elevator` can create ServiceAccounts, RoleBindings, Jobs and tokens cluster-wide; `bind`, `patch`, `delete`, `token` are pinned to the four tier names, and the VAPs bound where they apply.

## Secrets

- Committed secrets are SOPS/age encrypted (`.sops.yaml`); CI checks (`scripts/ci/check-secrets-encrypted.sh`). Flux decrypts with `flux-system/sops-age`; the age key is outside Git.
- Generated secrets never enter Git: the Dependency-Track KEK and admin password, the fileserver upload token, the per-VM poll tokens, the Garage keys. They come from External Secrets in `secret-store` (`k8s/infra/secret-store/`). The `secret-store` ClusterSecretStore is usable only from `secret-store`, `renovate-system`, `dependency-track-system`, `fileserver-system`, `arc-runners-system`, `claude-system`, `cilium-secrets`; its ServiceAccount reads and writes Secrets in `secret-store` only.
- Losing the Dependency-Track KEK makes its encrypted content unreadable.
- Certificates: internal CA (`portableinfo-root-ca`) for zot, Hubble and the runners' trust bundle; Let's Encrypt DNS-01 through Cloudflare for AdGuard. harper-pad's database uses client certificates.

## Supply chain

- Renovate pins digests and automerges patch and digest updates, except components listed in `renovate.json5`.
- Pull path: containerd, Spegel, zot, upstream (`docs/registry-mirrors.md`). Container images pin digests, so the mirror cannot change what runs. Pulled by tag instead: the VM disks (`*-containerdisk:latest`, imported by CDI) and the Trivy `vex-cache:latest` volume.
- Images built here are signed keyless with cosign, attested and scanned with Trivy (`.github/workflows/`).

### Vulnerability data flow

```mermaid
flowchart TB
  trivy["Trivy scan jobs: offline, databases from zot"] -->|"SbomReport only"| hook[sbom-hook]
  hook --> dt["Dependency-Track: project per image, version = digest (tag if none)"]
  dt -->|"Trivy analyzer query"| ts[trivy-service]
  dt -->|"not affected, false positive, resolved"| vex["daily vex-export Job"]
  vex -->|"PR to vex/, review required"| repo["vex/ on main, plus hand-written statements"]
  hub["Trivy VEX Hub"] --> cache["vex-cache image"]
  repo --> cache
  cache -->|"hides findings after the next report regeneration"| trivy
```

- Trivy scans running workloads with `scanners: [vuln]` (exposed-secret scanning off). `arc-runners-system` and `arc-controller-system` are excluded. No scan of the Talos OS or VM guests.
- Trivy ignores `will_not_fix` and `not_affected`; its ignore file and Rego policy are empty. Scan jobs are offline and reach only the Trivy server and zot.
- A hidden finding need not come from a Dependency-Track decision (VEX Hub, hand-written statements). Only `Dependency-Track`-authored documents are exported, via a GitHub App PR that `main` review gates. Trivy matches statements by PURL and digest, so a decision on a tag-versioned project is not exported (`vex/README.md`).

## Using this for a CVE

| If the vulnerability needs | Fact |
|---|---|
| Network access from the internet | Only the five *Internet* entries; the rest has default-deny ingress |
| Network access from the LAN | The LAN table plus host-network listeners (node-exporter 9100); others accept pod and node traffic as listed |
| A connection out to an attacker host | FQDN allowlist, except the VMs, `claude-urlshare`, `harper-pad-admin`; broad list for runners (*Network*) |
| A writable root filesystem, root, capabilities, privileged container, node access | Only the *Exceptions* and the runners; volumes can still be writable (*Container baseline*) |
| A service account token | Not mounted on listed pods; otherwise check the pod's ServiceAccount |
| Reading Secrets across namespaces | `claude` cannot read Secrets; `secret-store` reads only its own namespace |
| A shell in a pod | `pods/exec` holders in *Identity and RBAC* |
| A changed image or tag | Digest required by a native VAP; our own images also need a cosign signature (*Admission control*) |
