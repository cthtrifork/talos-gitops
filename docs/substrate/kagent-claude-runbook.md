# Runbook B (target state): a Claude agent with kagent on Agent Substrate

[kagent](https://kagent.dev) is the agent layer above Substrate. An `Agent` resource, run by a `Harness`, becomes a Substrate actor; each conversation suspends when its turn ends and resumes on whatever worker is free
for the next message. kagent's `claude` harness is the Claude Code binary plus a kagent adapter. Compare [Runbook A](claude-actor-runbook.md), which runs the Claude Code CLI as a bare actor, and the
[overview](overview.md) for the tradeoffs.

**Provenance.** Written from kagent's own repository at v1.0.1 (its Helm chart and values, the CRD schemas, the installer's code in `go/core/pkg/install/plan.go`, and `docs/architecture/`), not from a running
install. **kagent is not installed by any PR yet**, so "Part 1" below is work to do, not a state to check. Things I could not confirm are marked **(unverified)**.

## Part 1. What has to exist first (not in any PR)

Substrate's side is done in `k8s/apps/ate-system/` ("Ready for kagent" in its README): the preview gates, kagent's controller as a bootstrap owner and router client, and a credential grant for the `kagent` atespace.
What is missing is kagent itself. A `k8s/apps/kagent/` app would need:

| Piece | Detail |
|---|---|
| Namespace `kagent` | Label `ate.dev/api-access: "true"`: Substrate's ingress policy admits API clients only from labeled namespaces. PodSecurity `privileged` too, if the chart creates the worker pool there |
| Anthropic key | A Secret `kagent-anthropic` with key `ANTHROPIC_API_KEY`, made outside Git and outside any chat (an ExternalSecret from the cluster store, or SOPS). It is read by the controller, not by the agent |
| A database for kagent | Its chart expects two connection-string Secrets (`kagent-postgres-owner`, `kagent-postgres-readwrite`, roles `kagent_owner` and `kagent_readwrite`, schema `kagent`). Either a second database in `substrate-db` or a separate CloudNativePG cluster; a design choice, not made |
| `HelmRelease`s | `kagent-crds` and `kagent` from `oci://ghcr.io/kagent-dev/kagent/helm/`, version 1.0.1. The installer sets the values below |
| Cilium policy | The namespace follows this repo's default-deny: egress to `api.ate-system.svc:443`, the router, the database, DNS and the API server |
| The worker pool | In the **agent's namespace**: kagent resolves `workerPoolRef` there, so the pool in `ate-workers` is not used. The chart can create it (`substrateWorkerPool.create`), with the two placement labels kagent selects on |

Values, taken from what kagent's own installer sets, with this cluster's names **(the chart's value names are verified; that they are sufficient is not)**:

```yaml
providers:
  default: anthropic
  anthropic:
    model: claude-sonnet-5-5
    apiKeySecretRef: kagent-anthropic
    apiKeySecretKey: ANTHROPIC_API_KEY
controller:
  substrateClientCertificate:
    enabled: true            # mTLS to the API server and the router, with the pod-identity certificate
config:
  substrate:
    apiEndpoint: dns:///api.ate-system.svc:443
    routerUrl: https://atenet-router.ate-system.svc:443
    actorJwtIssuer: https://idp.ate-system.svc      # the substrate chart's default
substrateWorkerPool:
  create: true               # in the kagent namespace
  name: kagent-default
  replicas: 2
  sandboxClass: gvisor
  workerImage: ghcr.io/kagent-dev/substrate/ateworker-gvisor:v1.0.1@sha256:97ca74cd2cabc3fd28ac67790ed3b1f25b7b4247709a316ff374a428822c420e
harnesses:
  enabled: true              # renders kagent-default, codex-default and claude-default
  snapshotLocation: s3://ate-snapshots/kagent/     # Garage's bucket; needs the PerTemplateSnapshotLocation gate, which is set
  codex:
    enabled: false           # not needed
```

The rendered `claude-default` Harness, from the chart's template, is:

```yaml
apiVersion: api.kagent.dev/v1alpha3
kind: Harness
metadata:
  name: claude-default
  namespace: kagent
spec:
  claude: {}
  substrate:
    workerPoolRef:
      name: kagent-default
    snapshotPolicy:
      location: s3://ate-snapshots/kagent/
```

Check before going on:

```sh
kubectl -n kagent get pods                                    # controller, UI, database client, tool server
kubectl -n kagent get harness                                 # claude-default
kubectl get workerpool -n kagent                              # kagent-default, with kagent.dev/worker-pool-name and -namespace labels
kubectl -n kagent get modelconfig                             # default-model-config, provider Anthropic
kubectl -n kagent get secret kagent-anthropic
```

## Part 2. A Claude agent

A `ModelConfig` is made by the chart from `providers.default` (named `default-model-config`). The agent references it and the harness:

```yaml
apiVersion: api.kagent.dev/v1alpha3
kind: Agent
metadata:
  name: homelab-assistant
  namespace: kagent
spec:
  template:
    inline:
      modelConfig:
        name: default-model-config
      systemPrompt: |
        You are a Kubernetes assistant running in a sandbox. You have no cluster access of your own;
        answer from what you are told, and say when you would need a tool you do not have.
  harnessRef:
    name: claude-default
```

Held back on purpose: no tools. kagent's tool server runs with whatever RBAC its chart gives it, so give an agent cluster tools only after reading that. The `claude` harness takes HTTP and SSE MCP servers, skills and shared
subagents **(from kagent's docs; not tried)**.

Being a declarative object, the agent can live in Git and be applied by Flux. That is the main thing this route gives over Runbook A.

## Part 3. Run it

```sh
kubectl apply -f agent.yaml                                   # or commit it to the kagent app directory
kubectl -n kagent get agent homelab-assistant                 # status: Ready, and workloadImage is the claude-harness image
kubectl -n kagent get actortemplates.ate.dev                  # kagent turns the agent revision into an ActorTemplate; the golden snapshot takes a minute or two
kubectl ate get actors                                        # none until a session starts

kagent agent session create --agent homelab-assistant -n kagent     # the CLI, from kagent's docs
kubectl -n kagent port-forward svc/kagent-ui 8080:8080              # or the UI at http://localhost:8080
```

In the UI, ask: *What are you, and where are you running?* then *What did I just ask you?* Then:

- Between turns the session's actor should be **SUSPENDED** (`kubectl ate get actors`, or the UI's Substrate view) and the workers idle. The next message resumes it.
- The second question tests memory: it should know the first. That is what a bare actor with `claude --print` cannot do.
- Open three sessions. With two workers, at most two actors are `RUNNING` at once; a third waits for a free worker.

## What to look at

- **Resume time** after a suspend, against a warm turn.
- **Where the key lives.** kagent compiles the model's API key into a destination-scoped binding; the actor gets an inert placeholder, and Substrate's egress gateway swaps in the real key (header `x-api-key` for Anthropic), reading
  it from the Secret through the credential provider. The key should be in no environment variable of the actor: check `kubectl ate get actor-template <name> -a kagent -o yaml` for it. A rotated Secret reaches the gateway
  within about five minutes, without restarting the agent.
- **Egress.** kagent compiles the model call's egress (for `api.anthropic.com`) into the agent's policy; if the agent cannot reach the API, `kubectl ate get egress-policy <actor> -a kagent -o yaml` shows what was granted.
  Anything else the agent should reach needs an `EgressPolicy` (`api.kagent.dev/v1alpha3`) referenced from `spec.egressPolicyRefs`. TLS to the model is inspected by the gateway, so the actor must trust the gateway's CA,
  which kagent's templates project into the actor; **(unverified here)** that this works with the cert-manager CA of this install.
- **History** is described as readable without waking the sandbox, with checkpoints and forks: try them from the UI.

## When it does not work

| Symptom | Likely cause |
|---|---|
| kagent controller crash-loops | Substrate not ready, or the database Secrets missing; check `ate-system` first |
| `PermissionDenied` naming `spiffe://cluster.local/ns/kagent/sa/kagent-controller` | The controller's identity is not a bootstrap owner: `ateApi.authorization.bootstrapOwners` in `k8s/apps/ate-system/substrate/helm-release.yaml` |
| The agent is never Ready, `WorkerPoolNotFound` | The pool is not in the agent's namespace, or lacks `kagent.dev/worker-pool-name` and `kagent.dev/worker-pool-namespace` |
| `Compatible=False`, `RevisionInvalid` | The pool's sandbox class has no matching `SandboxConfig` (`gvisor-default` from the substrate chart) |
| `RuntimePreparationFailed` or `ActorTemplateRetrying` | Substrate rejected the template; check the preview gates on the API server and atelet, and `kubectl -n ate-system logs ds/atelet` for an image pull |
| Connection timeout to the API server | `kagent` lacks `ate.dev/api-access: "true"`, or its own egress policy blocks `api.ate-system.svc:443` |
| `Unauthenticated` from the API server | The controller's pod certificate is not mounted (`substrateClientCertificate.enabled`) |
| `CreateContainerConfigError` on the controller | The `kagent-anthropic` Secret is missing or has no `ANTHROPIC_API_KEY` key |
| A session stays "ready" with its task "working" | The harness process died ([kagent#3436](https://github.com/kagent-dev/kagent/issues/3436)) |
| A name does not resolve inside the agent | Egress: a denied host looks like a DNS failure |

## Cleanup

```sh
kubectl -n kagent delete agent homelab-assistant
```

If the agent is in Git, remove it there instead: Flux prunes it.

## What this route does not give you

The Claude Code CLI as you use it in `claude-rc`: no claude.ai/code session, no subscription login, and kagent decides how the CLI is invoked. For those, keep `claude-rc` or use Runbook A.
