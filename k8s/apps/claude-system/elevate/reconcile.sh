#!/usr/bin/env bash
# Turns the request files the page drops into /spool into a ServiceAccount, a RoleBinding and a short-lived token for a tier, written as a
# kubeconfig to /elevated. The page is not trusted: tier, minutes and namespaces are checked here again. The token expires on its own;
# deleting expired ServiceAccounts, bindings and files is housekeeping.
set -uo pipefail

spool=/spool
elevated=/elevated
ca_file=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
selector=app.kubernetes.io/managed-by=claude-elevate
dns_label='^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'
min_minutes=10 # the API server's shortest token
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

list_grants() { kubectl get serviceaccounts -A -l "$selector" -o json; }

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

write_kubeconfig() { # tier namespace token
  local name="$1-$2" file="${elevated}/$1-$2.kubeconfig"
  (
    umask 022
    TOKEN="$3" jq -n --arg name "$name" --arg ns "$2" --arg ca "$(base64 <"$ca_file" | tr -d '\n')" '{
      apiVersion: "v1", kind: "Config", "current-context": $name,
      clusters: [{name: "cluster", cluster: {server: "https://kubernetes.default.svc", "certificate-authority-data": $ca}}],
      users: [{name: $name, user: {token: env.TOKEN}}],
      contexts: [{name: $name, context: {cluster: "cluster", user: $name, namespace: $ns}}]}' >"${file}.tmp"
  ) && mv "${file}.tmp" "$file"
}

# deleting the ServiceAccount invalidates its tokens at once
remove() { # tier namespace
  local rc=0
  kubectl delete serviceaccount,rolebinding "claude-elevate-$1" -n "$2" --ignore-not-found >/dev/null 2>&1 || rc=1
  rm -f "${elevated}/$1-$2.kubeconfig"
  return $rc
}

grant() { # tier namespace minutes
  local tier=$1 ns=$2 expires token
  expires="$(jq -rn --argjson t "$(($(date +%s) + $3 * 60))" '$t | todate')"
  if apply_grant "$tier" "$ns" "$expires" &&
    token="$(kubectl create token "claude-elevate-$tier" -n "$ns" --duration="${3}m" 2>/dev/null)" &&
    write_kubeconfig "$tier" "$ns" "$token"; then
    event granted "$tier" "$ns" "until ${expires}"
  else
    remove "$tier" "$ns"
    event grant_failed "$tier" "$ns"
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

prune_kubeconfigs() {
  local keep f
  keep="$(list_grants | jq -r '.items[] | "\(.metadata.name | ltrimstr("claude-elevate-"))-\(.metadata.namespace).kubeconfig"')" || return
  for f in "${elevated}"/*.kubeconfig; do
    [[ -e "$f" ]] || continue
    grep -qxF "${f##*/}" <<<"$keep" || rm -f "$f"
  done
}

field() { jq -r --arg k "$1" '.[$k] // "" | tostring' <<<"$2"; } # field name, JSON

handle() { # request file
  local body tier minutes ns
  body="$(cat "$1")"
  rm -f "$1"
  jq -e 'type == "object"' <<<"$body" >/dev/null 2>&1 || { event rejected "" "" "unreadable request"; return; }
  tier="$(field tier "$body")"
  case "$(field action "$body")" in
    revokeall) revoke_grants requested ;;
    revoke)
      # not limited to opted-in namespaces
      ns="$(field namespace "$body")"
      if [[ -n "${max_minutes[$tier]:-}" && "$ns" =~ $dns_label ]]; then revoke "$tier" "$ns" requested; else event rejected "" "" "revoke request"; fi
      ;;
    grant)
      minutes="$(field minutes "$body")"
      if [[ -z "${max_minutes[$tier]:-}" || ! "$minutes" =~ ^[0-9]+$ ]] || ((minutes < min_minutes || minutes > max_minutes[$tier])); then
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
  local grants tiers t
  grants="$(list_grants)" || return
  tiers="$(for t in "${!max_minutes[@]}"; do printf '%s\t%s\t%s\n' "$t" "${max_minutes[$t]}" "${allowed[$t]}"; done |
    jq -Rn '[inputs | split("\t")] | {
      max_minutes: (map({(.[0]): (.[1] | tonumber)}) | add),
      allowed_namespaces: (map({(.[0]): (.[2] | split(" ") | map(select(. != "")))}) | add)}')"
  jq -n --argjson g "$grants" --argjson tiers "$tiers" --argjson now "$(date +%s)" --argjson min "$min_minutes" '$tiers + {
      now: $now,
      min_minutes: $min,
      grants: [$g.items[] | {namespace: .metadata.namespace, tier: (.metadata.name | ltrimstr("claude-elevate-")),
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
  revoke_grants expired
  prune_kubeconfigs
  write_status
  sleep 3
done
