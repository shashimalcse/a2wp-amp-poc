#!/usr/bin/env bash
# Deploys the wallet platform into the Agent Manager k3d cluster and creates
# one organization, its owner, one wallet for the agent and that wallet's API
# key. Secrets land in .secrets/ (gitignored); nothing secret is printed.
#
# Needs: the amp-local k3d cluster, the a2wp-wallet:poc image (see Dockerfile).
set -euo pipefail
cd "$(dirname "$0")/.."
SECRETS=.secrets
mkdir -p "$SECRETS" && chmod 700 "$SECRETS"
NS=a2wp
DEVSTACK_HOST=devstack.$NS.svc.cluster.local
VCT=https://agents.example/agent-credential
API=http://localhost:8180/admin/v1

log() { printf '\033[0;34m[wallet]\033[0m %s\n' "$*"; }

log "importing image into k3d"
k3d image import a2wp-wallet:poc -c amp-local >/dev/null

kubectl apply -f k8s/wallet.yaml >/dev/null
if ! kubectl -n $NS get secret wallet-master-key >/dev/null 2>&1; then
  log "creating master key"
  kubectl -n $NS create secret generic wallet-master-key \
    --from-literal=key="$(head -c 32 /dev/urandom | base64)" >/dev/null
fi
# The devstack mints a new root CA on every start; the wallet picks it up on its own restart.
kubectl -n $NS rollout restart deploy/devstack >/dev/null
kubectl -n $NS rollout status deploy/devstack --timeout=180s
kubectl -n $NS rollout restart deploy/wallet >/dev/null
kubectl -n $NS rollout status deploy/wallet --timeout=180s

if [[ ! -s $SECRETS/platform-token ]]; then
  log "bootstrapping platform"
  kubectl -n $NS exec deploy/wallet -c wallet -- /a2wp-walletd bootstrap \
    | grep -o 'a2wpa_[A-Za-z0-9._-]*' | head -1 > $SECRETS/platform-token
fi

pkill -f 'port-forward.*svc/wallet 8180' 2>/dev/null || true
kubectl -n $NS port-forward svc/wallet 8180:8080 >/dev/null 2>&1 &
for _ in $(seq 30); do curl -sf -o /dev/null http://localhost:8180/healthz && break; sleep 1; done

req() { # method path token [body]
  curl -sf -X "$1" "$API$2" -H "Authorization: Bearer $3" ${4:+-d "$4"}
}

if [[ ! -s $SECRETS/org.json ]]; then
  log "creating organization, owner, wallet and agent key"
  req POST /orgs "$(cat $SECRETS/platform-token)" '{"slug":"acme","name":"Acme"}' > $SECRETS/org.json
  ORG=$(jq -r .org.id $SECRETS/org.json); OT=$(jq -r .admin_token $SECRETS/org.json)
  head -c 12 /dev/urandom | base64 | tr -d '/+=' > $SECRETS/owner-passcode
  req POST /orgs/$ORG/members "$OT" \
    "$(jq -nc --arg p "$(cat $SECRETS/owner-passcode)" '{email:"ada@acme.example",display_name:"Ada",role:"owner",passcode:$p}')" \
    > $SECRETS/member.json
  MEM=$(jq -r '.member.id // .id' $SECRETS/member.json)
  req POST /orgs/$ORG/wallets "$OT" "$(jq -nc --arg o "$MEM" '{owner_id:$o,agent_name:"ticket-buyer"}')" > $SECRETS/wallet.json
  WAL=$(jq -r '.wallet.id // .id' $SECRETS/wallet.json)
  req POST /orgs/$ORG/wallets/$WAL/keys "$OT" '{"name":"agent-manager gateway"}' | jq -r .api_key > $SECRETS/wallet-api-key
fi
ORG=$(jq -r .org.id $SECRETS/org.json); OT=$(jq -r .admin_token $SECRETS/org.json)

log "setting policy (trusting the current devstack root CA)"
pkill -f 'port-forward.*svc/devstack 8181' 2>/dev/null || true
kubectl -n $NS port-forward svc/devstack 8181:8081 >/dev/null 2>&1 &
ROOT=""
for _ in $(seq 30); do ROOT=$(curl -sf http://localhost:8181/root.pem) && break; sleep 1; done
[[ -n $ROOT ]] || { echo "could not fetch the devstack root CA" >&2; exit 1; }
req PUT /orgs/$ORG/policy "$OT" "$(jq -nc --arg root "$ROOT" --arg h "$DEVSTACK_HOST" --arg vct "$VCT" '{
  issuers:   [{issuer: ("https://" + $h + ":8443/vci"), vcts: [$vct]}],
  verifiers: [{client_id: ("x509_san_dns:" + $h), name: "Lantern Tickets (devstack)",
               claims: ["agent_id", "agent_name", "operator"]}],
  approval:  {presentation: "never", issuance: "never"},
  trust_anchors: [$root]
}')" >/dev/null

log "done: MCP upstream for the proxy is http://wallet.$NS.svc.cluster.local:8080/mcp"
log "      the gateway's backend header is in $SECRETS/wallet-api-key (Authorization: Bearer <key>)"
