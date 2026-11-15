#!/usr/bin/env bash
# Turns the request files the page drops into /spool into RoleBindings for claude-system/claude, re-validating each one,
# and deletes grants that have expired. The page is not trusted: tier, minutes and namespaces are checked here again.
set -uo pipefail

spool=/spool
selector=app.kubernetes.io/managed-by=claude-elevate
dns_label='^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'
declare -A max_minutes=([ops]=60 [debug]=15 [storage]=15)
declare -A allowed=()
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
  for t in "${!max_minutes[@]}"; do
    out="$(kubectl get namespaces -l "claude-elevate/${t}=true" -o json 2>/dev/null)" || out='{"items":[]}'
    allowed[$t]="$(jq -r '[.items[].metadata.name] | join(" ")' <<<"$out")"
  done
}

is_allowed() { # tier namespace
  local ns
  for ns in ${allowed[$1]}; do [[ "$ns" == "$2" ]] && return 0; done
  return 1
}

list_bindings() { kubectl get rolebindings -A -l "$selector" -o json; }

grant() { # tier namespace minutes
  local tier=$1 ns=$2 expires
  expires="$(jq -rn --argjson t "$(($(date +%s) + $3 * 60))" '$t | todate')"
  if jq -n --arg ns "$ns" --arg tier "$tier" --arg exp "$expires" '{
      apiVersion: "rbac.authorization.k8s.io/v1", kind: "RoleBinding",
      metadata: {name: ("claude-elevate-" + $tier), namespace: $ns,
                 labels: {"app.kubernetes.io/managed-by": "claude-elevate"},
                 annotations: {"claude-elevate/expires-at": $exp}},
      roleRef: {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: ("claude-" + $tier)},
      subjects: [{kind: "ServiceAccount", name: "claude", namespace: "claude-system"}]}' |
    kubectl apply -f - >/dev/null 2>&1; then
    event granted "$tier" "$ns" "until ${expires}"
  else
    event grant_failed "$tier" "$ns"
  fi
}

revoke() { # tier namespace reason
  if kubectl delete rolebinding "claude-elevate-$1" -n "$2" --ignore-not-found >/dev/null 2>&1; then
    event revoked "$1" "$2" "$3"
  else
    event revoke_failed "$1" "$2"
  fi
}

# reason "expired": only overdue grants (an unreadable expiry counts as overdue); anything else: all of them
revoke_bindings() { # reason
  local name ns
  while read -r name ns; do revoke "${name#claude-elevate-}" "$ns" "$1"; done < <(
    list_bindings | jq -r --arg reason "$1" --argjson now "$(date +%s)" '
      .items[]
      | select($reason != "expired" or (try (.metadata.annotations["claude-elevate/expires-at"] | fromdateiso8601) catch 0) <= $now)
      | "\(.metadata.name) \(.metadata.namespace)"')
}

field() { jq -r --arg k "$1" '.[$k] // "" | tostring' <<<"$2"; } # field name, JSON

handle() { # request file
  local body tier minutes ns
  body="$(cat "$1")"
  rm -f "$1"
  jq -e 'type == "object"' <<<"$body" >/dev/null 2>&1 || { event rejected "" "" "unreadable request"; return; }
  tier="$(field tier "$body")"
  case "$(field action "$body")" in
    revokeall) revoke_bindings requested ;;
    revoke)
      # not limited to opted-in namespaces
      ns="$(field namespace "$body")"
      if [[ -n "${max_minutes[$tier]:-}" && "$ns" =~ $dns_label ]]; then revoke "$tier" "$ns" requested; else event rejected "" "" "revoke request"; fi
      ;;
    grant)
      minutes="$(field minutes "$body")"
      if [[ -z "${max_minutes[$tier]:-}" || ! "$minutes" =~ ^[0-9]+$ ]] || ((minutes < 1 || minutes > max_minutes[$tier])); then
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
  local bindings tiers t
  bindings="$(list_bindings)" || return
  tiers="$(for t in "${!max_minutes[@]}"; do printf '%s\t%s\t%s\n' "$t" "${max_minutes[$t]}" "${allowed[$t]}"; done |
    jq -Rn '[inputs | split("\t")] | {
      max_minutes: (map({(.[0]): (.[1] | tonumber)}) | add),
      allowed_namespaces: (map({(.[0]): (.[2] | split(" ") | map(select(. != "")))}) | add)}')"
  jq -n --argjson b "$bindings" --argjson tiers "$tiers" --argjson now "$(date +%s)" '$tiers + {
      now: $now,
      grants: [$b.items[] | {namespace: .metadata.namespace, tier: (.metadata.name | ltrimstr("claude-elevate-")),
                            expires_at: .metadata.annotations["claude-elevate/expires-at"]}],
      log: $ARGS.positional}' --args "${log[@]}" >"${spool}/.status.tmp" && mv "${spool}/.status.tmp" "${spool}/status"
}

while true; do
  touch "${spool}/.alive" # liveness probe
  refresh_allowed
  for f in "${spool}"/req-*; do
    [[ -e "$f" ]] || continue
    # skip files younger than a second (Connect writes in place)
    (($(date +%s) - $(stat -c %Y "$f") >= 1)) || continue
    handle "$f"
  done
  revoke_bindings expired
  write_status
  sleep 3
done
