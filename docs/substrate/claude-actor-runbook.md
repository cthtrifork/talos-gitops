# Runbook: a headless Claude actor on Agent Substrate

Runs the existing `claude-runner` image (`images/claude-runner/`, the one `claude-rc` uses) as a Substrate actor that takes tasks over HTTP: you
`POST` a prompt, the actor runs `claude --print` and returns the answer, and when you are done you suspend it. A suspended actor costs no CPU
or memory; the next request resumes it where it was. This is upstream's `claude-code-multiplex` pattern with a way to send it work.

Everything here is a Substrate API object, created with `kubectl ate`, not a Kubernetes manifest, so Flux does not manage it. **Nothing below
has been run.** It needs `k8s/apps/ate-system/` (PR #978) merged and healthy: run [the checklist](stage1-checklist.md) first. For how this compares with
kagent and with `claude-rc`, see [the overview](overview.md); the kagent route is [Runbook B](kagent-claude-runbook.md).

## What you need

- `kubectl` for this cluster, and the `kubectl-ate` plugin built from the source of the release the charts install (v1.0.1 of the kagent fork, which is what is deployed):
  `git clone --depth 1 --branch v1.0.1 https://github.com/kagent-dev/substrate && cd substrate && go install ./cmd/kubectl-ate`
  (Go 1.27 or newer; the binary lands in `~/go/bin`, which must be on `PATH` for `kubectl ate` to be found).
- Rights to create service account tokens in `ate-system`: without `--token-file`, `kubectl ate` acts as the `ate-client` service account, which is a bootstrap owner of the
  API server (`ateApi.authorization.bootstrapOwners` in `k8s/apps/ate-system/substrate/helm-release.yaml`). `kubectl ate proxy` also needs to create `podcertificaterequests`.
- **Token verification may fail on this cluster.** The API server verifies that service account token against the cluster's issuer, `https://[fdae:41e4:649b:9303::1]:10000`, which pods
  probably cannot reach ([agent-substrate/substrate#3326](https://github.com/agent-substrate/substrate/issues/3326)). If every `kubectl ate` call says `invalid bearer token`, none of this runbook can run until
  that is fixed; Part E of the checklist is the test.
- An Anthropic API key in your shell as `ANTHROPIC_API_KEY`. **Never paste it into a file in the repo or into a chat.**
- `envsubst`, to put it into the template at apply time.

## Before you start

```sh
kubectl -n ate-system get pods            # all Running; the key pools are made by cert-manager and External Secrets first
kubectl -n ate-workers get pods           # two worker pods of the gvisor WorkerPool
kubectl ate get workers                   # both listed, with their capacity
```

## Stage 1: does the image run, suspend and resume?

No key and no network. The actor keeps a counter in memory and one in a file on a durable volume, so a resume shows what the snapshot kept.

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
          n=$((n + 1)); echo "$n" > /workspace/count
          echo "tick $n (memory) $(cat /workspace/count) (file) $(claude --version)"
          sleep 5
        done
    volumeMounts:
      - name: work
        mountPath: /workspace
volumes:
  - name: work
    durableDir: {}
resources:
  limits:
    cpuMillicores: 1000
    memoryBytes: 2147483648
snapshotConfig:
  preferredFidelity: SNAPSHOT_FIDELITY_MEMORY
YAML
kubectl ate create actor lifecycle-1 -a claude --template claude-lifecycle
kubectl ate resume actor lifecycle-1 -a claude
kubectl ate logs actor lifecycle-1 -a claude         # ticks, with the Claude Code version
kubectl ate suspend actor lifecycle-1 -a claude
kubectl ate resume actor lifecycle-1 -a claude
kubectl ate logs actor lifecycle-1 -a claude         # the count continues instead of restarting at 1
```

Look at: the template reaches its golden snapshot; the first resume on a node is slower than later ones (the image is large); both counters
survive; `kubectl -n ate-workers get pods` still shows two workers, not one per actor. atelet needs `ghcr.io` on 443 to pull the image
(`k8s/apps/ate-system/networkpolicy.yaml` allows it; the image is public). If the template never becomes ready, `kubectl ate logs` of the golden actor and
`kubectl -n ate-system logs ds/atelet` are the places to look.

## Stage 2: the headless Claude actor

The template runs a small Python server (the image has `python3`) on port 8080: `GET /readyz` for Substrate's wakeup probe, and `POST /task` with a
prompt as the body. One task runs at a time. It listens on 8080, not 80, because a container whose image user is not root cannot bind a low port.
`/workspace` is a durable volume, so files the agent writes survive suspend and resume. `claude --print` keeps no conversation between calls: each
task is a fresh session that can read what is on disk.

```sh
cat > claude-headless-template.yaml <<'YAML'
metadata:
  atespace: claude
  name: claude-headless
workerSelector:
  matchLabels:
    pool: gvisor
containers:
  - name: claude
    image: ghcr.io/cthtrifork/talos-gitops/claude-runner:2.1.325-20261118.22@sha256:3be494831f6ed1bac19aae198ca2076e44cda79d30b0637eb483d0546945d565
    command: ["python3", "-u", "-c"]
    args:
      - |
        import subprocess, threading
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        lock = threading.Lock()

        class Handler(BaseHTTPRequestHandler):
            def reply(self, code, text):
                data = text.encode()
                self.send_response(code)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if self.path == "/readyz":
                    self.reply(200, "ok\n")
                else:
                    self.reply(404, "not found\n")

            def do_POST(self):
                if self.path != "/task":
                    return self.reply(404, "not found\n")
                prompt = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
                with lock:
                    try:
                        r = subprocess.run(["claude", "--print", prompt], capture_output=True, text=True, timeout=600)
                    except subprocess.TimeoutExpired:
                        return self.reply(504, "timed out after 600s\n")
                self.reply(200 if r.returncode == 0 else 500, r.stdout + r.stderr)

            def log_message(self, fmt, *args):
                print(fmt % args, flush=True)

        ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    env:
      - name: ANTHROPIC_API_KEY
        value: "${ANTHROPIC_API_KEY}"
      - name: DISABLE_AUTOUPDATER
        value: "1"
      - name: DISABLE_TELEMETRY
        value: "1"
    wakeupProbe:
      httpGet:
        path: /readyz
        port: 8080
    volumeMounts:
      - name: work
        mountPath: /workspace
volumes:
  - name: work
    durableDir: {}
resources:
  limits:
    cpuMillicores: 1000
    memoryBytes: 2147483648
snapshotConfig:
  preferredFidelity: SNAPSHOT_FIDELITY_MEMORY
YAML

# only ANTHROPIC_API_KEY is substituted; the rendered file holds the key, so do not keep it
envsubst '${ANTHROPIC_API_KEY}' < claude-headless-template.yaml | kubectl ate create actor-template -f -

cat > egress-policy.yaml <<'YAML'
rules:
  - tlsPassthrough:
      hostnames:
        - api.anthropic.com
YAML
kubectl ate create actor claude-1 -a claude --template claude-headless
kubectl ate create egress-policy claude-1 -a claude -f egress-policy.yaml
```

The key is a plain value in the template, which puts it in Substrate's database and in every snapshot of the actor. That is acceptable for a
prototype and not for anything shared: the way out is having the egress gateway add the key to the request outside the sandbox
(the Kubernetes credential provider is installed; its namespace policy is empty), which needs the gateway to inspect the TLS that
`tlsPassthrough` deliberately does not. The environment variables turn off the auto-updater and telemetry, whose hosts the policy does not allow.

### Use it

```sh
kubectl ate proxy actor claude-1 -a claude 8000:8080        # resumes the actor if it is suspended; leave it running

# in another shell
curl -s localhost:8000/task -d 'Write a haiku about snapshots to /workspace/haiku.txt, then print it.'
curl -s localhost:8000/task -d 'Read /workspace/haiku.txt and translate it to French.'
kubectl ate logs actor claude-1 -a claude                    # the server's request log

kubectl ate suspend actor claude-1 -a claude                 # nothing suspends it automatically
curl -s localhost:8000/task -d 'Is /workspace/haiku.txt still there? Print it.'   # the proxy resumes it
```

The proxy reaches the actor through `atenet-router`, which only accepts clients whose certificate carries an allowed SPIFFE ID
(`ns/ate-system/sa/atenet-client` is set in `atenetRouter.ingressAllowedSPIFFEIDs` in `k8s/apps/ate-system/substrate/helm-release.yaml`). If the proxy is refused, that allowlist is the first thing to check.

### What to look at

- Time of the first request after a suspend versus a warm one: that is the resume plus Claude Code starting. Time the requests with `curl -w '%{time_total}\n'`.
- That `haiku.txt` survives a suspend and resume, and that a second actor from the same template starts faster than the first.
- Whether `claude --print` works under gVisor at all; if a task fails, the response body carries the error.
- That a task whose prompt needs another host (a web fetch) fails: the gateway denies it without a rule.

### When it does not work

- **A request hangs or returns a connection error:** the actor may not be resumed yet, or the wakeup probe is failing; `kubectl ate get actor claude-1 -a claude`
  shows its state, and the logs show whether the server started.
- **`claude` says it cannot reach the API, or a name does not resolve:** egress. A denied host looks like an ordinary DNS failure inside the actor, and
  nothing logs the name. `kubectl ate get egress-policy claude-1 -a claude -o yaml` shows the rules; a change applies within about 5 seconds.
- **Authentication errors from Claude Code:** the key in the template is wrong or empty (the template is immutable: create a new one).
- **Changing anything:** templates are immutable. For a new image or script, create a new template and a new actor, or point a suspended actor at
  the new template with `kubectl ate update actor`.

## Cleaning up

```sh
kubectl ate delete actor claude-1 -a claude
kubectl ate delete actor lifecycle-1 -a claude
kubectl ate delete actor-template claude-headless -a claude
kubectl ate delete actor-template claude-lifecycle -a claude
```

The template with the key is also in the database: delete it when done.

## Not pursued: `claude remote-control` per actor

It needs a claude.ai login that an actor cannot be given interactively (and a login in a template or file would sit in every snapshot), and it holds an
outbound connection that nothing wakes after a suspend. If it is wanted later, the actor needs the `tlsPassthrough` rule for `api.anthropic.com` and
`anthropic.com` (what `claude-rc` is allowed), and the open question is whether the session reappears at claude.ai/code after a resume.

## Known gaps

- The image is large (about 15 admin tools): the first restore on a node has to fetch and unpack it. A trimmed image would help; see `images/claude-runner/`.
- The actor has no cluster access and no GitHub token: the `gh` wrapper and git credential helper find nothing at `/etc/github/token`.
- Nothing suspends an actor on its own: something has to call `kubectl ate suspend` (or the API) when work is done.
- The server runs one task at a time and has no authentication of its own: it relies on the router's client certificate check.
