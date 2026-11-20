# Agent Substrate on the homelab: overview and tradeoffs

What is built (PR #978), what each way of running a Claude agent costs and gives, and where to read next. **Nothing has run on the cluster yet**; every claim about behavior
below is from documentation, source code or issue threads, and says which.

| Read | When |
|---|---|
| [`stage1-checklist.md`](stage1-checklist.md) | First, after the PR merges: is the install healthy, and does an actor suspend and resume? |
| [`claude-actor-runbook.md`](claude-actor-runbook.md) | Runbook A: a headless Claude actor on Substrate alone |
| [`kagent-claude-runbook.md`](kagent-claude-runbook.md) | Runbook B: a Claude agent managed by kagent (target state; kagent is not installed) |
| [`../../k8s/apps/ate-system/README.md`](../../k8s/apps/ate-system/README.md) | How the install is put together, how to update it, what to watch |

## What is installed

Substrate from kagent's Helm charts (four HelmReleases, one release of the charts, maintained by Renovate), Garage for snapshots, CloudNativePG for the API server's database, cert-manager
and External Secrets for the CA and JWT key pools, Cilium egress policy, and one gVisor `WorkerPool` of two workers. See the diagram in
[`architecture.svg`](architecture.svg).

| Built in PR #978 | Not built |
|---|---|
| Control plane, data plane (agentgateway), atelet, pod certificate controller | The Anthropic key for kagent: you add it as a SOPS file (`k8s/apps/kagent/README.md`) |
| Garage, CloudNativePG, the key pools, Cilium and ingress policies | A narrow network policy for the worker pods |
| Preview gates, owners, router clients and credential grant that kagent needs | The microVM class, telemetry export, backups |
| A kagent test install: namespace, database, two charts, worker pool, Cilium policy, one test agent with no tools | kagent's tools, UI exposure and authentication |
| A bare-actor test script (`scripts/ate-actor-test.sh`), two runbooks, a checklist, this overview | Any actor actually created: the script and the agent have not run |

## Three ways to run Claude

| | `claude-rc` (today, in `claude-system`) | Runbook A: bare actor | Runbook B: kagent |
|---|---|---|---|
| What runs | `claude remote-control`, one pod | The Claude Code CLI behind a small HTTP server, in a Substrate actor | kagent's Claude harness: the Claude Code binary plus an adapter, in an actor |
| Where you use it | claude.ai/code, your subscription login | `curl` through `kubectl ate proxy` | kagent's UI, CLI, A2A or MCP |
| Many agents | One pod each | Many actors on a few workers | Many agents on a few workers |
| Idle cost | A pod, always | None while suspended | None while suspended |
| Who suspends | n/a (stage 3 `remote`: nothing; it stays up) | You (`kubectl ate suspend`); Substrate has no idle detection ([#483](https://github.com/agent-substrate/substrate/issues/483)) | kagent's controller, after each turn |
| Conversation memory | In the session | None: each `claude --print` is fresh | Durable sessions, checkpoints and forks (kagent docs) |
| Anthropic credential | Your login, on a PVC | An API key in the template: in the database and in every snapshot | Held at the gateway and injected on egress; the actor does not see it (kagent docs) |
| Defined as | A Deployment in Git | `kubectl ate` calls, by hand | `Agent` and `Harness` resources in Git |
| Cluster access | Read-only RBAC, elevation on request | None | None |
| Isolation | Pod, read-only root filesystem | gVisor sandbox | gVisor sandbox |
| Extra moving parts | None | Substrate only | Substrate and kagent (controller, UI, database), version-paired |
| Status | In use | Runbook written, not run | Runbook written from docs, not run; kagent not installed |
| Main risk | One session, one pod | Key in snapshots; you build the watchdog | kagent's maturity; agentgateway's open gaps |

How to choose: a few long-lived sessions you drive by hand → keep `claude-rc` or use Runbook A. Many agents that wake and sleep on their own, with history and a key the actor never holds →
Runbook B. Run the [checklist](stage1-checklist.md) first either way: it is the only thing that tells you whether suspend and resume work on these nodes.

## Who pays for the model

| Agent | How it authenticates | Billing | Costs when |
|---|---|---|---|
| `claude-rc` (running today) | Your claude.ai login | Subscription limits | You use it |
| Runbook A, stage 3: `remote` | A claude.ai login you make for it, stored in the template | **Subscription (Pro)**, shared with everything else on the account | The session is used |
| Runbook A, stage 2: `headless` / `ask` | `ANTHROPIC_API_KEY` in the template | **API, per token** | Each request |
| Runbook A, stage 1: `lifecycle` | None | Free | It runs `claude --version` and a counter |
| Runbook B: kagent `homelab-assistant` | `kagent-anthropic`, injected at the gateway | **API, per token** (Haiku for testing) | Each turn |
| Substrate, Garage, databases | None | None | |

kagent cannot use a subscription; the `remote` actor cannot use the API. Both are untested.

## Decisions already made

| Decision | Chosen | Instead of | Why, and the catch |
|---|---|---|---|
| Install method | kagent's Substrate Helm charts | Upstream's manifests vendored by hand | Upstream ships no chart; kagent 1.0 is tested against these; Renovate can maintain them. Catch: they are a fork's build, and agentgateway-only |
| Data plane | agentgateway (the charts') | Envoy (upstream's default) | Envoy needs the vendored route, which nothing maintains. Catch: see the next table |
| Database | CloudNativePG, password logins, `sslmode=require` | The bundled database with certificate logins | The charts' bundled path needs the project's own installer. Catch: the server certificate is not verified |
| CA and JWT pools | cert-manager plus External Secrets | A script writing SOPS files; an in-cluster Job | No keys in Git, and the CAs renew. Catch: the template is untested against Substrate's parser |
| Snapshot store | A separate Garage | Renovate's Garage; RustFS | Isolation. Catch: one node, no redundancy |
| Sandbox class | gVisor | microVM | `/dev/kvm` exists on two nodes but nested virtualization is unconfirmed |
| kagent namespaces | One privileged `kagent` namespace for everything | A split with a restricted control plane | A Harness can only use a pool in its own namespace; the split needs a shared ModelConfig and another credential grant. Catch: kagent's controller and UI run privileged |
| kagent database | Its own CloudNativePG cluster | A second database in `substrate-db` | Isolation and easy deletion. Catch: another database to look after |
| kagent's model | Haiku (`claude-haiku-5-5`) | Sonnet | Cheaper for a test; the chart's own default is Haiku too |
| Anthropic key for kagent | A SOPS file you add | An ExternalSecret from the cluster store | Your choice. Catch: the key is in Git, encrypted; the install waits for the file |
| kagent tools | Off | The chart's tool server | It runs with cluster-admin on everything. Catch: the test agent has no tools |
| Claude workload | Both runbooks are implemented for testing | One | Run the checklist first |

## Envoy or agentgateway

| | Envoy (upstream's default) | agentgateway (the charts' only option) |
|---|---|---|
| Maintained by | The Substrate project | Solo.io, which also maintains the kagent fork and wrote upstream's agentgateway support |
| In upstream's docs | Default | Supported alternative; upstream's own issues call it "opt-in" |
| Egress policy gaps | | Open: [#2930](https://github.com/agent-substrate/substrate/issues/2930), [#2931](https://github.com/agent-substrate/substrate/issues/2931); the TLS listener in the chart has the pattern of #2931 |
| Router to worker identity check | SPIFFE SAN verified | Chain only, `insecureHost: true` ([#3448](https://github.com/agent-substrate/substrate/issues/3448), P1) |
| CA rotation without restart | Yes | No ([#3445](https://github.com/agent-substrate/substrate/issues/3445)) |
| Custom `ext_proc` hooks | Yes (experimental) | No ([#3259](https://github.com/agent-substrate/substrate/issues/3259)) |
| MCP and A2A awareness | No | Yes: the reason Solo gives for building it |
| Tested with kagent | Not that I know | Yes: kagent's charts and CI |
| Hardening in this PR | n/a | Capabilities dropped, no privilege escalation, seccomp and a liveness probe by `postRenderers`; still root with a writable root filesystem |

Sources: the GitHub issues linked, the fork's commits and sync guide, upstream `main`'s `ate-setup` default, and Solo.io's posts (which argue for agentgateway above Substrate's own Envoy routing, not in place of it).

## Watch list

Open issues that change this install, most important first: [#3326](https://github.com/agent-substrate/substrate/issues/3326) (token verification on Talos: the issuer here is probably unreachable from pods),
[#3448](https://github.com/agent-substrate/substrate/issues/3448), [#3445](https://github.com/agent-substrate/substrate/issues/3445), [#483](https://github.com/agent-substrate/substrate/issues/483) (no idle detection),
[#3885](https://github.com/agent-substrate/substrate/issues/3885) (WebSocket egress, for `claude remote-control`), [#79](https://github.com/agent-substrate/substrate/issues/79) (an upstream Helm chart),
[kagent-dev/substrate#64](https://github.com/kagent-dev/substrate/issues/64) (chart values instead of post-renderers).
