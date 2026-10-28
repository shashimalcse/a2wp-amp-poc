#!/usr/bin/env bash
# The PoC end to end with the model in the loop:
#   1. the issuer offers ticket-buyer its agent credential; the agent accepts it
#   2. a verifier asks the agent to prove who it is; the agent presents
#   3. the verifier's view of what it received
# The agent reaches its wallet only through the Agent Manager MCP proxy, with
# its AgentID token. Needs the devstack port-forward (scripts/setup-wallet.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
agent() { (cd agent && uv run main.py "$1"); }

OFFER=$(curl -sf localhost:8181/offers -d '{"configuration_ids":["agent"],"claims":{"agent_id":"ticket-buyer","agent_name":"Ticket Buyer","operator":"Acme","model":"nemotron-3-ultra"},"sd":["agent_id","agent_name","operator","model"]}' | jq -r .link)
echo "== 1. credential offer"
agent "Your operator registered you and the registry sent your agent credential. Accept it: $OFFER"

REQ=$(curl -sf localhost:8181/requests -d '{"dcql_query":{"credentials":[{"id":"agent","format":"dc+sd-jwt","meta":{"vct_values":["https://agents.example/agent-credential"]},"claims":[{"path":["agent_id"]},{"path":["operator"]}]}]}}')
echo; echo "== 2. checkout asks the agent to verify itself"
agent "You are buying 2 concert tickets. At checkout the site says: \"Verify your agent\" with this link: $(jq -r .link <<<"$REQ")"

echo; echo "== 3. what the verifier received"
curl -sf "localhost:8181/requests/$(jq -r .session_id <<<"$REQ")" | jq '{status, claims}'
