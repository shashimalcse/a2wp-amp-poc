#!/usr/bin/env bash
# Drives the wallet directly over MCP (no gateway, no model): acquire an agent
# credential from the devstack issuer, then present it to the devstack
# verifier. Needs the port-forwards setup-wallet.sh starts (8180, 8181).
set -euo pipefail
cd "$(dirname "$0")/.."
K=${WALLET_TOKEN:-$(cat .secrets/wallet-api-key)}
URL=${WALLET_MCP_URL:-http://localhost:8180/mcp}
mcp() {
  curl -sf "$URL" -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -d "$1" | sed -n 's/^data: //p;/^{/p'
}
call() { mcp "$(jq -nc --arg n "$1" --argjson a "$2" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$n,arguments:$a}}')"; }
run() { # request -> final operation
  local op id
  op=$(call submit "$(jq -nc --arg r "$1" '{request:$r}')" | jq -c .result.structuredContent.operation)
  id=$(jq -r .id <<<"$op")
  while [[ $(jq -r .status <<<"$op") == pending ]]; do
    op=$(call get "$(jq -nc --arg id "$id" '{id:$id,wait_seconds:20}')" | jq -c .result.structuredContent.operation)
  done
  echo "$op"
}
OFFER=$(curl -sf localhost:8181/offers -d '{"configuration_ids":["agent"],"claims":{"agent_id":"ticket-buyer","agent_name":"Ticket Buyer","operator":"Acme","model":"nemotron-3-ultra"},"sd":["agent_id","agent_name","operator","model"]}' | jq -r .link)
echo "acquire: $(run "$OFFER")"
REQ=$(curl -sf localhost:8181/requests -d '{"dcql_query":{"credentials":[{"id":"agent","format":"dc+sd-jwt","meta":{"vct_values":["https://agents.example/agent-credential"]},"claims":[{"path":["agent_id"]},{"path":["operator"]}]}]}}')
echo "present: $(run "$(jq -r .link <<<"$REQ")")"
echo "verifier saw: $(curl -sf "localhost:8181/requests/$(jq -r .session_id <<<"$REQ")" | jq -c '{status,claims}')"
