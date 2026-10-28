#!/usr/bin/env bash
# Mints a ticket-buyer AgentID access token for the wallet proxy (client
# credentials, resource-indicated), as the agent itself would.
set -euo pipefail
cd "$(dirname "$0")/.."
MCP=${WALLET_MCP_URL:-http://default-default.gateway.localhost:19080/a2wp-wallet/mcp}
curl -sf http://default-idp.amp.localhost:8080/oauth2/token \
  -u "$(jq -r .clientId .secrets/amp/agentid.json):$(jq -r .clientSecret .secrets/amp/agentid.json)" \
  --data-urlencode grant_type=client_credentials --data-urlencode scope=a2wp-wallet:use \
  --data-urlencode "resource=$MCP" | jq -r .access_token
