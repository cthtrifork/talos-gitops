#!/usr/bin/env bash
# Lists what the claude-rc pod was denied by network policy (Hubble POLICY_DENIED drops), by the DNS name in the `destination` label;
# reverse DNS only for peers without one. Read-only; run it in the pod.
# Usage: scripts/claude-drops.sh [window, default 24h]
set -euo pipefail

window="${1:-24h}"
prom="${PROMETHEUS_URL:-http://prometheus-operated.kube-prometheus-stack-system.svc:9090}"
query="sum by (destination, destination_ip, destination_namespace, destination_workload)(increase(hubble_drop_total{reason=\"POLICY_DENIED\",source_workload=\"claude-rc\"}[${window}])) > 0"

curl -sf -G "${prom}/api/v1/query" --data-urlencode "query=${query}" |
  jq -r '.data.result | sort_by(-(.value[1] | tonumber))[] |
    [(.value[1] | tonumber | floor), (.metric.destination_ip // "-"), (.metric.destination_namespace // "-"), (.metric.destination_workload // "-"), (.metric.destination // "-")] | @tsv' |
  while IFS=$'\t' read -r count ip ns workload name; do
    if [[ "$name" == "-" && "$ip" != "-" ]]; then
      name="$(getent hosts "$ip" | awk '{print $2; exit}' || true)"
      name="${name:--}"
    fi
    printf '%6s  %-16s  %-40s  %s/%s\n' "$count" "$ip" "$name" "$ns" "$workload"
  done
