# Prototype: one Claude actor on Agent Substrate

Runs the existing `claude-runner` image (`images/claude-runner/`, the one `claude-rc` uses) as a Substrate actor, in two stages. Everything here is
a Substrate API object, created with `kubectl ate`, not a Kubernetes manifest, so Flux does not manage it. Nothing below has been run: it needs
`k8s/apps/ate-system/` (PR #978) merged and healthy, and `kubectl` with the [`kubectl-ate`](https://github.com/agent-substrate/substrate/tree/v1.0.0/cmd/kubectl-ate)
plugin built from the same tag. `kubectl ate` acts as the `ate-client` service account unless you pass `--token-file`; that account is the
API server's bootstrap owner (`k8s/apps/ate-system/kustomization.yaml`), and minting its token needs rights to create tokens in `ate-system`.

## Before you start

```sh
kubectl -n ate-system get pods                 # everything Running; the key pools are made by cert-manager and External Secrets first
kubectl -n ate-workers get pods                # two worker pods of the gvisor WorkerPool
kubectl ate get workers                        # both listed, with their capacity
```

## Stage 1: does the image run, suspend and resume?

No login and no network. The actor keeps a counter in memory and one in a file, so a resume shows what the snapshot kept.

```sh
kubectl ate create atespace claude
kubectl ate create actor-template -f - <<'YAML'
metadata:
  atespace: claude
  name: claude-lifecycle
workerSelector:
  matchLabels:
    pool: gvisor
containers:
  - name: runner
    image: ghcr.io/cthtrifork/talos-gitops/claude-runner:2.1.325-20261118.22@sha256:3be494831f6ed1bac19aae198ca2076e44cda79d30b0637eb483d0546945d565
    command: ["/bin/bash", "-c"]
    args:
      - |
        n=0
        while true; do
          n=$((n + 1)); echo "$n" > "$HOME/count"
          echo "tick $n (memory) $(cat "$HOME/count") (file) $(claude --version)"
          sleep 5
        done
resources:
  limits:
    cpuMillicores: 1000
    memoryBytes: 2147483648
snapshotConfig:
  preferredFidelity: SNAPSHOT_FIDELITY_MEMORY
YAML
kubectl ate create actor claude-1 -a claude --template claude-lifecycle
kubectl ate resume actor claude-1 -a claude
kubectl ate logs actor claude-1 -a claude          # ticks, with the Claude Code version
kubectl ate suspend actor claude-1 -a claude
kubectl ate resume actor claude-1 -a claude
kubectl ate logs actor claude-1 -a claude          # the count continues instead of restarting at 1
```

What to look at: the template reaches a golden snapshot; the first resume is slower than later ones (the image is large, see below); the count
survives; a resume does not re-pull the image; `kubectl -n ate-workers get pods` still shows two workers, not one per actor. `ghcr.io` must be
reachable from atelet (`k8s/apps/ate-system/networkpolicy.yaml` allows the internet on 443); the image is public.

## Stage 2: `claude remote-control`

Only after stage 1. Two things are unsolved, and this stage exists to find out what they cost:

- **Login.** `claude-rc` is logged in by hand (`kubectl exec -it ... -- claude`) and keeps the login on its PVC. An actor cannot be exec'd into, and
  the login is a credential: whoever supplies it to an actor (as an env value in the template, or a file) puts it in the Substrate database and in every
  snapshot. Check first whether `claude remote-control` accepts anything other than a full claude.ai login.
- **Suspend and resume.** `claude remote-control` holds an outbound connection to claude.ai. Substrate suspends an actor only when asked, and resumes
  it on a request through the router, which an outbound-only actor never receives. Test whether the session reappears at claude.ai/code after a resume.

The actor also needs an egress policy, or the gateway denies everything. Two hosts are what `claude-rc` is allowed
(`k8s/apps/claude-system/networkpolicy.yaml`). WebSocket and CONNECT are blocked unless a `tlsPassthrough` rule matches the host:

```yaml
rules:
  - tlsPassthrough:
      hostnames:
        - api.anthropic.com
        - anthropic.com
```

```sh
kubectl ate create egress-policy claude-1 -a claude -f egress-policy.yaml
```

Use `DISABLE_AUTOUPDATER=1` and `DISABLE_TELEMETRY=1` in the template env, as `claude-rc` does (the update and telemetry hosts are not allowed).

## Things that may go wrong

- The image is large (about 15 admin tools); the first restore on a node has to fetch and unpack it, and each snapshot includes what the actor wrote.
- The actor has no cluster access and no GitHub token: the `gh` wrapper and the git credential helper find nothing at `/etc/github/token`.
- gVisor may not support something Claude Code needs; the logs of the actor are the place to look.
