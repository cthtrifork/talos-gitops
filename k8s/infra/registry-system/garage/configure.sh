#!/bin/sh
# Garage layout for the zot store: one zone per node, the bucket and the key. Idempotent.
set -e

SERVICE_DNS=garage-headless.registry-system.svc.cluster.local
CAPACITY=100Gi
REPLICAS="0 1 2"

# The node id of a pod, once its admin API answers
get_node_id() {
  while true; do
    RESPONSE=$(wget -q -O - --header "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
      "http://$1:3903/v2/GetNodeInfo?node=self" 2>/dev/null) || true
    ID=$(printf '%s' "$RESPONSE" | sed -n -E 's/.*"nodeId":\s*"([a-fA-F0-9]+)".*/\1/p' | head -n 1)
    if [ -n "$ID" ]; then
      echo "$ID"
      return 0
    fi
    echo "Waiting for $1..." >&2
    sleep 5
  done
}

COORD_HOST="garage-0.${SERVICE_DNS}"
GARAGE_RPC_HOST="$(get_node_id "$COORD_HOST")@${COORD_HOST}:3901"
run_garage() {
  /shared/garage -h "$GARAGE_RPC_HOST" "$@"
}

# one zone per pod, the same capacity on each
for i in $REPLICAS; do
  NODE_ID=$(get_node_id "garage-$i.${SERVICE_DNS}")
  echo "Assigning garage-$i ($NODE_ID) to zone z$i"
  run_garage layout assign -z "z$i" -c "$CAPACITY" "$NODE_ID" || true
done
run_garage layout show
CURRENT_VERSION=$(run_garage layout show | grep "Current cluster layout version" | awk '{print $5}')
if [ -n "$CURRENT_VERSION" ]; then
  run_garage layout apply --version $((CURRENT_VERSION + 1)) || true
fi

run_garage bucket create zot 2>/dev/null || true

# GK plus 24 hex characters, and 64 hex characters, are what Garage accepts
if ! echo "$KEY_ID" | grep -qE '^GK[0-9a-fA-F]{24}$'; then
  echo "ERROR: the key id must be GK followed by 24 hex characters"
  exit 1
fi
if ! echo "$SECRET_KEY" | grep -qE '^[0-9a-fA-F]{64}$'; then
  echo "ERROR: the secret key must be 64 hex characters"
  exit 1
fi
run_garage key import "$KEY_ID" "$SECRET_KEY" --yes -n zot || true
run_garage bucket allow zot --key "$KEY_ID" --read --write
echo "Done."
