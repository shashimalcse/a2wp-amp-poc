#!/usr/bin/env bash
# Calls the local Agent Manager API as the platform's m2m client (the quick-start
# install's chart default credentials; local development only).
#
#   scripts/amp-api.sh GET  /orgs
#   scripts/amp-api.sh POST /orgs/default/mcp-proxies body.json
set -euo pipefail
THUNDER=${AMP_THUNDER_URL:-http://thunder.amp.localhost:8080}
API=${AMP_API_URL:-http://api.amp.localhost:8080/api/v1}
SCOPES=$(kubectl -n wso2-amp get cm amp-api -o jsonpath='{.data.OAUTH_SCOPES_SUPPORTED}' | tr ',' ' ')
TOKEN=$(curl -sf "$THUNDER/oauth2/token" -u amp-api-client:amp-api-client-secret \
  --data-urlencode grant_type=client_credentials --data-urlencode "scope=$SCOPES" | jq -r .access_token)
method=$1 path=$2 body=${3:-}
curl -sS -X "$method" "$API$path" -H "Authorization: Bearer $TOKEN" \
  ${body:+-H 'Content-Type: application/json' --data-binary @"$body"}
