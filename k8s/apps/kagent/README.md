# kagent (test install)

[kagent](https://kagent.dev) 1.0 on the Agent Substrate install in `k8s/apps/ate-system/`, to try a Claude agent whose conversations suspend between turns. **Nothing here has run.** It is a test
install, and the Substrate side is described in `../ate-system/README.md` ("Ready for kagent").

| Where | What |
|---|---|
| `namespace.yaml` | `kagent`: PodSecurity `privileged` (the worker pool is here, and a Harness can only use a pool in its own namespace), and `ate.dev/api-access` so Substrate's API server admits it |
| `crds/`, `kagent/` | The two HelmReleases (kagent-crds, kagent), pinned by digest, grouped by Renovate. The values are the cluster-specific part |
| `postgres-cluster.yaml`, `externalsecrets.yaml` | kagent's own CloudNativePG database, set up as its installer does, with passwords generated in the cluster store (`k8s/infra/secret-store/`) |
| `networkpolicy.yaml` | Cilium default-deny for kagent's pods and what each needs. The worker pods are not denied (see the comment there) |
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

## What it does not do

- No tools: the chart's tool server runs with cluster-admin on everything, so `kagent-tools` is off. The agent answers from its prompt only.
- No UI exposure and no UI authentication: reach it with `kubectl -n kagent port-forward svc/kagent-ui 8080:8080`.
- Backups of the database; telemetry; the codex harness.
- The worker pods' network policy.

The runbook is `docs/substrate/kagent-claude-runbook.md`; the overview and tradeoffs are `docs/substrate/overview.md`.
