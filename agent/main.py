"""An agent that uses its own A2WP wallet through the Agent Manager MCP proxy.

    uv run main.py "Accept this credential offer: openid-credential-offer://..."
    uv run main.py "A site asks you to prove who you are: openid4vp://..."

The model (Nemotron 3 Ultra on OpenRouter) only sees the wallet's tools and
operation states. Credentials, presentations and keys stay in the wallet.

Settings come from the environment, from .env next to this file, or from
../.secrets/agent.env (which the PoC setup writes):

    OPENROUTER_API_KEY          the model key
    WALLET_MCP_URL              the proxy's gateway URL for this environment
    WALLET_MCP_RESOURCE         the proxy's public URL, the AgentID token's
                                resource (default WALLET_MCP_URL; differs when
                                the agent is platform-hosted and calls the
                                gateway's internal URL)
    WALLET_MCP_API_KEY          when the proxy uses API-key security
    AMP_AGENTID_CLIENT_ID       when the proxy uses OAuth (AgentID) security,
    AMP_AGENTID_CLIENT_SECRET   the four AgentID values Agent Manager shows
    AMP_AGENTID_TOKEN_ENDPOINT  (or injects, for a platform-hosted agent)
    AMP_AGENTID_SCOPES
"""

import asyncio
import json
import os
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv
from langchain_mcp_adapters.client import MultiServerMCPClient
from langchain_openai import ChatOpenAI
from langgraph.prebuilt import create_react_agent
from pydantic import SecretStr

load_dotenv(Path(__file__).with_name(".env"))
load_dotenv(Path(__file__).parent.parent / ".secrets" / "agent.env")

MODEL = os.environ.get("AGENT_MODEL", "nvidia/nemotron-3-ultra-550b-a55b")

SYSTEM = """You are an autonomous agent with your own credential wallet, reachable through
the wallet tools. When you are given a credential offer or a presentation request,
pass it to the wallet exactly as received and follow the operation until it is
finished. Never invent or edit offers or requests. When an operation completes
with a continuation, report it. Report the outcome briefly."""


def wallet_headers(url: str) -> dict[str, str]:
    if key := os.environ.get("WALLET_MCP_API_KEY"):
        return {"API-Key": key, "Authorization": ""}
    resp = httpx.post(
        os.environ["AMP_AGENTID_TOKEN_ENDPOINT"],
        auth=(os.environ["AMP_AGENTID_CLIENT_ID"], os.environ["AMP_AGENTID_CLIENT_SECRET"]),
        data={
            "grant_type": "client_credentials",
            "scope": os.environ.get("AMP_AGENTID_SCOPES", ""),
            "resource": os.environ.get("WALLET_MCP_RESOURCE") or url,
        },
        verify=os.environ.get("AMP_CA_FILE", True),
        timeout=30,
    )
    resp.raise_for_status()
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


async def wallet_tools():
    url = os.environ["WALLET_MCP_URL"]
    client = MultiServerMCPClient(
        {"wallet": {"url": url, "transport": "streamable_http", "headers": wallet_headers(url)}}
    )
    return await client.get_tools()


def build_agent(tools, checkpointer=None):
    llm = ChatOpenAI(
        model=MODEL,
        base_url="https://openrouter.ai/api/v1",
        api_key=SecretStr(os.environ["OPENROUTER_API_KEY"]),
        temperature=0,
    )
    return create_react_agent(llm, tools, prompt=SYSTEM, checkpointer=checkpointer)


async def run(task: str) -> None:
    tools = await wallet_tools()
    print("tools:", ", ".join(t.name for t in tools), file=sys.stderr)

    agent = build_agent(tools)
    async for step in agent.astream({"messages": [("user", task)]}, stream_mode="updates"):
        for node, update in step.items():
            for msg in update.get("messages", []):
                for call in getattr(msg, "tool_calls", None) or []:
                    print(f"[{node}] call {call['name']} {json.dumps(call['args'])}", file=sys.stderr)
                if msg.type == "tool":
                    print(f"[tool] {msg.content}", file=sys.stderr)
                elif msg.type == "ai" and msg.content:
                    print(msg.content)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    asyncio.run(run(sys.argv[1]))
