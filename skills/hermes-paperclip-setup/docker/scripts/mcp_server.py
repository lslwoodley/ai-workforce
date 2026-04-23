#!/usr/bin/env python3
"""
mcp_server.py — MCP server that exposes the Hermes-Paperclip workforce as tools.

Any MCP-compatible agent (Hermes, Claude, etc.) can connect and call:
  - list_agents       — get all active workers and their status
  - assign_task       — queue a task to an agent or role
  - query_agent       — ask an agent a direct question (synchronous, returns response)
  - get_agent_memory  — fetch an agent's recent memory entries
  - spawn_agent       — create a new Hermes worker in a Paperclip role
  - escalate_to_human — create a board review item
  - get_company_goals — return current OKRs from Paperclip

Start:   python scripts/mcp_server.py
Connect: add to agent's mcp_servers config as { "transport": "http", "url": "http://localhost:8765" }

Implements the MCP 2025-03-26 spec over HTTP (streamable).
"""

import asyncio, json, os, subprocess, logging
from pathlib import Path
from typing import Any
from dotenv import load_dotenv
import httpx
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.server.streamable_http import streamable_http_server
from mcp.types import Tool, TextContent

load_dotenv(Path(__file__).parent.parent / ".env")

PAPERCLIP_API_URL = os.getenv("PAPERCLIP_API_URL", "http://localhost:3000")
PAPERCLIP_API_KEY = os.getenv("PAPERCLIP_API_KEY", "")
HERMES_SESSIONS_DIR = Path(os.getenv("HERMES_SESSIONS_DIR", Path.home() / ".hermes" / "sessions"))
MCP_SERVER_PORT = int(os.getenv("MCP_SERVER_PORT", "8765"))

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("hermes-paperclip-mcp")

PC_HEADERS = {"Authorization": f"Bearer {PAPERCLIP_API_KEY}", "Content-Type": "application/json"}

# ── Paperclip helpers ─────────────────────────────────────────────────────────

async def pc_get(path: str) -> dict:
    async with httpx.AsyncClient() as client:
        r = await client.get(f"{PAPERCLIP_API_URL}{path}", headers=PC_HEADERS, timeout=10)
        r.raise_for_status()
        return r.json()

async def pc_post(path: str, payload: dict) -> dict:
    async with httpx.AsyncClient() as client:
        r = await client.post(f"{PAPERCLIP_API_URL}{path}", json=payload, headers=PC_HEADERS, timeout=15)
        r.raise_for_status()
        return r.json()

# ── MCP server ────────────────────────────────────────────────────────────────

app = Server("hermes-paperclip")


@app.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="list_agents",
            description="Returns all active Hermes agents registered in Paperclip, including their role, department, status, model, and last-active time.",
            inputSchema={"type": "object", "properties": {}, "required": []},
        ),
        Tool(
            name="assign_task",
            description="Queue a task to a specific agent (by session ID) or to a role (Paperclip routes to the right worker). Returns the created task record.",
            inputSchema={
                "type": "object",
                "properties": {
                    "task":       {"type": "string",  "description": "Task description"},
                    "agent_id":   {"type": "string",  "description": "Target agent session ID (use this OR role)"},
                    "role":       {"type": "string",  "description": "Target role name (use this OR agent_id)"},
                    "from_agent": {"type": "string",  "description": "Session ID of the delegating agent"},
                    "priority":   {"type": "string",  "enum": ["low", "normal", "high", "urgent"], "default": "normal"},
                    "due":        {"type": "string",  "description": "Due date YYYY-MM-DD"},
                    "budget":     {"type": "number",  "description": "USD budget cap"},
                    "escalate":   {"type": "boolean", "description": "Flag for human board review", "default": False},
                },
                "required": ["task"],
            },
        ),
        Tool(
            name="query_agent",
            description="Ask a Hermes agent a direct question. The agent resumes its session, processes the query, and returns its response. Use for synchronous agent-to-agent consultation.",
            inputSchema={
                "type": "object",
                "properties": {
                    "agent_id": {"type": "string", "description": "Target agent session ID"},
                    "query":    {"type": "string", "description": "The question or prompt"},
                },
                "required": ["agent_id", "query"],
            },
        ),
        Tool(
            name="get_agent_memory",
            description="Retrieve recent memory entries from a Hermes agent's persistent memory store. Useful for understanding what context an agent has before assigning it work.",
            inputSchema={
                "type": "object",
                "properties": {
                    "agent_id": {"type": "string", "description": "Agent session ID"},
                    "last":     {"type": "integer", "description": "Number of most recent entries to return", "default": 20},
                },
                "required": ["agent_id"],
            },
        ),
        Tool(
            name="spawn_agent",
            description="Create a new Hermes worker and register it in a Paperclip role. Use when the org chart needs a new employee.",
            inputSchema={
                "type": "object",
                "properties": {
                    "role":          {"type": "string", "description": "Job title / role name"},
                    "department":    {"type": "string", "description": "Department"},
                    "session_id":    {"type": "string", "description": "Stable session ID (e.g. eng-lead-002)"},
                    "model":         {"type": "string", "description": "Model string", "default": "openrouter/anthropic/claude-3.5-sonnet"},
                    "system_prompt": {"type": "string", "description": "Optional system prompt"},
                    "budget":        {"type": "number", "description": "USD budget cap"},
                },
                "required": ["role", "department", "session_id"],
            },
        ),
        Tool(
            name="escalate_to_human",
            description="Create a board review item in Paperclip — pauses the task and notifies the human operator. Use when a decision requires human approval or exceeds agent authority.",
            inputSchema={
                "type": "object",
                "properties": {
                    "reason":      {"type": "string", "description": "Why this needs human review"},
                    "context":     {"type": "string", "description": "Relevant context the human needs to decide"},
                    "from_agent":  {"type": "string", "description": "Escalating agent session ID"},
                    "task_id":     {"type": "string", "description": "Associated Paperclip task ID, if any"},
                },
                "required": ["reason"],
            },
        ),
        Tool(
            name="get_company_goals",
            description="Returns the current OKR/goal cascade from Paperclip — board goals, department goals, and per-agent goals. Useful for agents to align their work with company strategy.",
            inputSchema={"type": "object", "properties": {}, "required": []},
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:

    # ── list_agents ──────────────────────────────────────────────────────────
    if name == "list_agents":
        data = await pc_get("/api/agents")
        return [TextContent(type="text", text=json.dumps(data, indent=2))]

    # ── assign_task ──────────────────────────────────────────────────────────
    elif name == "assign_task":
        payload = {
            "task":      arguments["task"],
            "priority":  arguments.get("priority", "normal"),
            "escalate":  arguments.get("escalate", False),
        }
        if "agent_id"   in arguments: payload["agentId"]      = arguments["agent_id"]
        if "role"       in arguments: payload["role"]          = arguments["role"]
        if "from_agent" in arguments: payload["delegatedBy"]   = arguments["from_agent"]
        if "due"        in arguments: payload["dueDate"]       = arguments["due"]
        if "budget"     in arguments: payload["budgetUsd"]     = arguments["budget"]

        result = await pc_post("/api/tasks", payload)
        return [TextContent(type="text", text=json.dumps(result, indent=2))]

    # ── query_agent ──────────────────────────────────────────────────────────
    elif name == "query_agent":
        agent_id = arguments["agent_id"]
        query    = arguments["query"]
        log.info(f"Querying agent {agent_id}: {query[:60]}")

        proc = await asyncio.create_subprocess_exec(
            "hermes", "--resume", agent_id, "-q", query,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=120)
        if proc.returncode != 0:
            raise RuntimeError(f"Hermes returned code {proc.returncode}: {stderr.decode()}")
        return [TextContent(type="text", text=stdout.decode().strip())]

    # ── get_agent_memory ─────────────────────────────────────────────────────
    elif name == "get_agent_memory":
        agent_id = arguments["agent_id"]
        last     = arguments.get("last", 20)

        # Read from Hermes session memory file
        memory_path = HERMES_SESSIONS_DIR / agent_id / "memory.json"
        if not memory_path.exists():
            return [TextContent(type="text", text=f"No memory file found for agent {agent_id}")]

        memories = json.loads(memory_path.read_text())
        if isinstance(memories, list):
            memories = memories[-last:]
        return [TextContent(type="text", text=json.dumps(memories, indent=2))]

    # ── spawn_agent ──────────────────────────────────────────────────────────
    elif name == "spawn_agent":
        # Delegate to spawn_agent.py via subprocess to keep logic DRY
        cmd = [
            "python",
            str(Path(__file__).parent / "spawn_agent.py"),
            "--role",       arguments["role"],
            "--department", arguments["department"],
            "--session-id", arguments["session_id"],
            "--model",      arguments.get("model", "openrouter/anthropic/claude-3.5-sonnet"),
        ]
        if "system_prompt" in arguments:
            cmd += ["--system-prompt", arguments["system_prompt"]]
        if "budget" in arguments:
            cmd += ["--budget", str(arguments["budget"])]

        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=60)
        output = stdout.decode()
        if proc.returncode != 0:
            raise RuntimeError(f"spawn_agent failed:\n{output}")
        return [TextContent(type="text", text=output)]

    # ── escalate_to_human ────────────────────────────────────────────────────
    elif name == "escalate_to_human":
        payload = {
            "type":    "escalation",
            "reason":  arguments["reason"],
            "context": arguments.get("context", ""),
        }
        if "from_agent" in arguments: payload["agentId"]  = arguments["from_agent"]
        if "task_id"    in arguments: payload["taskId"]   = arguments["task_id"]

        result = await pc_post("/api/board/reviews", payload)
        return [TextContent(type="text", text=json.dumps(result, indent=2))]

    # ── get_company_goals ────────────────────────────────────────────────────
    elif name == "get_company_goals":
        data = await pc_get("/api/goals")
        return [TextContent(type="text", text=json.dumps(data, indent=2))]

    else:
        raise ValueError(f"Unknown tool: {name}")


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import sys
    transport = sys.argv[1] if len(sys.argv) > 1 else "http"

    if transport == "stdio":
        # For Claude Desktop / Claude Code integration
        print("Starting hermes-paperclip MCP server (stdio)…", file=sys.stderr)
        asyncio.run(stdio_server(app))
    else:
        # HTTP for agent-to-agent calls
        print(f"Starting hermes-paperclip MCP server on http://0.0.0.0:{MCP_SERVER_PORT}")
        print("Connect via: { \"transport\": \"http\", \"url\": \"http://localhost:" + str(MCP_SERVER_PORT) + "\" }")
        asyncio.run(streamable_http_server(app, host="0.0.0.0", port=MCP_SERVER_PORT))
