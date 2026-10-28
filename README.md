# A2WP wallet behind WSO2 Agent Manager (PoC)

An agent registered in WSO2 Agent Manager 1.0 uses its own A2WP wallet
([../a2wp-wallet](../a2wp-wallet)) as an MCP server. It reaches the wallet only
through the Agent Manager AI Gateway, authenticated with its AgentID. The model
is Nemotron 3 Ultra on OpenRouter.

```
 ticket-buyer agent (LangGraph, Nemotron 3 Ultra via OpenRouter)
   │ 1. client_credentials + resource=<proxy URL>  ──▶ ThunderID (AgentID)
   │ 2. MCP + Bearer AgentID token
   ▼
 Agent Manager AI Gateway  /a2wp-wallet/mcp
   │  mcp-auth: validates the AgentID JWT
   │  mcp-authz: tool needs scope a2wp-wallet:use (role wallet-user)
   │  set-headers: Authorization: Bearer <wallet API key>
   ▼
 a2wp-walletd (k3d, ns a2wp) ──OpenID4VCI──▶ devstack issuer
                             ──OpenID4VP───▶ devstack verifier
```

## What is set up

| Piece | Where |
|---|---|
| Agent Manager 1.0.0 | k3d cluster `amp-local` on the Colima profile `agent-manager` (quick-start install) |
| Wallet + dev issuer/verifier | [k8s/wallet.yaml](k8s/wallet.yaml), [scripts/setup-wallet.sh](scripts/setup-wallet.sh) |
| MCP proxy `a2wp-wallet` | org `default`, upstream `http://wallet.a2wp.example/mcp`, OAuth (AgentID) security |
| Scope `a2wp-wallet:use` | covers `submit`, `get`, `cancel` |
| Role `wallet-user` | env `default`, grants `a2wp-wallet:use`, assigned to `ticket-buyer` and `ticket-buyer-hosted` |
| Agent `ticket-buyer` | project `default`, external, AgentID provisioned for `default`; runs on your machine (CLI, demo scripts) |
| Agent `ticket-buyer-hosted` | project `default`, platform-hosted chat agent built from this repo (`/agent`, `python app.py`), auto-instrumented |
| Agent code | [agent/main.py](agent/main.py) (CLI), [agent/app.py](agent/app.py) (chat API for hosting) |

Secrets live in `.secrets/` (gitignored): wallet admin tokens, the wallet API key
the gateway sends upstream, the agent's AgentID client secret
(`.secrets/agent.env`). `agent/.env` holds only `OPENROUTER_API_KEY`.

## Run it

```sh
./scripts/wallet-smoke.sh                       # wallet directly, no gateway, no model
WALLET_TOKEN=$(./scripts/agentid-token.sh) \
WALLET_MCP_URL=http://default-default.gateway.localhost:19080/a2wp-wallet/mcp \
  ./scripts/wallet-smoke.sh                     # through the gateway, no model
./scripts/demo.sh                               # through the gateway, with Nemotron
./scripts/demo-manual.sh                        # the same, one step at a time
```

`scripts/amp-api.sh METHOD PATH [body.json]` calls the Agent Manager API as the
quick-start's m2m client.

### Platform-hosted, with traces

Traces appear only for `ticket-buyer-hosted`: Agent Manager instruments the
agents it hosts, and the external `ticket-buyer` sends none. In the console
(http://console.amp.localhost:8080), open **Ticket Buyer (hosted)** → **Try It**
and paste what the devstack hands out, in one chat session:

```sh
curl -s localhost:8181/offers -d '{"configuration_ids":["agent"],"claims":{"agent_id":"ticket-buyer","agent_name":"Ticket Buyer","operator":"Acme","model":"nemotron-3-ultra"},"sd":["agent_id","agent_name","operator","model"]}' | jq -r .link
curl -s localhost:8181/requests -d '{"dcql_query":{"credentials":[{"id":"agent","format":"dc+sd-jwt","meta":{"vct_values":["https://agents.example/agent-credential"]},"claims":[{"path":["agent_id"]},{"path":["operator"]}]}]}}' | jq -r .link
```

Then open **Traces**. A push to `main` does not rebuild it; trigger a build
with `scripts/amp-api.sh POST /orgs/default/projects/default/agents/ticket-buyer-hosted/builds`.

## Results

| Check | Result |
|---|---|
| Agent Manager discovers the wallet's tools (`fetch-server-info`) | `submit`, `get`, `cancel` |
| AgentID token, scope `a2wp-wallet:use`, gateway → wallet acquire | completed |
| Same path, present | completed; verifier got `agent_id`, `operator` only |
| No token | 401 at the gateway |
| Token without the scope | 403 at the gateway |
| Role unassigned → new token has no scope → call | 403; reassigning restores access |
| Nemotron agent end to end (`scripts/demo.sh`) | completed: the model passed the offer and the request to `submit` unchanged, polled `get` once each, and reported the continuation; the verifier got `agent_id`, `operator` only |
| Platform-hosted agent, acquire then present in one chat session | completed; the verifier got `agent_id`, `operator` only |
| Traces for the hosted agent (observer API) | one trace per `POST /chat`, 37 spans, no errors: model calls, MCP `submit`/`get`, HTTP |

## Findings

**Agent Manager**

1. **The MCP proxy refuses private upstreams.** `fetch-server-info` and proxy
   creation reject any URL whose host resolves to a non-public IP
   (`utils/ssrf`), with no override. An MCP server running beside Agent Manager,
   such as a wallet on the same cluster, cannot be registered. The PoC works
   around it inside the cluster only ([k8s/wallet-public.yaml](k8s/wallet-public.yaml):
   a CoreDNS entry and a Service externalIP on 192.88.99.10). A real deployment
   needs an allow-list for internal upstreams, or a public wallet URL.
2. **The quick-start installer fails on macOS bash 3.2.** It stops at step 7 with
   `CP_HELM_ARGS[@]: unbound variable`, because an empty array under `set -u`
   is an error before bash 4.4. Re-running it with Homebrew bash 5 completes.
3. **The wallet does not learn which agent is calling.** The gateway validates
   the AgentID token and then replaces `Authorization` with one static upstream
   credential. The wallet sees the proxy, not the agent, so one proxy maps to one
   wallet. A per-agent wallet behind one proxy needs the gateway to forward the
   agent's identity (the token, or a signed `sub` header), which the wallet's
   OAuth mode could then bind (`oauth-bindings`).
4. **A hosted agent is handed an MCP proxy URL it cannot reach.** The MCP
   config injects the proxy's public URL (`default-default.gateway.localhost:19080`),
   which is not reachable from pods in the quick-start, while the OTel and
   token endpoints it injects are in-cluster URLs. The agent connects to the
   gateway's internal URL (`WALLET_MCP_ENDPOINT`) and keeps the public URL as
   the token's `resource`; the AgentID token endpoint issues no token for any
   other resource.
5. **The platform sets `PORT=8080` but probes port 8000**, the chat contract's
   port. An agent that honours `PORT` never becomes ready.
6. **Traces need hosting.** Only platform-hosted agents are instrumented; an
   external agent must bring its own OpenTelemetry setup to appear in Traces.

**A2WP**

7. **Gateway scopes cannot separate acquiring from presenting.** -01 has one
   `submit` tool for offers and presentation requests, so tool-level
   authorization grants both or neither. That is consistent with -01 leaving
   authorization to the wallet's policy, but it means "this agent may hold
   credentials but not present them" cannot be expressed at the gateway. This
   is evidence for the binding-agnostic, single-`submit` design, and for keeping
   access decisions in the wallet.
8. **Access protection is decided by the deployment.** Here it is AgentID and
   the gateway, with no change to the protocol. This backs keeping
   authentication out of scope in the draft.
9. **Whatever the Agent passes through is recorded.** The traces store the chat
   input and the tool arguments, so the credential offer with its
   pre-authorized code sits in the observability store. Presentations and
   credentials never appear there, which is the point of "never return
   presentations"; but an offer is a bearer secret in transit, so it needs to be
   single use and short-lived, or protected with a `tx_code`.

**Wallet**

10. **Failures are opaque.** A blocked or failed outbound fetch is reported as
   `processing-error` ("Could not resolve the credential offer"), and the cause
   is not logged even at debug level. Log the underlying error server-side.

**Local networking**

11. **A pod cannot reach itself through its own Service** (no hairpin NAT on k3d
    flannel), so the devstack runs as its own pod.
12. **After a Colima restart, CoreDNS stays in `Unknown`** and cluster DNS is
    refused, so the wallet's init container hangs and the gateway runtime
    crash-loops. Delete the CoreDNS pod, restart the gateway runtime deployment,
    then re-run `scripts/setup-wallet.sh` (the devstack has a new root CA).
    The restart also drops `host.k3d.internal` from CoreDNS `NodeHosts` and the
    node's `/etc/hosts` (k3d adds it only when it starts the cluster itself),
    so agent builds fail to push to the local registry. Add
    `172.18.0.1 host.k3d.internal` to both.
