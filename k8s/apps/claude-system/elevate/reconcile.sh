#!/usr/bin/env bash
# Turns the request files the page drops into /spool into a ServiceAccount, a RoleBinding and a short-lived token for a tier, stored as a
# kubeconfig in a Secret that claude-rc mounts. The API server decides what is allowed (RBAC, the admission policies, the TokenRequest
# limits) and the token expires on its own; this only checks that names are safe to put in a URL. Deleting expired ServiceAccounts,
# bindings and kubeconfigs is housekeeping. The page reads the state from the API itself; it gets from here a read-only token,
# a heartbeat and the last lines of what happened.
set -uo pipefail

spool=/spool
server=${API_SERVER:-https://kubernetes.default.svc}
sa_dir=/var/run/secrets/kubernetes.io/serviceaccount
auth_header=/tmp/auth-header
secret=/api/v1/namespaces/claude-system/secrets/claude-elevated-kubeconfigs
grants_path='/api/v1/serviceaccounts?labelSelector=app.kubernetes.io/managed-by%3Dclaude-elevate'
tier_label='^[a-z]{1,16}$'
dns_label='^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'
log=()
# shellcheck disable=SC2016
meta_def='def meta: {name: $name, namespace: $ns, labels: {"app.kubernetes.io/managed-by": "claude-elevate"}, annotations: {"claude-elevate/expires-at": $exp}};'

# curl against the API server; a content type means the body is read from stdin. The last response is kept for the reason of a failure.
api() { # method path [content-type]
  local body=()
  [[ -n "${3:-}" ]] && body=(-H "Content-Type: $3" --data-binary @-)
  curl -q -sS --fail-with-body --cacert "${sa_dir}/ca.crt" -H "@${auth_header}" -X "$1" "${body[@]}" "${server}$2" | tee /tmp/last-response
}

# a missing object counts as deleted
delete() { # path
  local err
  err="$(api DELETE "$1" 2>&1 >/dev/null)" || [[ "$err" == *"error: 404"* ]]
}

# One JSON line on stdout (audit trail) and one line for the page's "Recent" box (last 10)
event() { # event [tier] [namespace] [detail]
  jq -nc --arg event "$1" --arg tier "${2:-}" --arg namespace "${3:-}" --arg detail "${4:-}" \
    '{ts: (now | todate), event: $event, tier: $tier, namespace: $namespace, detail: $detail}'
  log+=("$(date -u +%H:%M:%S) $1${2:+ $2}${3:+ in $3}${4:+ $4}")
  if ((${#log[@]} > 10)); then log=("${log[@]:1}"); fi
}

list_grants() { api GET "$grants_path"; }

patch_secret() { api PATCH "$secret" application/merge-patch+json >/dev/null 2>&1; }

apply_grant() { # tier namespace expires
  local name="claude-elevate-$1" ns=$2 meta="$meta_def" apply="?fieldManager=claude-elevate&force=true"
  jq -n --arg ns "$ns" --arg name "$name" --arg exp "$3" "$meta"'
    {apiVersion: "v1", kind: "ServiceAccount", metadata: meta}' |
    api PATCH "/api/v1/namespaces/${ns}/serviceaccounts/${name}${apply}" application/apply-patch+yaml >/dev/null 2>&1 &&
    jq -n --arg ns "$ns" --arg name "$name" --arg exp "$3" --arg role "claude-$1" "$meta"'
      {apiVersion: "rbac.authorization.k8s.io/v1", kind: "RoleBinding", metadata: meta,
       roleRef: {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: $role},
       subjects: [{kind: "ServiceAccount", name: $name, namespace: $ns}]}' |
    api PATCH "/apis/rbac.authorization.k8s.io/v1/namespaces/${ns}/rolebindings/${name}${apply}" application/apply-patch+yaml >/dev/null 2>&1
}

request_token() { # tier namespace seconds
  jq -n --argjson s "$3" '{apiVersion: "authentication.k8s.io/v1", kind: "TokenRequest", spec: {expirationSeconds: $s}}' |
    api POST "/api/v1/namespaces/$2/serviceaccounts/claude-elevate-$1/token" application/json 2>/dev/null | jq -er .status.token
}

# the token's own exp claim must not be later than the grant's deadline (a minute of slack)
token_within() { # token minutes
  local exp
  exp="$(jq -rR 'split(".")[1] | gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - length % 4) % 4)) | @base64d | fromjson | .exp' <<<"$1")" &&
    ((exp <= $(date +%s) + $2 * 60 + 60))
}

write_kubeconfig() { # tier namespace token
  local name="$1-$2"
  TOKEN="$3" jq -n --arg name "$name" --arg ns "$2" --arg ca "${sa_dir}/ca.crt" '{
    stringData: {($name + ".kubeconfig"): ({
      apiVersion: "v1", kind: "Config", "current-context": $name,
      clusters: [{name: "cluster", cluster: {server: "https://kubernetes.default.svc", "certificate-authority": $ca}}],
      users: [{name: $name, user: {token: env.TOKEN}}],
      contexts: [{name: $name, context: {cluster: "cluster", user: $name, namespace: $ns}}]} | tojson)}}' | patch_secret
}

# deleting the ServiceAccount invalidates its tokens at once; the kubeconfig goes first, so a failure leaves a grant that is still listed and retried
remove() { # tier namespace
  local name="claude-elevate-$1"
  jq -n --arg key "$1-$2.kubeconfig" '{data: {($key): null}}' | patch_secret &&
    delete "/api/v1/namespaces/$2/serviceaccounts/${name}" &&
    delete "/apis/rbac.authorization.k8s.io/v1/namespaces/$2/rolebindings/${name}"
}

grant() { # tier namespace minutes
  local expires token why
  expires="$(jq -rn --argjson t "$(($(date +%s) + $3 * 60))" '$t | todate')"
  # a new ServiceAccount invalidates the tokens of an earlier grant
  if remove "$1" "$2" && apply_grant "$1" "$2" "$expires" &&
    token="$(request_token "$1" "$2" "$(($3 * 60))")" && token_within "$token" "$3" && write_kubeconfig "$1" "$2" "$token"; then
    event granted "$1" "$2" "until ${expires}"
  else
    why="$(jq -r '.message // empty' /tmp/last-response 2>/dev/null)"
    remove "$1" "$2"
    event grant_failed "$1" "$2" "${why:0:160}"
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

# a short-lived token of the read-only ServiceAccount claude-elevate-ui, refreshed at half its life
ui_token() {
  (($(date +%s) - $(stat -c %Y "${spool}/ui-token" 2>/dev/null || echo 0) < 1800)) && return
  local token
  token="$(request_token ui claude-system 3600)" && (umask 077 && printf '%s' "$token" >"${spool}/.ui-token.tmp") && mv "${spool}/.ui-token.tmp" "${spool}/ui-token"
}

handle() { # request file
  local body action tier minutes ns
  body="$(cat "$1")"
  rm -f "$1"
  IFS=$'\x1f' read -r action tier minutes ns < <(jq -r '[.action, .tier, .minutes, .namespace] | map(. // "" | tostring) | join("\u001f")' <<<"$body" 2>/dev/null) ||
    { event rejected "" "" "unreadable request"; return; }
  case "$action" in
    revokeall) revoke_grants requested ;;
    revoke)
      if [[ "$tier" =~ $tier_label && "$ns" =~ $dns_label ]]; then revoke "$tier" "$ns" requested; else event rejected "" "" "revoke request"; fi
      ;;
    grant)
      if [[ ! "$tier" =~ $tier_label || ! "$minutes" =~ ^[1-9][0-9]{0,3}$ ]]; then event rejected "" "" "grant request: tier or minutes"; return; fi
      while read -r ns; do
        if [[ "$ns" =~ $dns_label ]]; then grant "$tier" "$ns" "$minutes"; else event rejected "$tier" "${ns:0:63}" "invalid namespace"; fi
      done < <(jq -r '(.namespaces // [])[] | strings' <<<"$body")
      ;;
    *) event rejected "" "" "unknown action" ;;
  esac
}

while true; do
  date +%s >"${spool}/heartbeat" # the page and the liveness probe read it
  # the projected token rotates, so the header file is rewritten every pass
  (umask 077 && printf 'Authorization: Bearer %s\n' "$(cat "${sa_dir}/token")" >"$auth_header")
  ui_token
  for f in "${spool}"/req-*; do
    [[ -e "$f" ]] || continue
    # names sort by arrival; stop at a file younger than a second (Connect writes in place) so a later request never runs first
    (($(date +%s) - $(stat -c %Y "$f") >= 1)) || break
    handle "$f"
  done
  revoke_grants expired
  jq -nc '$ARGS.positional' --args "${log[@]}" >"${spool}/.recent.tmp" && mv "${spool}/.recent.tmp" "${spool}/recent"
  sleep 3
done
