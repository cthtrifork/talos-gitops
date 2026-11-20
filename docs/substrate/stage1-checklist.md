# Checklist: after PR #978 merges

Is the install healthy, and does an actor suspend and resume on these nodes? Run it top to bottom and stop at the first failure: each step depends on the one before. Nothing here has run yet, so the
"expect" lines are what the manifests and docs say should happen, not what was seen. Record what you see in the table at the end.

Commands are read-only except Part F, which creates an atespace, a template and an actor with `kubectl ate`.

## A. Delivery

- [ ] Flux applied everything:
  ```sh
  kubectl -n flux-system get kustomization app-ate-system app-ate-system-pools
  kubectl -n ate-system get helmrelease        # garage, substrate-crds, substrate-podcert, substrate-atelet, substrate
  ```
  Expect: all `Ready=True`. The four Substrate releases install in order, so `substrate` is last. Failure: `kubectl -n ate-system describe helmrelease <name>`.
- [ ] No alerts firing (skill `cluster-alerts`), and no new drops for `ate-system`, `ate-workers` or `podcertificate-controller-system` (skill `cilium-drops`; `scripts/claude-drops.sh`).
  Expect: some drops on the first start are normal; a steady stream is a missing egress allow in `k8s/apps/ate-system/networkpolicy.yaml`.

## B. Secrets and identity

- [ ] cert-manager made the keys:
  ```sh
  kubectl -n ate-system get certificate                              # actor-id-ca, egress-mitm-ca, actor-id-jwt
  kubectl -n podcertificate-controller-system get certificate        # service-dns-ca, pod-identity-ca, postgres-ca
  ```
  Expect: all `READY=True`.
- [ ] External Secrets built what Substrate reads:
  ```sh
  kubectl get externalsecret -n ate-system
  kubectl get externalsecret -n podcertificate-controller-system
  kubectl -n ate-system get secret actor-id-ca-pool actor-id-jwt-pool actor-id-ca-certs egress-mitm-ca-pool \
    substrate-postgres-owner substrate-postgres-readwrite garage-aws-credentials garage-s3-key
  ```
  Expect: every ExternalSecret `SecretSynced`, every Secret present. Failure with `SecretSyncedError`: the store or its RBAC (`secretstore.yaml`, `rbac.yaml`), or the generator in `k8s/infra/secret-store/`.
- [ ] The pod certificate controller is up and publishing trust:
  ```sh
  kubectl -n podcertificate-controller-system get pods
  kubectl get clustertrustbundles
  ```
  Expect: one Running pod, and trust bundles for the pod-identity and service-DNS signers. **Open question:** whether the controller accepts the pool JSON that External Secrets builds; its logs say
  (`kubectl -n podcertificate-controller-system logs deploy/podcertificate-controller`). A parse error here is the first place the pool template could be wrong.

## C. State

- [ ] Database:
  ```sh
  kubectl -n ate-system get cluster substrate-db
  kubectl -n ate-system get cluster substrate-db -o jsonpath='{.status.managedRolesStatus}{"\n"}'
  ```
  Expect: `Cluster in healthy state`, and both login roles `reconciled`. The NOLOGIN roles and the `substrate` schema come from `postInitApplicationSQL` and cannot be read without a shell: the API
  server's first start (Part D) is the test, because its migrations fail if the schema or grants are wrong.
- [ ] Garage:
  ```sh
  kubectl -n ate-system get pods -l app.kubernetes.io/name=garage
  kubectl -n ate-system get job garage-configure
  ```
  Expect: one Running pod; the configure job `Complete` (it creates the bucket `ate-snapshots` and the key). It is deleted after five minutes: its absence later is normal.

## D. Substrate

- [ ] Pods:
  ```sh
  kubectl -n ate-system get pods -o wide
  ```
  Expect Running: `ate-api-server`, `ate-controller`, `ate-idp-server`, `atenet-router`, `atenet-egress`, `k8s-credential-provider`, and `atelet` on `talos-11a-esj` and `talos-tba-msi` only
  (`talos-2ny-8tx` is tainted). A pod stuck in `ContainerCreating` is usually a missing Secret from Part B.
- [ ] The API server started clean:
  ```sh
  kubectl -n ate-system logs deploy/ate-api-server -c ate-api-server | head -50
  ```
  Expect: migrations applied, "Configured JWT provider" for `kubernetes`, a listening gRPC server, no crash loop. A database error means Part C's schema or login is wrong; an OpenFGA or authz error
  means `--authz-bootstrap-owners` (in the chart values) is empty or malformed.
- [ ] The hardening did not break the gateways:
  ```sh
  kubectl -n ate-system get pods -l 'app in (atenet-router,atenet-egress)'
  kubectl -n ate-system logs deploy/atenet-router | tail -20
  ```
  Expect: Running and Ready. These containers got `allowPrivilegeEscalation: false`, all capabilities dropped, a seccomp profile and a liveness probe from `postRenderers`, untested.
  If one crash-loops, remove the `securityContext` patch for it in `substrate/helm-release.yaml` first.
- [ ] Workers:
  ```sh
  kubectl get workerpool -A
  kubectl -n ate-workers get pods
  kubectl get sandboxconfig
  ```
  Expect: `gvisor` pool with two workers Running, and a `gvisor-default` SandboxConfig. Failure: `kubectl -n ate-workers describe pod` (PodSecurity, image pull from `ghcr.io/kagent-dev/substrate`,
  the node's `/dev`), then atelet's logs: `kubectl -n ate-system logs ds/atelet -c atelet`, which also show whether it could fetch the gVisor bundle from `gs://gvisor`.

## E. Client access

- [ ] Build the plugin, then ask the API something:
  ```sh
  git clone --depth 1 --branch v1.0.1 https://github.com/kagent-dev/substrate && cd substrate && go install ./cmd/kubectl-ate    # Go 1.27+; ~/go/bin on PATH
  kubectl ate get workers
  kubectl ate get atespaces
  ```
  Expect: the two workers listed. **Likely failure on this cluster:** `Unauthenticated: invalid bearer token`. `kubectl ate` presents a service account token, and the API server verifies it against the issuer
  `https://[fdae:41e4:649b:9303::1]:10000`, which pods probably cannot reach ([#3326](https://github.com/agent-substrate/substrate/issues/3326)). Check the API server's logs for the discovery error.
  If so, nothing in Part F can run through `kubectl ate` until the cluster's `service-account-issuer` is reachable from pods; record it and stop. Everything in Parts A to D is still valid, and kagent
  authenticates with pod certificates, so it is not blocked by this.

## F. Stage 1: suspend and resume

Only if Part E worked. The commands are in [`claude-actor-runbook.md`](claude-actor-runbook.md), "Stage 1". In short: create the atespace, the `claude-lifecycle` template and an actor,
resume it, read its logs, suspend, resume, read its logs again.

- [ ] The template reaches its golden snapshot (`kubectl ate get actor-template claude-lifecycle -a claude`). Expect: a minute or two; the image is large.
- [ ] The first resume runs: the logs show ticks and the Claude Code version.
- [ ] After a suspend and resume the **memory** counter and the **file** counter both continue instead of restarting at 1.
- [ ] `kubectl -n ate-workers get pods` still shows two workers, not one per actor.
- [ ] A second actor from the same template resumes faster than the first.
- [ ] Time a resume: `time kubectl ate resume actor lifecycle-1 -a claude`.

Failures: template never ready → atelet's logs and `kubectl ate get actor-template -o yaml`; resume hangs → `kubectl -n ate-system logs ds/atelet` for the restore, and Garage (`kubectl -n ate-system logs statefulset/garage`);
counters restart at 1 → the snapshot fidelity or the volume mount in the template.

## Record

| Check | Result | Notes |
|---|---|---|
| A. Delivery | | |
| B. Secrets, identity (pool parse) | | |
| C. Database, Garage | | |
| D. Pods, API server, gateways, workers | | |
| E. `kubectl ate` auth | | |
| F. Counters survive suspend and resume | | |
| Resume time, first / second / warm | | |
| First image pull on a node | | |

Then: if A to D pass, kagent can be added (Runbook B). If F passes, Runbook A stage 2 can run. If E fails, the issuer is the next thing to fix, in `patches/`, not in this PR.
