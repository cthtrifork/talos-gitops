#!/usr/bin/env bash
# The elevate pod's hands (see elevate.yaml). The page (Redpanda Connect) only drops request files into /spool; this loop
# validates each one again, adds or removes a RoleBinding for ServiceAccount claude-system/claude, deletes every grant
# that has expired and writes /spool/status for the page. It trusts nothing in a request except what it re-checks here:
# the tier, the minutes and the namespaces. The admission policy claude-elevator-rolebindings is the second lock.
# Not a Flux template (configMapGenerator disables postBuild envsubst).
set -uo pipefail

spool=/spool
read -r -a allowed <<<"${ALLOWED_NAMESPACES:?}"
declare -A max_minutes=([ops]=60 [debug]=15) # exec reaches whatever the pod can, so a shorter leash
selector=app.kubernetes.io/managed-by=claude-elevate
log=()

note() {
  echo "$*"
  log+=("$(date -u +%H:%M:%S) $*")
  if ((${#log[@]} > 10)); then log=("${log[@]:1}"); fi
}

is_allowed() {
  local ns
  for ns in "${allowed[@]}"; do [[ "$ns" == "$1" ]] && return 0; done
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
    kubectl apply -f - >/dev/null 2>&1 && note "granted ${tier} in ${ns} until ${expires}" || note "FAILED to grant ${tier} in ${ns}"
}

revoke() { # tier namespace
  kubectl delete rolebinding "claude-elevate-$1" -n "$2" --ignore-not-found >/dev/null 2>&1 && note "revoked $1 in $2" || note "FAILED to revoke $1 in $2"
}

handle() { # request file
  local body tier minutes action ns
  body="$(cat "$1")"
  rm -f "$1"
  action="$(jq -r '.action // ""' <<<"$body" 2>/dev/null)" || { note "dropped an unreadable request"; return; }
  case "$action" in
    revokeall)
      while read -r name ns; do revoke "${name#claude-elevate-}" "$ns"; done < <(
        kubectl get rolebindings -A -l "$selector" -o json | jq -r '.items[] | "\(.metadata.name) \(.metadata.namespace)"')
      ;;
    revoke)
      tier="$(jq -r '.tier // ""' <<<"$body")"
      ns="$(jq -r '.namespace // ""' <<<"$body")"
      if [[ -n "${max_minutes[$tier]:-}" ]] && is_allowed "$ns"; then revoke "$tier" "$ns"; else note "rejected a revoke request"; fi
      ;;
    grant)
      tier="$(jq -r '.tier // ""' <<<"$body")"
      minutes="$(jq -r '.minutes // ""' <<<"$body")"
      if [[ -z "${max_minutes[$tier]:-}" || ! "$minutes" =~ ^[0-9]+$ ]] || ((minutes < 1 || minutes > max_minutes[$tier])); then
        note "rejected a grant request (tier or minutes)"
        return
      fi
      while read -r ns; do
        if is_allowed "$ns"; then grant "$tier" "$ns" "$minutes"; else note "rejected namespace ${ns:0:63}"; fi
      done < <(jq -r '(.namespaces // [])[] | strings' <<<"$body")
      ;;
    *) note "dropped a request with an unknown action" ;;
  esac
}

# A grant with no readable expiry counts as expired, so a mangled annotation fails closed.
sweep() {
  while read -r name ns; do revoke "${name#claude-elevate-}" "$ns"; done < <(
    kubectl get rolebindings -A -l "$selector" -o json | jq -r --argjson now "$(date +%s)" '
      .items[] | select((try (.metadata.annotations["claude-elevate/expires-at"] | fromdateiso8601) catch 0) <= $now)
      | "\(.metadata.name) \(.metadata.namespace)"')
}

write_status() {
  local bindings
  bindings="$(kubectl get rolebindings -A -l "$selector" -o json)" || return
  printf '%s\n' "${log[@]:-}" | jq -R . | jq -s . | jq --argjson b "$bindings" --argjson now "$(date +%s)" \
    --arg allowed "${allowed[*]}" --argjson ops "${max_minutes[ops]}" --argjson debug "${max_minutes[debug]}" '{
      now: $now,
      allowed_namespaces: ($allowed | split(" ")),
      max_minutes: {ops: $ops, debug: $debug},
      grants: [$b.items[] | {namespace: .metadata.namespace, tier: (.metadata.name | ltrimstr("claude-elevate-")),
                            expires_at: .metadata.annotations["claude-elevate/expires-at"]}],
      log: (. | map(select(. != "")))}' >"${spool}/.status.tmp" && mv "${spool}/.status.tmp" "${spool}/status"
}

while true; do
  touch "${spool}/.alive" # the liveness probe: a stuck loop leaves grants past their time
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
