# Agent Substrate (ate-system)

[Agent Substrate](https://github.com/agent-substrate/substrate) runs sandboxed agents ("actors") on a small pool of warm worker pods
and snapshots idle actors to object storage. This directory is its control plane at **v1.0.0**, with gVisor as the only sandbox class.
`k8s/apps/ate-system-pools/` has the `SandboxConfig` and the `WorkerPool`; they wait for the CRDs installed here
(`app-ate-system` and `app-ate-system-pools` in `k8s/clusters/homelab/app-ate-system.yaml`).

| Where | What |
|---|---|
| `rendered/` | Upstream's install manifests (`manifests/ate-install/` at the tag), CRDs and RBAC, and the Kubernetes credential provider. Generated: see below. |
| `kustomization.yaml` | The patches that make them fit this cluster (S3 instead of GCS, no GKE credential provider, the router's client allowlist, PodSecurity labels) |
| `helm-release.yaml`, `helm-repository.yaml` | Garage (S3) for the snapshots, in this namespace and separate from the one Renovate uses |
| `postgres-cluster.yaml` | CloudNativePG database for `ate-api-server` (Substrate's "bring your own database" layout, with password logins) |
| `externalsecrets.yaml` | Passwords and keys generated in `k8s/infra/secret-store/` (`ate-garage-*`, `ate-postgres-*`) and copied here; no value is in Git |
| `configmap.yaml` | What `ate-setup deploy` writes as ConfigMaps at install time: API config, authentication config, API env, OTel config (export off) |
| `networkpolicy.yaml`, `ingress-networkpolicy.yaml` | Cilium egress policies, and the ingress allows upstream's policies lack for Garage and the database |
| `issuer.yaml`, `certificate.yaml`, `rbac.yaml`, `secretstore.yaml`, `externalsecrets-pools.yaml` | The CA and JWT key pools: cert-manager makes the keys, External Secrets builds the pool Secrets Substrate reads (see below) |

## The key pools

Substrate keeps its CAs (pod identity, service DNS, Postgres, actor identity, egress MITM) and the actor JWT signing key in pool Secrets in its
own format. `ate-setup` would generate them once and never renew them; here:

1. cert-manager issues each as a CA `Certificate` (`certificate.yaml`): five years, renewed a year early, `rotationPolicy: Never` so a renewal
   keeps the key and only issues a new certificate. The JWT key is a `Certificate` too; only its key is used.
2. An `ExternalSecret` per pool (`externalsecrets-pools.yaml`) reads that Secret through a namespaced `SecretStore` and writes the pool: a JSON
   document with the key and the root certificate as base64 DER, which is the body of the PEM files cert-manager gives. The format is
   `localca.Marshal` and `localjwtauthority.Marshal` in the Substrate sources.

Things to know:

- A pool is **rebuilt from the cert-manager Secret every hour** (`refreshInterval`). Do not edit one by hand, and rotate the JWT key through cert-manager
  (delete the `actor-id-jwt-source` Secret and cert-manager issues a new key, which becomes the only key in the pool; tokens signed by the old one stop verifying). Substrate's
  `kubectl ate admin add-jwt-key` rotation, which keeps the old key published for a day, does not survive the next refresh.
- A renewed CA certificate reaches the pods through the mounted Secret. The JWT pool is reread by the pods within a minute; whether the
  other pools are reread without a restart is not confirmed, so restart `podcertificate-controller` and the Substrate pods after a CA renewal.
- The JWT authority id is the fixed `"1"`; the installer uses the key's thumbprint. Nothing in the code requires that.
- The Secrets are created in `ate-system` and `podcertificate-controller-system`, which stay empty until cert-manager and External Secrets have run;
  the pods that mount a pool wait in `ContainerCreating` meanwhile.

## Updating to a new release

`rendered/` is generated from a tag, and Renovate ignores it (`k8s/**/rendered/**`), so an update is by hand:

1. In a clone of Substrate at the new tag, take `manifests/ate-install/{ate-api-server,ate-controller,ate-idp-server,atelet,atenet-router,atenet-egress,pod-certificate-controller,ate-system-networkpolicies,sandboxconfig-validation}.yaml`,
   `manifests/egress-credential-injection/{k8s-credential-provider,namespace-policy}.yaml`, and `manifests/ate-install/generated/*.yaml` (CRDs to `rendered/crds/`).
2. Replace each `ko://go.ate.dev/substrate/cmd/<name>` image with `ghcr.io/agent-substrate/substrate/<name>:<tag>@sha256:<digest>` (`crane digest`;
   `credential-provider/kubernetes-secrets` is the image `kubernetes-secrets`), `${ENVOY_DATAPLANE_IMAGE}` with `envoy-dataplane`, and the
   `#ATE_EGRESS_INJECT_FLAGS` marker in `atenet-egress.yaml` with the five `--credential-provider-*` flags that are there now.
3. Update the `workerImage` in `k8s/apps/ate-system-pools/workerpool.yaml` and the `SandboxConfig` there. If the pool format changed, update the templates in `externalsecrets-pools.yaml`.
4. Read the release notes first: CRDs are applied by Flux, which does not delete or migrate what a release removes.

Changing a ConfigMap or Secret here does not restart the pods that read it (`ate-setup` stamps an env hash for that). Restart `ate-api-server`
by hand after editing `configmap.yaml` or after the database passwords change.

## Things to know

- **atelet is privileged in effect**: root, `hostPath` on `/var/lib/ate`, `/var/lib/kubelet/{plugins,device-plugins}` and `/dev`, priority
  `system-cluster-critical`. The worker pods in `ate-workers` run as root with `SYS_ADMIN`, `NET_ADMIN`, `NET_RAW` and no seccomp. Both
  namespaces are PodSecurity `privileged`. gVisor is the boundary between an actor and the node; keep untrusted workloads out of any other use of these nodes.
- **The Kubernetes credential provider can read Secrets cluster-wide** (its ClusterRole), but serves nothing until `namespace-policy.yaml`
  grants an atespace the namespaces it may read (`policies: []` is default-deny). Review each grant.
- **Router clients**: `atenet-router` only accepts clients whose certificate has a SPIFFE ID in `--ingress-allowed-spiffe-ids`. The one set
  is upstream's quickstart example (`ns/ate-system/sa/atenet-client`); add the real clients in `kustomization.yaml`.
- **JWT clients** (`kubectl ate` and the like) authenticate with a Kubernetes service account token. The provider in `configmap.yaml` uses this
  cluster's issuer; its discovery URL may not be reachable from the pod, which only affects those clients. The control plane itself uses pod certificates.
- **Not covered yet**: the microVM class (Cloud Hypervisor; `/dev/kvm` exists on `talos-11a-esj` and `talos-tba-msi`, nested virtualization
  is not confirmed), telemetry export (there is no OTLP collector for it), Prometheus scraping of the Substrate components, and backups of
  the database and of Garage.
