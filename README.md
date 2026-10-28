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
| Role `wallet-user` | env `default`, grants `a2wp-wallet:use`, assigned to `ticket-buyer` |
| Agent `ticket-buyer` | project `default`, external, AgentID provisioned for `default` |
| Agent code | [agent/main.py](agent/main.py) |

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
```

`scripts/amp-api.sh METHOD PATH [body.json]` calls the Agent Manager API as the
quick-start's m2m client.

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

**A2WP**

4. **Gateway scopes cannot separate acquiring from presenting.** -01 has one
   `submit` tool for offers and presentation requests, so tool-level
   authorization grants both or neither. That is consistent with -01 leaving
   authorization to the wallet's policy, but it means "this agent may hold
   credentials but not present them" cannot be expressed at the gateway. This
   is evidence for the binding-agnostic, single-`submit` design, and for keeping
   access decisions in the wallet.
5. **Access protection is decided by the deployment.** Here it is AgentID and
   the gateway, with no change to the protocol. This backs keeping
   authentication out of scope in the draft.

**Wallet**

6. **Failures are opaque.** A blocked or failed outbound fetch is reported as
   `processing-error` ("Could not resolve the credential offer"), and the cause
   is not logged even at debug level. Log the underlying error server-side.

**Local networking**

7. **A pod cannot reach itself through its own Service** (no hairpin NAT on k3d
   flannel), so the devstack runs as its own pod.
8. **After a Colima restart, CoreDNS stays in `Unknown`** and cluster DNS is
   refused, so the wallet's init container hangs and the gateway runtime
   crash-loops. Delete the CoreDNS pod, restart the gateway runtime deployment,
   then re-run `scripts/setup-wallet.sh` (the devstack has a new root CA).
