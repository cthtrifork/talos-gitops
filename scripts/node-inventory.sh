#!/usr/bin/env bash
# Couples every Kubernetes node to the physical machine it runs on: model, serial, NIC MAC addresses and disks (from Talos),
# plus CPU and memory (from Kubernetes, so a node that is down still shows them). Read-only; prints a Markdown table.
# Look the MAC up in the router's DHCP lease list, or match the model/serial/disk serial against the sticker on the machine.
# Needs kubectl, talosctl and jq. Usage: scripts/node-inventory.sh [talosconfig, default talosconfig.yaml]
set -euo pipefail

talosconfig="${1:-talosconfig.yaml}"

talos() {
  local ip="$1"
  shift
  timeout 20 talosctl --talosconfig "$talosconfig" -n "$ip" "$@" 2>/dev/null
}

echo '| Node | IP | Ready | CPU | Memory | Machine | Serial | NIC (MAC) | Disks |'
echo '|---|---|---|---|---|---|---|---|---|'

kubectl get nodes -o json |
  jq -r '.items | sort_by(.metadata.name)[] |
    [.metadata.name,
     (.status.addresses[] | select(.type == "InternalIP") | .address),
     (.status.conditions[] | select(.type == "Ready") | .status),
     .status.capacity.cpu,
     ((.status.capacity.memory | sub("Ki$"; "") | tonumber / 1048576 | floor | tostring) + " GiB")] | @tsv' |
  while IFS=$'\t' read -r name ip ready cpu mem; do
    machine="unreachable"
    serial="-"
    nics="-"
    disks="-"

    if info="$(talos "$ip" get systeminformation -o json)"; then
      machine="$(jq -r '[.spec.manufacturer, .spec.productName] | map(select(. != null and . != "")) | join(" ")' <<<"$info")"
      serial="$(jq -r '.spec.serialNumber // "-" | if . == "" then "-" else . end' <<<"$info")"
      nics="$(talos "$ip" get links -o json |
        jq -rs 'map(select(.spec.busPath != null and .spec.busPath != "" and .spec.kind == "") | "\(.metadata.id) (\(.spec.hardwareAddr))") | join(", ")')"
      disks="$(talos "$ip" get disks -o json |
        jq -rs 'map(select(.spec.transport != null and .spec.transport != "" and .spec.transport != "dm") |
          "\(.metadata.id) \(.spec.model // .spec.transport) \(.spec.pretty_size) s/n \(if (.spec.serial // "") == "" then "-" else .spec.serial end)") | join("; ")')"
    fi

    echo "| ${name} | ${ip} | ${ready} | ${cpu} | ${mem} | ${machine} | ${serial} | ${nics} | ${disks} |"
  done
