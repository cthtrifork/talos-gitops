# Runbook (target state): a Claude agent with kagent on Agent Substrate

> **Superseded in part.** Written before the kagent 1.0 sources were read. kagent 1.0 uses `api.kagent.dev/v1alpha3` (`Agent`, `Harness`, `EgressPolicy`),
> not the `kagent.dev/v1alpha2` `SandboxAgent` shown below, which is from the 0.10 walkthrough. It also has a Claude harness (`claude-default`, the Claude
> Code binary plus a kagent adapter), holds the Anthropic key at the Substrate gateway, and requires Substrate settings this repo does not set yet
> (preview gates, the controller as a bootstrap owner and router client, a credential-provider grant, a pool in the agent's namespace). Treat the
> assumptions, the failure table and the comparison as a sketch, and the YAML as wrong, until this is rewritten from the kagent 1.0 charts.

[kagent](https://kagent.dev) is the agent layer above Substrate: a `SandboxAgent` resource becomes a Substrate actor, every conversation suspends
when its turn ends, and the next message resumes it on whatever worker is free. This runbook is for the state where kagent is installed next to
`k8s/apps/ate-system/` and runs a Claude-backed agent. Compare `docs/agent-substrate-claude-actor.md`, which runs the Claude Code CLI as a bare actor
with no kagent.

**Provenance.** Written from two pages, not from a running install: the kagent walkthrough
[Deploy kagent with Agent Substrate](https://kagent.dev/blog/deploy-kagent-with-agent-substrate), which is pinned to Substrate 0.0.8 and kagent 0.10.0-beta6,
and the [kagent 1.0 announcement](https://www.solo.io/blog/announcing-kagent-1-0-ga). Field names marked **(unverified)** are from the older guide or from
memory and must be checked against the kagent 1.0 docs and CRDs before use. **Nothing here has run, and kagent is not installed by any PR yet.**

## What is assumed

| Assumption | Why it matters | Check |
|---|---|---|
| Substrate v1.0.0 from `k8s/apps/ate-system/` is healthy (PR #978 merged) | kagent drives it through the API server | `kubectl -n ate-system get pods`, `kubectl -n ate-workers get pods` |
| kagent 1.0 is installed in `kagent`, by a Flux `HelmRelease` (the announcement says the Helm charts are the route for GitOps) | The walkthrough's `kagent install` CLI also installs its own Substrate and PostgreSQL; here Substrate is ours | `kubectl -n kagent get pods`, `kubectl get helmrelease -A` |
| kagent is pointed at **our** Substrate and worker pool, not the one its chart can create | One control plane, one pool | values below |
| The Anthropic API key is a Secret in `kagent`, created outside Git | The key is never in a manifest or a chat | `kubectl -n kagent get secret kagent-anthropic` |
| Substrate has authorized the kagent controller | `ate-api-server` authorizes every call; only `ate-client` is a bootstrap owner today | see "What Substrate must allow" |

Pairing matters. The walkthrough says Substrate 0.0.9 broke the wire format that kagent 0.10.0-beta6 uses, and that the two must be bumped
together. This repo runs upstream Substrate **v1.0.0** from `ghcr.io/agent-substrate/substrate`, whereas the walkthrough uses kagent's own charts and
images (`ghcr.io/kagent-dev/substrate`). Before installing, confirm which Substrate release the kagent 1.0 chart targets, and whether the chart expects
its own packaging. If it only works with its own charts, the choice is between swapping them in for `k8s/apps/ate-system/rendered/` and not using kagent.

## What kagent needs configured (HelmRelease values)

From the walkthrough's Helm flags, with this cluster's names. **(unverified for 1.0)**

```yaml
providers:
  default: anthropic                      # check the chart for the Anthropic provider key and the Secret it reads
controller:
  substrate:
    enabled: true
    ateApiEndpoint: dns:///api.ate-system.svc:443
    atenetRouterURL: http://atenet-router.ate-system.svc:80   # check the router Service's real port in rendered/atenet-router.yaml
    ateApiTokenFile: /var/run/secrets/tokens/ate-api/token
    defaultWorkerPool:
      namespace: ate-workers
      name: gvisor
substrateWorkerPool:
  create: false                           # use our pool: k8s/apps/ate-system-pools/workerpool.yaml
```

Do not put the API key in the values: use the chart's existing-Secret option. The walkthrough warns that an empty key makes the install "succeed"
and then fail with `CreateContainerConfigError`.

## What Substrate must allow

1. **Authorization.** The controller calls the API with a service account token (audience `api.ate-system.svc`). Its principal is
   `system:serviceaccount:kagent:kagent-controller`. Either add it to `--authz-bootstrap-owners` in `k8s/apps/ate-system/kustomization.yaml`, or, better, give it a role
   in an access policy (`kubectl ate create access-policy`, see Substrate's `docs/guides/authorization.md`). A denied call names the principal with `:` encoded as `%3A`.
2. **Authentication.** The token's issuer must be trusted: `ate-api-authentication` in `k8s/apps/ate-system/configmap.yaml` trusts this cluster's service account
   issuer `https://[fdae:41e4:649b:9303::1]:10000`, and the API server fetches that issuer's keys when it verifies a token. That address has never been
   tested from a pod: if the controller gets `Unauthenticated`, this is the first thing to check.
3. **Network.** `ate-system`'s ingress policy admits API clients only from namespaces labeled `ate.dev/api-access: "true"`, so label `kagent`.
   kagent's own egress needs `api.ate-system.svc:443` and the router, and the model provider's host.
4. **Pool.** The pool's namespace is `ate-workers`, which is PodSecurity `privileged`; a pool created by the chart in `kagent` would not be.

## The agent

A Claude model configuration and a declarative agent. Shapes are from the walkthrough's `SandboxAgent` and from kagent's `ModelConfig` as I remember it
**(unverified)**: check both against `kubectl explain` for the installed CRDs.

```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: claude
  namespace: kagent
spec:
  provider: Anthropic
  model: claude-sonnet-5-5
  apiKeySecret: kagent-anthropic
  apiKeySecretKey: ANTHROPIC_API_KEY
---
apiVersion: kagent.dev/v1alpha2
kind: SandboxAgent
metadata:
  name: homelab-assistant
  namespace: kagent
spec:
  type: Declarative
  description: A read-only Kubernetes assistant, running as a Substrate actor
  declarative:
    runtime: go                           # the walkthrough: required for gVisor checkpoint and restore
    modelConfig: claude
    systemMessage: |
      You are a Kubernetes assistant running inside an Agent Substrate gVisor actor.
      Answer questions about the cluster with the tools you have. Keep answers short.
    tools:
      - type: McpServer
        mcpServer:
          name: kagent-tool-server
          kind: RemoteMCPServer
          apiGroup: kagent.dev
          toolNames:
            - k8s_get_resources
            - k8s_describe_resource
            - k8s_get_pod_logs
```

Held back on purpose: the tools are read-only, and that tool server runs with whatever RBAC kagent gives it, so review that before widening it. Being a
declarative object, both resources can live in Git and be applied by Flux, which is the main thing this route gives over the bare-actor runbook.

## Run it

```sh
kubectl apply -f agent.yaml                                  # or commit it to the kagent app directory
kubectl -n kagent wait sandboxagent/homelab-assistant --for=condition=Ready --timeout=5m
kubectl -n kagent get actortemplates.ate.dev                 # kagent projects the agent into an ActorTemplate; the golden snapshot takes ~60-90s
kubectl ate get actors                                       # the session actors (none until the first conversation)

kubectl -n kagent port-forward svc/kagent-ui 8080:8080       # http://localhost:8080 -> Agents -> homelab-assistant
```

In the UI, ask: *What are you and where are you running?* then *List the pods in ate-system.* Then:

- Open the UI's Substrate view, or run `kubectl ate get actors` / `kubectl ate get workers`: between turns the session actor should be **SUSPENDED** and the
  workers idle. The next message resumes it.
- Open three conversations. With two workers, at most two actors are `RUNNING` at once; the third waits for a free worker (the guide notes a worker serves
  one actor at a time, and that overlapping sessions need more workers).
- To add workers: edit `replicas` in `k8s/apps/ate-system-pools/workerpool.yaml`; a manual `kubectl scale` is reverted by Flux.

## What to look at

- **Resume time after a suspend** against a warm turn: the point of the whole stack.
- **Egress from the actor.** The model call goes from the agent inside the sandbox, so it passes the egress gateway, which denies every host without a policy
  for that actor. Whether kagent creates the policy (for the model provider and for the tool server) is not in anything I read. If a turn hangs or fails to
  resolve a name, check `kubectl ate get egress-policy <actor> -a <atespace> -o yaml` first.
- **Where the API key lives.** In the Secret, read by the kagent controller and handed to the agent, which puts it in the actor and its snapshots unless
  the gateway holds it. The announcement describes gateway-held credentials as part of the design (and agentgateway as the gateway in Solo's enterprise
  releases); whether the open-source install does the same is unknown.
- **Conversation history** is described as readable without waking the sandbox, with checkpoints and forks: try them from the UI.

## When it does not work

| Symptom | Likely cause |
|---|---|
| kagent controller crash-loops at start | Substrate not reachable or not ready; fix `ate-system` first (the walkthrough: install Substrate before kagent) |
| `PermissionDenied` naming `user:system%3Aserviceaccount%3Akagent%3Akagent-controller` | The controller is not a bootstrap owner and has no access policy |
| `Unauthenticated` | The issuer in `ate-api-authentication` cannot be reached or does not match the token's issuer |
| Connection timeout to the API | The `kagent` namespace lacks `ate.dev/api-access: "true"`, or kagent's own egress policy blocks it |
| `SandboxAgent` never Ready | Fewer than 2 workers, a pool selector mismatch, or the golden snapshot failing: `kubectl -n kagent describe sandboxagent`, then `kubectl get actortemplates.ate.dev -A` |
| `CreateContainerConfigError` on the agent or controller | The `kagent-anthropic` Secret is missing or empty |
| Chat fails after a version bump | Substrate and kagent versions are out of step (see "Pairing") |

## Cleanup

```sh
kubectl -n kagent delete sandboxagent homelab-assistant
kubectl -n kagent delete modelconfig claude
```

If the agent is in Git, remove it there instead: Flux prunes it.

## Compared with the bare-actor runbook

| | `agent-substrate-claude-actor.md` | this runbook |
|---|---|---|
| What runs | The Claude Code CLI behind a small HTTP server | kagent's Go agent runtime, with Claude as the model |
| Defined by | `kubectl ate` calls, by hand | `SandboxAgent` and `ModelConfig` in Git |
| Sessions and history | None: each task is a fresh `claude --print` | Provided by kagent, with checkpoints and forks |
| Suspend and resume | You call `kubectl ate suspend` | Automatic at the end of each turn |
| Tools | Whatever the image has | MCP servers, declared on the agent |
| Credentials | Plain env value in the template | The model Secret; gateway-held credentials are possible |
| Moving parts | Substrate only | Substrate and kagent, version-paired |
| What you do not get | Anything kagent provides | The Claude Code CLI itself, claude.ai/code and `claude-runner` |

The announcement also says kagent can act as a self-hosted sandbox for Claude Managed Agents (experimental) and can place coding harnesses on Substrate
(an `AgentHarness` resource, with `runtime: substrate`). Neither is covered here; whether Claude Code is one of the supported harnesses is worth checking in the
kagent docs, since that would be the way to run the CLI under kagent.

## Work this assumes (not in any PR)

1. A `k8s/apps/kagent/` app (namespace labeled `ate.dev/api-access`, a `HelmRelease` for the kagent charts, the model Secret, Cilium policies, the agent).
2. The kagent controller as a Substrate principal: a bootstrap owner or an access policy.
3. A check that the service account issuer is reachable from pods for the API server's token verification.
4. The decision on Substrate packaging, above.
