#!/usr/bin/env bash
# demo.sh, one step at a time, for watching by hand. Each step shows what is
# about to happen and waits for Enter. At each agent step you can type your own
# instruction instead of the default one (the link is appended to it).
set -euo pipefail
cd "$(dirname "$0")/.."
MCP=http://default-default.gateway.localhost:19080/a2wp-wallet/mcp
agent() { (cd agent && uv run main.py "$1" 2> >(grep -v -E 'Deprecat|create_react_agent' >&2)); }
step() { printf '\n\033[1;34m== %s\033[0m\n' "$1"; }
pause() { read -r -p $'\033[2m[Enter to continue]\033[0m '; }
ask() { # default task -> task
  local t
  printf '\033[2mDefault: %s\033[0m\n' "$1" >&2
  read -r -p "Your instruction (Enter for default): " t
  echo "${t:-$1}"
}

step "0. The gateway refuses calls without an AgentID token"
curl -s -o /dev/null -w "POST $MCP -> %{http_code}\n" "$MCP" -H 'Content-Type: application/json' -d '{}'
pause

step "1. The registry issues ticket-buyer a credential offer"
OFFER=$(curl -sf localhost:8181/offers -d '{"configuration_ids":["agent"],"claims":{"agent_id":"ticket-buyer","agent_name":"Ticket Buyer","operator":"Acme","model":"nemotron-3-ultra"},"sd":["agent_id","agent_name","operator","model"]}' | jq -r .link)
echo "$OFFER"
TASK=$(ask "Your operator registered you and the registry sent your agent credential. Accept it:")
pause
agent "$TASK $OFFER"

step "2. At checkout, the ticket site asks the agent to verify itself"
REQ=$(curl -sf localhost:8181/requests -d '{"dcql_query":{"credentials":[{"id":"agent","format":"dc+sd-jwt","meta":{"vct_values":["https://agents.example/agent-credential"]},"claims":[{"path":["agent_id"]},{"path":["operator"]}]}]}}')
LINK=$(jq -r .link <<<"$REQ")
echo "The site asks for agent_id and operator only: $LINK"
TASK=$(ask "You are buying 2 concert tickets. At checkout the site says \"Verify your agent\" with this link:")
pause
agent "$TASK $LINK"

step "3. What the verifier received"
curl -sf "localhost:8181/requests/$(jq -r .session_id <<<"$REQ")" | jq '{status, claims}'
