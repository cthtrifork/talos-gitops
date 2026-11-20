# kagent (test install)

[kagent](https://kagent.dev) 1.0 on the Agent Substrate install in `k8s/apps/ate-system/`, to try a Claude agent whose conversations suspend between turns. **Nothing here has run.** It is a test
install, and the Substrate side is described in `../ate-system/README.md` ("Ready for kagent").

| Where | What |
|---|---|
| `namespace.yaml` | `kagent`: PodSecurity `privileged` (the worker pool is here, and a Harness can only use a pool in its own namespace), and `ate.dev/api-access` so Substrate's API server admits it |
| `crds/`, `kagent/` | The two HelmReleases (kagent-crds, kagent), pinned by digest, grouped by Renovate. The values are the cluster-specific part |
| `postgres-cluster.yaml`, `externalsecrets.yaml` | kagent's own CloudNativePG database, set up as its installer does, with passwords generated in the cluster store (`k8s/infra/secret-store/`) |
| `networkpolicy.yaml` | Cilium default-deny for kagent's pods and what each needs. The worker pods have a deny of their own (`kagent-workers`) |
| `../kagent-agents/` | The test agent, in its own Flux Kustomization because its CRDs come from the chart |
| `../kagent-secrets/` | **You add this:** the Anthropic key as a SOPS file |

## What you have to do: the Anthropic key

kagent's chart only references a Secret named `kagent-anthropic` with the key `ANTHROPIC_API_KEY`; nothing in Git holds the value, and I cannot create it for you. In your own shell
(never in a chat or a file in the repo you do not encrypt):

```sh
mkdir -p k8s/apps/kagent-secrets
read -rs ANTHROPIC_API_KEY && export ANTHROPIC_API_KEY       # type or paste the key, then Enter
kubectl create secret generic kagent-anthropic -n kagent --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml > k8s/apps/kagent-secrets/kagent-anthropic.enc.yaml
sops --encrypt --in-place k8s/apps/kagent-secrets/kagent-anthropic.enc.yaml    # the age recipient of .sops.yaml
grep -q '^sops:' k8s/apps/kagent-secrets/kagent-anthropic.enc.yaml && echo encrypted
unset ANTHROPIC_API_KEY
git add k8s/apps/kagent-secrets && git commit -m "feat(kagent): add the Anthropic key"
```

Until the file is committed, `app-kagent-secrets` fails on a missing path and the kagent controller cannot start its model (`CreateContainerConfigError` or a model error); the rest is applied.
`k8s/apps/kagent-secrets/` has no `kustomization.yaml`, so Flux generates one and the repo's CI skips it.

## Tools, and GitHub access

The Claude harness runs the real Claude Code with its Bash tool on and its permission prompts off, inside the Substrate sandbox, so an agent can run any command that exists in its image. The default harness image has
`bash`, `git` and `ripgrep` only. `images/claude-runner/Dockerfile` (target `kagent-harness`) builds one with `kubectl`, `kustomize`, `helm`, `flux`, `yq`, `kubeconform`, `crane`, `actionlint`, `shellcheck`, `yamllint` and `gh` (the versions and checksum
checks of the claude-runner image; no cluster access, so no `talosctl`), on top of kagent's `claude-harness` of the same release.

**Not wired yet.** A Harness points at an image by digest, which only exists after CI has built it from `main`. After the merge: (1) wait for the "Build and release the kagent Claude harness image" run and make the
package public in the repository's package settings (a new ghcr package is private, and atelet pulls it anonymously, as it does `claude-runner`); (2) in a follow-up pull request add this Harness and point the Agent at it:

```yaml
apiVersion: api.kagent.dev/v1alpha3
kind: Harness
metadata:
  name: claude-tools
  namespace: kagent
spec:
  claude: {}
  substrate:
    workerPoolRef:
      name: kagent-default
    snapshotPolicy:
      location: s3://ate-snapshots/kagent/
  workload:
    image: ghcr.io/cthtrifork/talos-gitops/kagent-claude-harness:<tag>@sha256:<digest>   # from the release; no command: the image keeps kagent's entrypoint (unverified that this is accepted)
  env:
    - name: GH_TOKEN
      value: kagent-credential-injected   # gh sends this as its Authorization header; the gateway replaces it
```

and set the Agent's `harnessRef.name` to `claude-tools`.

**GitHub.** The agents use claude-rc's GitHub credential without holding it: `k8s/apps/claude-system/pushsecret.yaml` copies the short-lived installation token into the cluster store,
`externalsecrets.yaml` here shapes it (`token`, and `basic` for git), and `../kagent-agents/egresspolicy.yaml` has the Substrate egress gateway replace the `Authorization` header on `github.com` (Basic) and `api.github.com` (Bearer)
with it. git and `gh` in the tools image send a placeholder header for the gateway to replace. **That token is the GitHub App's full grant on its repositories, write access included**: the actor cannot read or leak the
token, but anything the agent can be talked into doing with it, such as a push or a pull request, it can do. The agent's prompt says not to, which is not a control; a read-only token is the narrower choice.

## What it does not do

- Sub-agent: `network-assistant` (`k8s/apps/kagent-agents/agenttemplate.yaml`) is a Shared sub-agent tool of `homelab-assistant`: it runs inside the parent's sandbox and egress, queries Prometheus for Cilium drops and alerts (`egresspolicy-prometheus.yaml`) and drafts policy changes as diffs. The egress gateway matches the origin only, so the parent can call every Prometheus API path. The sub-agent mechanism that gives an agent its own sandbox and harness (`agentRef`) is not served by kagent 1.0.1 yet.
- No MCP tools: the chart's tool server runs with cluster-admin on everything, so `kagent-tools` is off. Command-line tools come from the image above, once the follow-up lands.
- The UI has no authentication of its own. It is published through the Omni service exposer (annotations on the `kagent-ui` Service, port 50098, prefix `kagent`), so the Omni login is the only gate, and the `kagent-ui` NetworkPolicy lets in the host network only. `kubectl -n kagent port-forward svc/kagent-ui 8080:8080` still works with the debug tier. Anyone who can open it can run the agents, which spend API money and can use the injected GitHub credential: keep Omni access narrow. Substrate itself has no UI.
- Backups of the database; telemetry; the codex harness.
- Verification of the worker pods' network policy (`kagent-workers`, and `ate-workers-lockdown` in `k8s/apps/ate-system-pools/`): ports come from the worker's sources, nothing has run, so the first actor is the test. Look for drops from the workers (skill `cilium-drops`).

The runbook is `docs/substrate/kagent-claude-runbook.md`; the overview and tradeoffs are `docs/substrate/overview.md`.
