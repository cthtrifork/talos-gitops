#!/usr/bin/env bash
# Turns the request files the page drops into /spool into a ServiceAccount, a RoleBinding and a short-lived token for a tier, stored as a
# kubeconfig in a Secret that claude-rc mounts. The page is not trusted: tier, minutes and namespaces are checked here again. The token
# expires on its own; deleting expired ServiceAccounts, bindings and kubeconfigs is housekeeping.
set -uo pipefail

spool=/spool
secret=claude-elevated-kubeconfigs
secret_ns=claude-system
selector=app.kubernetes.io/managed-by=claude-elevate
dns_label='^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'
min_minutes=10 # the API server's shortest token
max_minutes='{"ops":60,"debug":15,"storage":15}'
allowed='{}'
log=()

# One JSON line on stdout (audit trail) and one line for the page's "Recent" box (last 10, in memory)
event() { # event [tier] [namespace] [detail]
  jq -nc --arg event "$1" --arg tier "${2:-}" --arg namespace "${3:-}" --arg detail "${4:-}" \
    '{ts: (now | todate), event: $event, tier: $tier, namespace: $namespace, detail: $detail}'
  log+=("$(date -u +%H:%M:%S) $1${2:+ $2}${3:+ in $3}${4:+ $4}")
  if ((${#log[@]} > 10)); then log=("${log[@]:1}"); fi
}

# A namespace opts in per tier with the label claude-elevate/<tier>=true (the admission policy reads the same label)
refresh_allowed() {
  local t out
  allowed="$(for t in $(jq -r 'keys[]' <<<"$max_minutes"); do
    out="$(kubectl get namespaces -l "claude-elevate/${t}=true" -o json 2>/dev/null)" || out='{"items":[]}'
    jq -c --arg t "$t" '{($t): [.items[].metadata.name]}' <<<"$out"
  done | jq -sc add)"
}

is_allowed() { jq -e --arg t "$1" --arg ns "$2" '.[$t] | index($ns)' <<<"$allowed" >/dev/null; } # tier namespace

list_grants() { kubectl get serviceaccounts -A -l "$selector" -o json; }

patch_secret() { kubectl patch secret "$secret" -n "$secret_ns" --type merge --patch-file=/dev/stdin >/dev/null 2>&1; }

apply_grant() { # tier namespace expires
  jq -n --arg ns "$2" --arg tier "$1" --arg exp "$3" '
    def meta: {name: ("claude-elevate-" + $tier), namespace: $ns,
               labels: {"app.kubernetes.io/managed-by": "claude-elevate"},
               annotations: {"claude-elevate/expires-at": $exp}};
    {apiVersion: "v1", kind: "List", items: [
      {apiVersion: "v1", kind: "ServiceAccount", metadata: meta},
      {apiVersion: "rbac.authorization.k8s.io/v1", kind: "RoleBinding", metadata: meta,
       roleRef: {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: ("claude-" + $tier)},
       subjects: [{kind: "ServiceAccount", name: ("claude-elevate-" + $tier), namespace: $ns}]}]}' |
    kubectl apply -f - >/dev/null 2>&1
}

# the token's own exp claim must not be later than the grant's deadline (a minute of slack)
token_within() { # token minutes
  local exp
  exp="$(jq -rR 'split(".")[1] | gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - length % 4) % 4)) | @base64d | fromjson | .exp' <<<"$1")" &&
    ((exp <= $(date +%s) + $2 * 60 + 60))
}

write_kubeconfig() { # tier namespace token
  local name="$1-$2"
  TOKEN="$3" jq -n --arg name "$name" --arg ns "$2" '{
    stringData: {($name + ".kubeconfig"): ({
      apiVersion: "v1", kind: "Config", "current-context": $name,
      clusters: [{name: "cluster", cluster: {server: "https://kubernetes.default.svc",
                                             "certificate-authority": "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"}}],
      users: [{name: $name, user: {token: env.TOKEN}}],
      contexts: [{name: $name, context: {cluster: "cluster", user: $name, namespace: $ns}}]} | tojson)}}' | patch_secret
}

# deleting the ServiceAccount invalidates its tokens at once; the kubeconfig goes first, so a failure leaves a grant that is still listed and retried
remove() { # tier namespace
  jq -n --arg key "$1-$2.kubeconfig" '{data: {($key): null}}' | patch_secret &&
    kubectl delete serviceaccount,rolebinding "claude-elevate-$1" -n "$2" --ignore-not-found >/dev/null 2>&1
}

grant() { # tier namespace minutes
  local expires token
  expires="$(jq -rn --argjson t "$(($(date +%s) + $3 * 60))" '$t | todate')"
  # a new ServiceAccount invalidates the tokens of an earlier grant
  if remove "$1" "$2" && apply_grant "$1" "$2" "$expires" &&
    token="$(kubectl create token "claude-elevate-$1" -n "$2" --duration="${3}m" 2>/dev/null)" && token_within "$token" "$3" &&
    write_kubeconfig "$1" "$2" "$token"; then
    event granted "$1" "$2" "until ${expires}"
  else
    remove "$1" "$2"
    event grant_failed "$1" "$2"
  fi
}

revoke() { # tier namespace reason
  if remove "$1" "$2"; then event revoked "$1" "$2" "$3"; else event revoke_failed "$1" "$2"; fi
}

# reason "expired": only overdue grants (an unreadable expiry counts as overdue); anything else: all of them
revoke_grants() { # reason
  local name ns
  while read -r name ns; do revoke "${name#claude-elevate-}" "$ns" "$1"; done < <(
    list_grants | jq -r --arg reason "$1" --argjson now "$(date +%s)" '
      .items[]
      | select($reason != "expired" or (try (.metadata.annotations["claude-elevate/expires-at"] | fromdateiso8601) catch 0) <= $now)
      | "\(.metadata.name) \(.metadata.namespace)"')
}

handle() { # request file
  local body action tier minutes ns max
  body="$(cat "$1")"
  rm -f "$1"
  IFS=$'\x1f' read -r action tier minutes ns < <(jq -r '[.action, .tier, .minutes, .namespace] | map(. // "" | tostring) | join("\u001f")' <<<"$body" 2>/dev/null) ||
    { event rejected "" "" "unreadable request"; return; }
  max="$(jq -r --arg t "$tier" '.[$t] // empty' <<<"$max_minutes")"
  case "$action" in
    revokeall) revoke_grants requested ;;
    revoke)
      # not limited to opted-in namespaces
      if [[ -n "$max" && "$ns" =~ $dns_label ]]; then revoke "$tier" "$ns" requested; else event rejected "" "" "revoke request"; fi
      ;;
    grant)
      if [[ -z "$max" || ! "$minutes" =~ ^[1-9][0-9]{0,3}$ ]] || ((minutes < min_minutes || minutes > max)); then
        event rejected "" "" "grant request: tier or minutes"
        return
      fi
      while read -r ns; do
        if is_allowed "$tier" "$ns"; then grant "$tier" "$ns" "$minutes"; else event rejected "$tier" "${ns:0:63}" "namespace not opted in"; fi
      done < <(jq -r '(.namespaces // [])[] | strings' <<<"$body")
      ;;
    *) event rejected "" "" "unknown action" ;;
  esac
}

write_status() {
  local grants
  grants="$(list_grants)" || return
  jq -n --argjson g "$grants" --argjson allowed "$allowed" --argjson max "$max_minutes" --argjson now "$(date +%s)" '{
      now: $now, max_minutes: $max, allowed_namespaces: $allowed,
      grants: [$g.items[] | {namespace: .metadata.namespace, tier: (.metadata.name | ltrimstr("claude-elevate-")),
                            expires_at: .metadata.annotations["claude-elevate/expires-at"]}],
      log: $ARGS.positional}' --args "${log[@]}" >"${spool}/.status.tmp" && mv "${spool}/.status.tmp" "${spool}/status"
}

while true; do
  touch "${spool}/.alive" # liveness probe
  refresh_allowed
  for f in "${spool}"/req-*; do
    [[ -e "$f" ]] || continue
    # names sort by arrival; stop at a file younger than a second (Connect writes in place) so a later request never runs first
    (($(date +%s) - $(stat -c %Y "$f") >= 1)) || break
    handle "$f"
  done
  revoke_grants expired
  write_status
  sleep 3
done
