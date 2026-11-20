#!/usr/bin/env bash
# The new agents (the kagent Agent, and the actors of scripts/ate-actor-test.sh) are meant to reach exactly the hosts the claude-rc pod does. The Cilium policy of claude-rc is the source:
# this fails when the kagent EgressPolicy lists a different set. (scripts/ate-actor-test.sh reads the Cilium policy itself, so it cannot drift.) Needs yq.
set -euo pipefail

source_policy="k8s/apps/claude-system/networkpolicy.yaml"
agent_policy="k8s/apps/kagent-agents/egresspolicy.yaml"

want="$(yq e 'select(.metadata.name == "claude-egress-allowlist") | .spec.egress[].toFQDNs[]? | (.matchName // .matchPattern)' "${source_policy}" | tr '[:upper:]' '[:lower:]' | sort -u)"
have="$(yq e '.spec.destinations[].origin' "${agent_policy}" | sed -E 's#^https://##; s#:443$##' | tr '[:upper:]' '[:lower:]' | sort -u)"

if [ -z "${want}" ]; then
  echo "ERROR: no hosts found in the claude-egress-allowlist policy of ${source_policy}" >&2
  exit 1
fi
if [ "${want}" != "${have}" ]; then
  echo "ERROR: ${agent_policy} does not list the same hosts as claude-egress-allowlist in ${source_policy}:" >&2
  diff <(echo "${want}") <(echo "${have}") | sed 's/^</  only in the Cilium policy:/; s/^>/  only in the kagent policy:/' >&2 || true
  exit 1
fi
echo "OK: $(echo "${want}" | wc -l) hosts, the same in both"
