#!/usr/bin/env bash
# Turns the request files the page drops into /spool into a ServiceAccount, a RoleBinding and a short-lived token for a tier, stored as a
# kubeconfig in a Secret that claude-rc mounts. The page is not trusted: tier, minutes and namespaces are checked here again. The token
# expires on its own; deleting expired ServiceAccounts, bindings and kubeconfigs is housekeeping. Talks to the API server with curl.
set -uo pipefail

spool=/spool
api=${API_SERVER:-https://kubernetes.default.svc}
sa_dir=/var/run/secrets/kubernetes.io/serviceaccount
auth_header=/tmp/auth-header
secret=claude-elevated-kubeconfigs
secret_ns=claude-system
selector=app.kubernetes.io/managed-by=claude-elevate
dns_label='^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'
min_minutes=10 # the API server's shortest token
declare -A max_minutes=([ops]=60 [debug]=15 [storage]=15)
declare -A allowed=()
log=()

# The projected token is rotated, so the header file is rewritten every pass
refresh_auth() { (umask 077 && printf 'Authorization: Bearer %s\n' "$(cat "${sa_dir}/token")" >"$auth_header"); }

curl_api() { curl -q -sS --fail-with-body --cacert "${sa_dir}/ca.crt" -H "@${auth_header}" "$@"; }

get() { # path [label selector]
  if [[ -n "${2:-}" ]]; then curl_api -G --data-urlencode "labelSelector=$2" "${api}$1"; else curl_api "${api}$1"; fi
}

send() { # method path content-type: the body is read from stdin
  curl_api -X "$1" -H "Content-Type: $3" --data-binary @- "${api}$2"
}

# a missing object counts as deleted
delete() { # path
  local code
  code="$(curl -q -sS -o /dev/null -w '%{http_code}' --cacert "${sa_dir}/ca.crt" -H "@${auth_header}" -X DELETE "${api}$1")"
  [[ "$code" == 2* || "$code" == 404 ]]
}

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
    out="$(get /api/v1/namespaces "claude-elevate/${t}=true" 2>/dev/null)" || out='{"items":[]}'
    allowed[$t]="$(jq -r '[.items[].metadata.name] | join(" ")' <<<"$out")"
  done
}

is_allowed() { # tier namespace
  local ns
  for ns in ${allowed[$1]}; do [[ "$ns" == "$2" ]] && return 0; done
  return 1
}

list_grants() { get /api/v1/serviceaccounts "$selector"; }

patch_secret() { send PATCH "/api/v1/namespaces/${secret_ns}/secrets/${secret}" application/merge-patch+json >/dev/null 2>&1; }

# server-side apply, one object per call
apply() { # path
  send PATCH "$1?fieldManager=claude-elevate&force=true" application/apply-patch+yaml >/dev/null 2>&1
}

apply_grant() { # tier namespace expires
  local name="claude-elevate-$1"
  jq -n --arg ns "$2" --arg name "$name" --arg exp "$3" '{
    apiVersion: "v1", kind: "ServiceAccount",
    metadata: {name: $name, namespace: $ns, labels: {"app.kubernetes.io/managed-by": "claude-elevate"},
               annotations: {"claude-elevate/expires-at": $exp}}}' | apply "/api/v1/namespaces/$2/serviceaccounts/${name}" &&
    jq -n --arg ns "$2" --arg tier "$1" --arg name "$name" --arg exp "$3" '{
      apiVersion: "rbac.authorization.k8s.io/v1", kind: "RoleBinding",
      metadata: {name: $name, namespace: $ns, labels: {"app.kubernetes.io/managed-by": "claude-elevate"},
                 annotations: {"claude-elevate/expires-at": $exp}},
      roleRef: {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: ("claude-" + $tier)},
      subjects: [{kind: "ServiceAccount", name: $name, namespace: $ns}]}' |
    apply "/apis/rbac.authorization.k8s.io/v1/namespaces/$2/rolebindings/${name}"
}

request_token() { # tier namespace seconds
  jq -n --argjson s "$3" '{apiVersion: "authentication.k8s.io/v1", kind: "TokenRequest", spec: {expirationSeconds: $s}}' |
    send POST "/api/v1/namespaces/$2/serviceaccounts/claude-elevate-$1/token" application/json 2>/dev/null | jq -er .status.token
}

write_kubeconfig() { # tier namespace token
  local name="$1-$2"
  TOKEN="$3" jq -n --arg name "$name" --arg ns "$2" --arg ca "$(base64 <"${sa_dir}/ca.crt" | tr -d '\n')" '{
    stringData: {($name + ".kubeconfig"): ({
      apiVersion: "v1", kind: "Config", "current-context": $name,
      clusters: [{name: "cluster", cluster: {server: "https://kubernetes.default.svc", "certificate-authority-data": $ca}}],
      users: [{name: $name, user: {token: env.TOKEN}}],
      contexts: [{name: $name, context: {cluster: "cluster", user: $name, namespace: $ns}}]} | tojson)}}' | patch_secret
}

# deleting the ServiceAccount invalidates its tokens at once
remove() { # tier namespace
  local rc=0 name="claude-elevate-$1"
  delete "/api/v1/namespaces/$2/serviceaccounts/${name}" || rc=1
  delete "/apis/rbac.authorization.k8s.io/v1/namespaces/$2/rolebindings/${name}" || rc=1
  jq -n --arg key "$1-$2.kubeconfig" '{data: {($key): null}}' | patch_secret || rc=1
  return "$rc"
}

# the token's own exp claim must not be later than the grant's deadline (a minute of slack)
token_within() { # token minutes
  local exp
  exp="$(jq -rR 'split(".")[1] | gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - length % 4) % 4)) | @base64d | fromjson | .exp' <<<"$1")" &&
    ((exp <= $(date +%s) + $2 * 60 + 60))
}

grant() { # tier namespace minutes
  local tier=$1 ns=$2 expires token
  expires="$(jq -rn --argjson t "$(($(date +%s) + $3 * 60))" '$t | todate')"
  # a new ServiceAccount invalidates the tokens of an earlier grant
  if remove "$tier" "$ns" && apply_grant "$tier" "$ns" "$expires" &&
    token="$(request_token "$tier" "$ns" "$(($3 * 60))")" &&
    token_within "$token" "$3" &&
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

# removes the kubeconfigs of grants that no longer exist
prune_kubeconfigs() {
  local keep patch
  keep="$(list_grants | jq -c '[.items[] | "\(.metadata.name | ltrimstr("claude-elevate-"))-\(.metadata.namespace).kubeconfig"]')" || return
  patch="$(get "/api/v1/namespaces/${secret_ns}/secrets/${secret}" 2>/dev/null |
    jq -c --argjson keep "$keep" '{data: ((.data // {}) | with_entries(select(.key | IN($keep[]) | not)) | map_values(null))}')" || return
  if jq -e '.data | length > 0' <<<"$patch" >/dev/null 2>&1; then patch_secret <<<"$patch"; fi
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
      if [[ -z "${max_minutes[$tier]:-}" || ! "$minutes" =~ ^[1-9][0-9]{0,3}$ ]] || ((minutes < min_minutes || minutes > max_minutes[$tier])); then
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
  refresh_auth
  refresh_allowed
  for f in "${spool}"/req-*; do
    [[ -e "$f" ]] || continue
    # names sort by arrival; stop at a file younger than a second (Connect writes in place) so a later request never runs first
    (($(date +%s) - $(stat -c %Y "$f") >= 1)) || break
    handle "$f"
  done
  revoke_grants expired
  prune_kubeconfigs
  write_status
  sleep 3
done
