#!/usr/bin/env bash
# The new agents (the kagent Agent, and the actors of scripts/ate-actor-test.sh) are meant to reach exactly the hosts the claude-rc pod does. The Cilium policy of claude-rc is the source:
# this fails when the kagent EgressPolicy lists a different set. (scripts/ate-actor-test.sh reads the Cilium policy itself, so it cannot drift.) One difference is allowed: a credential
# needs an exact origin, so the kagent policy may list a host (api.github.com) that a wildcard of the Cilium policy (*.github.com) already covers, one label deep. Needs yq.
set -euo pipefail

source_policy="k8s/apps/claude-system/networkpolicy.yaml"
agent_policy="k8s/apps/kagent-agents/egresspolicy.yaml"

want="$(yq e 'select(.metadata.name == "claude-egress-allowlist") | .spec.egress[].toFQDNs[]? | (.matchName // .matchPattern)' "${source_policy}" | tr '[:upper:]' '[:lower:]' | sort -u)"
have="$(yq e '.spec.destinations[].origin' "${agent_policy}" | sed -E 's#^https://##; s#:443$##' | tr '[:upper:]' '[:lower:]' | sort -u)"

if [ -z "${want}" ]; then
  echo "ERROR: no hosts found in the claude-egress-allowlist policy of ${source_policy}" >&2
  exit 1
fi
covered_by_wildcard() { # host, patterns on stdin: true when a "*.<suffix>" pattern matches exactly one more label
  local host="$1" pattern suffix label
  while read -r pattern; do
    case "${pattern}" in
      '*.'*)
        suffix="${pattern#\*.}"
        label="${host%."${suffix}"}"
        if [ "${label}" != "${host}" ] && [ -n "${label}" ] && [ "${label#*.}" = "${label}" ]; then return 0; fi
        ;;
    esac
  done
  return 1
}

missing="$(comm -23 <(echo "${want}") <(echo "${have}"))"
extra=""
while read -r host; do
  [ -n "${host}" ] || continue
  covered_by_wildcard "${host}" <<<"${want}" || extra="${extra}${host}"$'\n'
done < <(comm -13 <(echo "${want}") <(echo "${have}"))

if [ -n "${missing}" ] || [ -n "${extra}" ]; then
  echo "ERROR: ${agent_policy} does not list the same hosts as claude-egress-allowlist in ${source_policy}:" >&2
  while read -r host; do [ -z "${host}" ] || echo "  only in the Cilium policy: ${host}" >&2; done <<<"${missing}"
  while read -r host; do [ -z "${host}" ] || echo "  only in the kagent policy (and not covered by a wildcard): ${host}" >&2; done <<<"${extra}"
  exit 1
fi
echo "OK: $(echo "${want}" | wc -l) hosts, the same in both"
