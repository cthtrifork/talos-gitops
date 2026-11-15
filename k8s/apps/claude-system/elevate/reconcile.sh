#!/usr/bin/env bash
# The elevate pod's hands (see elevate.yaml). The page (Redpanda Connect) only drops request files into /spool; this loop
# validates each one again, adds or removes a RoleBinding for ServiceAccount claude-system/claude, deletes every grant
# that has expired and writes /spool/status for the page. It trusts nothing in a request except what it re-checks here:
# the tier, the minutes and the namespaces. The admission policy claude-elevator-rolebindings is the second lock.
# Not a Flux template (configMapGenerator disables postBuild envsubst).
set -uo pipefail

spool=/spool
declare -A allowed=([ops]="" [debug]="")
declare -A max_minutes=([ops]=60 [debug]=15) # exec reaches whatever the pod can, so a shorter leash
selector=app.kubernetes.io/managed-by=claude-elevate
log=()

# One JSON line per action on stdout is the audit trail (the page's "Recent" list is only the last 10, in memory).
audit() { # event [tier] [namespace] [detail]
  jq -nc --arg event "$1" --arg tier "${2:-}" --arg namespace "${3:-}" --arg detail "${4:-}" \
    '{ts: (now | todate), event: $event, tier: $tier, namespace: $namespace, detail: $detail}'
}

note() {
  log+=("$(date -u +%H:%M:%S) $*")
  if ((${#log[@]} > 10)); then log=("${log[@]:1}"); fi
}

# The allowlist is the label claude-elevate/<tier>=true on a Namespace (set in Git next to the namespace; the admission policy reads the
# same label). debug and ops are opted in separately, since exec reaches the Secrets a pod mounts. If the lookup fails nothing is allowed.
refresh_allowed() {
  local t out
  for t in "${!max_minutes[@]}"; do
    if out="$(kubectl get namespaces -l "claude-elevate/${t}=true" -o json 2>/dev/null)"; then
      allowed[$t]="$(jq -r '[.items[].metadata.name] | join(" ")' <<<"$out")"
    else
      allowed[$t]=""
    fi
  done
}

is_allowed() { # tier namespace
  local ns
  for ns in ${allowed[$1]}; do [[ "$ns" == "$2" ]] && return 0; done
  return 1
}

grant() { # tier namespace minutes
  local tier=$1 ns=$2 minutes=$3 expires
  expires="$(jq -rn --argjson t "$(($(date +%s) + minutes * 60))" '$t | todate')"
  jq -n --arg ns "$ns" --arg tier "$tier" --arg exp "$expires" '{
      apiVersion: "rbac.authorization.k8s.io/v1", kind: "RoleBinding",
      metadata: {name: ("claude-elevate-" + $tier), namespace: $ns,
                 labels: {"app.kubernetes.io/managed-by": "claude-elevate"},
                 annotations: {"claude-elevate/expires-at": $exp}},
      roleRef: {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: ("claude-" + $tier)},
      subjects: [{kind: "ServiceAccount", name: "claude", namespace: "claude-system"}]}' |
    kubectl apply -f - >/dev/null 2>&1 && { audit granted "$tier" "$ns" "until ${expires}"; note "granted ${tier} in ${ns} until ${expires}"; } ||
    { audit grant_failed "$tier" "$ns"; note "FAILED to grant ${tier} in ${ns}"; }
}

revoke() { # tier namespace [reason]
  kubectl delete rolebinding "claude-elevate-$1" -n "$2" --ignore-not-found >/dev/null 2>&1 && { audit revoked "$1" "$2" "$3"; note "revoked $1 in $2"; } ||
    { audit revoke_failed "$1" "$2"; note "FAILED to revoke $1 in $2"; }
}

handle() { # request file
  local body tier minutes action ns
  body="$(cat "$1")"
  rm -f "$1"
  action="$(jq -r '.action // ""' <<<"$body" 2>/dev/null)" || { audit rejected "" "" "unreadable request"; note "dropped an unreadable request"; return; }
  case "$action" in
    revokeall)
      while read -r name ns; do revoke "${name#claude-elevate-}" "$ns" requested; done < <(
        kubectl get rolebindings -A -l "$selector" -o json | jq -r '.items[] | "\(.metadata.name) \(.metadata.namespace)"')
      ;;
    revoke)
      tier="$(jq -r '.tier // ""' <<<"$body")"
      ns="$(jq -r '.namespace // ""' <<<"$body")"
      # A revoke always works, also for a namespace that has left the allowlist since; the admission policy lets it delete only its own bindings
      if [[ -n "${max_minutes[$tier]:-}" && "$ns" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]; then revoke "$tier" "$ns" requested; else audit rejected "" "" "revoke request"; note "rejected a revoke request"; fi
      ;;
    grant)
      tier="$(jq -r '.tier // ""' <<<"$body")"
      minutes="$(jq -r '.minutes // ""' <<<"$body")"
      if [[ -z "${max_minutes[$tier]:-}" || ! "$minutes" =~ ^[0-9]+$ ]] || ((minutes < 1 || minutes > max_minutes[$tier])); then
        audit rejected "" "" "grant request: tier or minutes"
        note "rejected a grant request (tier or minutes)"
        return
      fi
      while read -r ns; do
        if is_allowed "$tier" "$ns"; then grant "$tier" "$ns" "$minutes"; else audit rejected "$tier" "${ns:0:63}" "namespace not opted in"; note "rejected namespace ${ns:0:63}"; fi
      done < <(jq -r '(.namespaces // [])[] | strings' <<<"$body")
      ;;
    *) audit rejected "" "" "unknown action"; note "dropped a request with an unknown action" ;;
  esac
}

# A grant with no readable expiry counts as expired, so a mangled annotation fails closed.
sweep() {
  while read -r name ns; do revoke "${name#claude-elevate-}" "$ns" expired; done < <(
    kubectl get rolebindings -A -l "$selector" -o json | jq -r --argjson now "$(date +%s)" '
      .items[] | select((try (.metadata.annotations["claude-elevate/expires-at"] | fromdateiso8601) catch 0) <= $now)
      | "\(.metadata.name) \(.metadata.namespace)"')
}

write_status() {
  local bindings
  bindings="$(kubectl get rolebindings -A -l "$selector" -o json)" || return
  printf '%s\n' "${log[@]:-}" | jq -R . | jq -s . | jq --argjson b "$bindings" --argjson now "$(date +%s)" \
    --arg aops "${allowed[ops]}" --arg adebug "${allowed[debug]}" --argjson ops "${max_minutes[ops]}" --argjson debug "${max_minutes[debug]}" '{
      now: $now,
      allowed_namespaces: {ops: ($aops | split(" ")), debug: ($adebug | split(" "))},
      max_minutes: {ops: $ops, debug: $debug},
      grants: [$b.items[] | {namespace: .metadata.namespace, tier: (.metadata.name | ltrimstr("claude-elevate-")),
                            expires_at: .metadata.annotations["claude-elevate/expires-at"]}],
      log: (. | map(select(. != "")))}' >"${spool}/.status.tmp" && mv "${spool}/.status.tmp" "${spool}/status"
}

while true; do
  touch "${spool}/.alive" # the liveness probe: a stuck loop leaves grants past their time
  refresh_allowed
  for f in "${spool}"/req-*; do
    [[ -e "$f" ]] || continue
    # Connect writes the file in place: give it a second to finish
    (($(date +%s) - $(stat -c %Y "$f") >= 1)) || continue
    handle "$f"
  done
  sweep
  write_status
  sleep 3
done
