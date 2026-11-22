#!/usr/bin/env bash
# Tests a bare Agent Substrate actor running the claude-runner image (docs/substrate/claude-actor-runbook.md): `lifecycle` checks that an actor suspends and resumes with its
# memory and its files intact; `headless` creates an actor that answers prompts over HTTP with `claude --print` (API billing); `ask` sends it one; `remote` creates an actor that runs
# `claude remote-control` on Sonnet with your claude.ai login (subscription billing; see the warnings at `remote`); `clean` deletes what this script made.
#
# Needs: kubectl, the kubectl-ate plugin (built from the release the charts install), and for `headless` an Anthropic key in the environment (ANTHROPIC_API_KEY, never in this
# file or the repo; it ends up in the template, which is in Substrate's database and in the actor's snapshots) plus envsubst and curl for `ask`.
set -euo pipefail

ATESPACE="${ATESPACE:-claude}"
IMAGE="${IMAGE:-ghcr.io/cthtrifork/talos-gitops/claude-runner:2.1.325-20261118.22@sha256:3be494831f6ed1bac19aae198ca2076e44cda79d30b0637eb483d0546945d565}"
POOL_LABEL="${POOL_LABEL:-pool=gvisor}" # the label of the WorkerPool the template may use (k8s/apps/ate-system-pools/workerpool.yaml)
LIFECYCLE_ACTOR="lifecycle-1"
HEADLESS_ACTOR="claude-1"
REMOTE_ACTOR="claude-remote-1"
REMOTE_NAME="${REMOTE_NAME:-homelab-actor}" # the session name in claude.ai/code
REMOTE_MODEL="${REMOTE_MODEL:-sonnet}"      # a Claude Code model alias or id
LOCAL_PORT="${LOCAL_PORT:-8000}"
# The actors reach the same hosts as the claude-rc pod: its Cilium egress allowlist is read from the repo each time, so the two cannot drift (and CI checks the kagent copy).
ALLOWLIST_FILE="${ALLOWLIST_FILE:-$(dirname "$0")/../k8s/apps/claude-system/networkpolicy.yaml}"

usage() {
  cat <<USAGE
Usage: $0 <command>

  check       list the workers (is the API reachable, and is there capacity?)
  lifecycle   create the atespace, a template and an actor; run it, suspend, resume; compare what survived
  headless    create the template, actor and egress policy of the headless Claude actor (needs ANTHROPIC_API_KEY)
  policy      print the egress policy the headless and remote actors get (the hosts of claude-rc's allowlist)
  ask TEXT    send TEXT to the headless actor through a port-forward, and time the answer
  remote      create an actor that runs 'claude remote-control' on Sonnet with a claude.ai login you made for it
              (needs CLAUDE_CREDENTIALS_FILE: the credentials file of that separate login; it is stored in the template)
  clean       delete the actors and templates this script made

Environment: ATESPACE (default ${ATESPACE}), IMAGE, POOL_LABEL (default ${POOL_LABEL}), LOCAL_PORT (default ${LOCAL_PORT}).
USAGE
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
ate() { kubectl ate "$@"; }
say() { printf '\n== %s\n' "$*"; }

ensure_atespace() {
  ate get atespace "${ATESPACE}" >/dev/null 2>&1 || ate create atespace "${ATESPACE}"
}

ensure_template() { # name, manifest on stdin. Templates are immutable: an existing one is kept.
  local name="$1" manifest
  manifest="$(cat)"
  if ate get actor-template "${name}" -a "${ATESPACE}" >/dev/null 2>&1; then
    echo "template ${name} exists; keeping it (templates are immutable: delete it to change it)"
  else
    printf '%s\n' "${manifest}" | ate create actor-template -f -
  fi
}

ensure_actor() { # actor, template
  ate get actor "$1" -a "${ATESPACE}" >/dev/null 2>&1 || ate create actor "$1" -a "${ATESPACE}" --template "$2"
}

allowlist_hosts() { # the toFQDNs names and patterns of the claude-egress-allowlist policy, lowercase, without the bare "*" of its DNS rule
  [ -r "${ALLOWLIST_FILE}" ] || { echo "cannot read ${ALLOWLIST_FILE}: run this from a clone of talos-gitops, or set ALLOWLIST_FILE" >&2; return 1; }
  awk '
    /^---/ { doc = "" }
    /^  name: / { doc = $2 }
    doc == "claude-egress-allowlist" && /^ +- match(Name|Pattern): / { v = $3; gsub(/"/, "", v); if (v != "*") print tolower(v) }
  ' "${ALLOWLIST_FILE}" | sort -u
}

egress_policy_yaml() { # an EgressPolicy letting the actor reach those hosts on 443 without inspection (tlsPassthrough: no trust bundle needed, WebSocket allowed)
  local hosts
  hosts="$(allowlist_hosts)"
  [ -n "${hosts}" ] || { echo "no hosts found in ${ALLOWLIST_FILE}" >&2; return 1; }
  echo "rules:"
  echo "  - tlsPassthrough:"
  echo "      hostnames:"
  while read -r host; do printf '        - "%s"\n' "${host}"; done <<<"${hosts}"
  echo "      ports:"
  echo "        numbers:"
  echo "          - 443"
}

ensure_egress_policy() { # actor
  ate get egress-policy "$1" -a "${ATESPACE}" >/dev/null 2>&1 || egress_policy_yaml | ate create egress-policy "$1" -a "${ATESPACE}" -f -
}

last_tick() { # the number after the last "tick" in the actor's container output
  ate logs actor "${LIFECYCLE_ACTOR}" -a "${ATESPACE}" -c runner --source containers 2>/dev/null |
    grep -o 'tick [0-9]*' | tail -n 1 | awk '{print $2}'
}

lifecycle_template() {
  cat <<YAML
metadata:
  atespace: ${ATESPACE}
  name: claude-lifecycle
workerSelector:
  matchLabels:
    ${POOL_LABEL%%=*}: ${POOL_LABEL#*=}
containers:
  - name: runner
    image: ${IMAGE}
    command: ["/bin/bash", "-c"]
    args:
      - |
        n=0
        while true; do
          n=\$((n + 1)); echo "\$n" > /workspace/count
          echo "tick \$n (memory) \$(cat /workspace/count) (file) \$(claude --version)"
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
}

cmd_check() {
  need kubectl
  ate get workers
}

cmd_lifecycle() {
  need kubectl
  say "atespace, template, actor"
  ensure_atespace
  lifecycle_template | ensure_template claude-lifecycle
  ensure_actor "${LIFECYCLE_ACTOR}" claude-lifecycle

  say "first resume"
  local start
  start="$(date +%s)"
  ate resume actor "${LIFECYCLE_ACTOR}" -a "${ATESPACE}"
  echo "first resume took $(($(date +%s) - start)) s"
  sleep 15
  local before
  before="$(last_tick || true)"
  echo "last tick before the suspend: ${before:-none}"
  [ -n "${before}" ] || { echo "FAIL: the actor printed no ticks; read its logs: kubectl ate logs actor ${LIFECYCLE_ACTOR} -a ${ATESPACE}" >&2; exit 1; }

  say "suspend (sync: the snapshot is durable when this returns), then resume"
  ate suspend actor "${LIFECYCLE_ACTOR}" -a "${ATESPACE}" --mode sync
  start="$(date +%s)"
  ate resume actor "${LIFECYCLE_ACTOR}" -a "${ATESPACE}"
  echo "resume after suspend took $(($(date +%s) - start)) s"
  sleep 10
  local after
  after="$(last_tick || true)"
  echo "last tick after the resume: ${after:-none}"

  if [ -n "${after}" ] && [ "${after}" -gt "${before}" ]; then
    echo "PASS: the counter continued (${before} -> ${after}), so memory survived the snapshot"
  else
    echo "FAIL: the counter did not continue (${before} -> ${after:-none}); memory was not restored (a cold boot starts at 1)" >&2
    exit 1
  fi
  echo "also check by hand: the file counter in the same lines, and kubectl -n ate-workers get pods (two workers, not one per actor)"
}

headless_template() { # needs ANTHROPIC_API_KEY in the environment; the key is substituted by envsubst, never written to a file
  cat <<YAML
metadata:
  atespace: ${ATESPACE}
  name: claude-headless
workerSelector:
  matchLabels:
    ${POOL_LABEL%%=*}: ${POOL_LABEL#*=}
containers:
  - name: claude
    image: ${IMAGE}
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
        value: "\${ANTHROPIC_API_KEY}"
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
}

cmd_headless() {
  need kubectl
  need envsubst
  [ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "set ANTHROPIC_API_KEY in your shell (not in a file or a chat)" >&2; exit 1; }
  ensure_atespace
  # only ANTHROPIC_API_KEY is substituted, and only on the way into kubectl: the rendered template holds the key and is never written to disk
  # shellcheck disable=SC2016 # envsubst takes the variable name literally, on purpose
  headless_template | envsubst '${ANTHROPIC_API_KEY}' | ensure_template claude-headless
  ensure_actor "${HEADLESS_ACTOR}" claude-headless
  ensure_egress_policy "${HEADLESS_ACTOR}"
  echo "ready: $0 ask 'Write a haiku about snapshots to /workspace/haiku.txt, then print it.'"
}

remote_template() { # needs CLAUDE_CREDENTIALS_B64 and, for the name and model, REMOTE_NAME and REMOTE_MODEL in the environment; envsubst puts only CLAUDE_CREDENTIALS_B64 in
  cat <<YAML
metadata:
  atespace: ${ATESPACE}
  name: claude-remote
workerSelector:
  matchLabels:
    ${POOL_LABEL%%=*}: ${POOL_LABEL#*=}
containers:
  - name: claude
    image: ${IMAGE}
    command: ["/bin/bash", "-c"]
    args:
      - |
        set -eu
        mkdir -p "\$HOME/.claude"
        # seed the login once: after that the file on the durable volume holds the refreshed tokens, and the value in the environment is stale
        if [ ! -s "\$HOME/.claude/.credentials.json" ]; then
          printf '%s' "\$CLAUDE_CREDENTIALS_B64" | base64 -d > "\$HOME/.claude/.credentials.json"
          chmod 600 "\$HOME/.claude/.credentials.json"
        fi
        [ -s "\$HOME/.claude/settings.json" ] || printf '{"model":"%s"}\n' "${REMOTE_MODEL}" > "\$HOME/.claude/settings.json"
        exec claude remote-control --name "${REMOTE_NAME}"
    env:
      - name: CLAUDE_CREDENTIALS_B64
        value: "\${CLAUDE_CREDENTIALS_B64}"
      - name: ANTHROPIC_MODEL
        value: "${REMOTE_MODEL}"
      - name: DISABLE_AUTOUPDATER
        value: "1"
      - name: DISABLE_TELEMETRY
        value: "1"
      - name: CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY
        value: "1"
      - name: CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL
        value: "1"
    volumeMounts:
      - name: home
        mountPath: /home/claude
volumes:
  - name: home
    durableDir: {}
resources:
  limits:
    cpuMillicores: 1000
    memoryBytes: 2147483648
snapshotConfig:
  preferredFidelity: SNAPSHOT_FIDELITY_MEMORY
YAML
}

cmd_remote() {
  need kubectl
  need envsubst
  need base64
  # WARNING, read before running: the login goes into the template, which is in Substrate's database and in every snapshot of the actor. Use a login made for this actor
  # (claude, then /login, on your own machine, then copy nothing from claude-rc: two sessions sharing one refresh token invalidate each other), and revoke it in your claude.ai
  # account when you delete the actor. Whether remote-control accepts such credentials in a sandbox, and keeps its connection across a suspend, is untested.
  if [ -z "${CLAUDE_CREDENTIALS_FILE:-}" ] || [ ! -s "${CLAUDE_CREDENTIALS_FILE}" ]; then
    echo "set CLAUDE_CREDENTIALS_FILE to the .credentials.json of a separate claude.ai login (see the warning in this script)" >&2
    exit 1
  fi
  CLAUDE_CREDENTIALS_B64="$(base64 -w0 "${CLAUDE_CREDENTIALS_FILE}")"
  export CLAUDE_CREDENTIALS_B64 REMOTE_NAME REMOTE_MODEL
  ensure_atespace
  # shellcheck disable=SC2016 # envsubst takes the variable name literally, on purpose
  remote_template | envsubst '${CLAUDE_CREDENTIALS_B64}' | ensure_template claude-remote
  unset CLAUDE_CREDENTIALS_B64
  ensure_actor "${REMOTE_ACTOR}" claude-remote
  # remote-control keeps a long-lived connection (WebSocket) to claude.ai, which the egress gateway blocks unless a tlsPassthrough rule matches the host: that is why the policy is
  # pass-through (the list includes claude.ai, platform.claude.com and *.claudeusercontent.com, which claude-rc needs for sign-in and Remote Control).
  ensure_egress_policy "${REMOTE_ACTOR}"
  ate resume actor "${REMOTE_ACTOR}" -a "${ATESPACE}"
  echo "started. Nothing suspends it, so it stays up and holds a worker. Look for its session '${REMOTE_NAME}' in claude.ai/code, and read its output:"
  echo "  kubectl ate logs actor ${REMOTE_ACTOR} -a ${ATESPACE} -c claude"
}

cmd_ask() {
  need kubectl
  need curl
  local text="${1:-}"
  [ -n "${text}" ] || { echo "usage: $0 ask TEXT" >&2; exit 2; }
  ate proxy actor "${HEADLESS_ACTOR}" -a "${ATESPACE}" "${LOCAL_PORT}:8080" >/dev/null 2>&1 &
  local proxy=$!
  # shellcheck disable=SC2064 # the pid is fixed now on purpose
  trap "kill ${proxy} 2>/dev/null || true" EXIT
  sleep 3 # the proxy resumes the actor if it is suspended; the first request waits for the wakeup probe
  curl -sS --max-time 700 -w '\n[%{http_code}, %{time_total} s]\n' "http://localhost:${LOCAL_PORT}/task" -d "${text}"
}

cmd_clean() {
  need kubectl
  for a in "${LIFECYCLE_ACTOR}" "${HEADLESS_ACTOR}" "${REMOTE_ACTOR}"; do ate delete actor "${a}" -a "${ATESPACE}" 2>/dev/null || true; done
  for t in claude-lifecycle claude-headless claude-remote; do ate delete actor-template "${t}" -a "${ATESPACE}" 2>/dev/null || true; done
  echo "deleted; the atespace ${ATESPACE} is left"
}

case "${1:-}" in
  check) cmd_check ;;
  lifecycle) cmd_lifecycle ;;
  headless) cmd_headless ;;
  ask) shift; cmd_ask "${1:-}" ;;
  remote) cmd_remote ;;
  clean) cmd_clean ;;
  policy) egress_policy_yaml ;;
  -h | --help | help | "") usage ;;
  *) usage >&2; exit 2 ;;
esac
