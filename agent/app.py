"""The same agent as a platform-hosted Agent Manager chat agent.

Implements the Agent Manager chat-agent contract: POST /chat on port 8000,
{message, session_id} in, {response, session_id} out. Each session keeps its
conversation, so "Try It" in the console works as a chat. Agent Manager injects
the AgentID values and WALLET_MCP_URL, and instruments the process for traces.

    python app.py
"""

import logging
from uuid import uuid4

import uvicorn
from fastapi import FastAPI, HTTPException
from langgraph.checkpoint.memory import MemorySaver
from pydantic import BaseModel

from main import build_agent, wallet_tools

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("ticket-buyer")

MEMORY = MemorySaver()
app = FastAPI(title="Ticket Buyer", version="0.1.0")


class ChatRequest(BaseModel):
    message: str
    session_id: str | None = None


class ChatResponse(BaseModel):
    response: str
    session_id: str


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest) -> ChatResponse:
    session = req.session_id or uuid4().hex
    try:
        # A fresh AgentID token per turn; the conversation lives in MEMORY.
        agent = build_agent(await wallet_tools(), checkpointer=MEMORY)
        result = await agent.ainvoke(
            {"messages": [("user", req.message)]},
            {"configurable": {"thread_id": session}},
        )
    except Exception as exc:
        log.exception("agent run failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return ChatResponse(response=result["messages"][-1].content, session_id=session)


if __name__ == "__main__":
    # The chat contract fixes port 8000 (the platform also sets PORT=8080).
    uvicorn.run(app, host="0.0.0.0", port=8000)
