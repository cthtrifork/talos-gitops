# Runbook B (target state): a Claude agent with kagent on Agent Substrate

[kagent](https://kagent.dev) is the agent layer above Substrate. An `Agent` resource, run by a `Harness`, becomes a Substrate actor; each conversation suspends when its turn ends and resumes on whatever worker is free
for the next message. kagent's `claude` harness is the Claude Code binary plus a kagent adapter. Compare [Runbook A](claude-actor-runbook.md), which runs the Claude Code CLI as a bare actor, and the
[overview](overview.md) for the tradeoffs.

**Provenance.** Written from kagent's own repository at v1.0.1 (its Helm chart and values, the CRD schemas, the installer's code in `go/core/pkg/install/plan.go`, and `docs/architecture/`), not from a running
install. **A test install is in PR #978** (`k8s/apps/kagent/` and `k8s/apps/kagent-agents/`); it has not run, and it needs one thing from you: the Anthropic key (Part 1). Things I could not confirm are marked **(unverified)**.

## Part 1. What is installed, and what you add

`k8s/apps/ate-system/` sets Substrate's side ("Ready for kagent" in its README). `k8s/apps/kagent/` installs kagent itself, for testing:

| Piece | Where, and the choice made |
|---|---|
| Namespace `kagent` | One namespace for the control plane, the agents and the worker pool: PodSecurity `privileged` (worker pods need it, and a Harness can only use a pool in its own namespace) and labeled `ate.dev/api-access` |
| Database | Its own CloudNativePG cluster `kagent-db`, set up as kagent's installer does, password logins; passwords generated in the cluster store |
| Charts | `kagent-crds` and `kagent` 1.0.1 as HelmReleases, pinned by digest and grouped by Renovate |
| Values | Anthropic as the default provider (`claude-haiku-5-5`, the cheaper model, for testing), the controller's client certificate on, kagent's endpoints for our Substrate, `global.watchNamespaces: [kagent]` (Roles instead of ClusterRoles), `kagent-tools` **off** (the chart gives it cluster-admin on everything), the codex harness off |
| Worker pool | `kagent-default`, two gVisor workers, created by the chart in `kagent` with the labels kagent selects on, using the fork's worker image |
| Network | Cilium default-deny for kagent's pods plus what each needs; the Substrate egress gateway may call the controller (actors call it back). The worker pods are not denied |
| Agent | `homelab-assistant` in `k8s/apps/kagent-agents/`: the `claude-default` Harness, `default-model-config`, a system prompt, no tools |
| **Anthropic key** | **You add it:** a SOPS file in `k8s/apps/kagent-secrets/`. The steps are in `k8s/apps/kagent/README.md`. Until it exists, `app-kagent-secrets` fails and the controller cannot use its model |

Check before going on:

```sh
kubectl -n flux-system get kustomization app-kagent app-kagent-secrets app-kagent-agents
kubectl -n kagent get helmrelease,pods
kubectl -n kagent get harness                                 # claude-default
kubectl get workerpool -n kagent                              # kagent-default, with kagent.dev/worker-pool-name and -namespace labels
kubectl -n kagent get modelconfig,secret kagent-anthropic     # default-model-config, provider Anthropic
kubectl -n kagent get cluster kagent-db                       # healthy
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
# the agent is applied by Flux from k8s/apps/kagent-agents/agent.yaml
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
- **Egress.** The agent has the same allowlist as the `claude-rc` pod: an `EgressPolicy` `claude-runner-allowlist` (35 hosts, copied from its Cilium policy; CI fails if they differ) referenced from the agent's
  `egressPolicyRefs`. kagent adds the model call's host itself. Anything else needs an addition to both policies. If the agent cannot reach a host, `kubectl ate get egress-policy <actor> -a kagent -o yaml`
  shows what was granted. TLS to these hosts is inspected by the gateway (`https` origins), so the actor must trust the gateway's CA, which kagent's templates project into the actor; **(unverified here)**
  that this works with the cert-manager CA of this install.
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

## Cost and your Claude Pro

kagent's Claude harness needs an **Anthropic API key** (a Console account with its own billing, pay per token): its docs list Anthropic, Bedrock and Vertex models, and its gateway injection supports API keys
and rejects OAuth-style credentials. **Your Claude Pro login cannot be used with it.** The test install uses Haiku to keep the spend small; set a spend limit on the key's workspace in the Console. A suspended
agent costs nothing; a turn costs tokens. For Pro-billed Claude, see Stage 3 of [Runbook A](claude-actor-runbook.md).

## What this route does not give you

The Claude Code CLI as you use it in `claude-rc`: no claude.ai/code session, no subscription login, and kagent decides how the CLI is invoked. For those, keep `claude-rc` or use Runbook A.
