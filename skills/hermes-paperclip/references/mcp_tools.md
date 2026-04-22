# MCP Tools Reference

This document describes all tools exposed by `scripts/mcp_server.py` for agent-to-agent use.

## Connecting to the server

Add this to any Hermes agent's config (`~/.hermes/config.json`):

```json
{
  "mcp_servers": [
    {
      "name": "hermes-paperclip",
      "transport": "http",
      "url": "http://localhost:8765"
    }
  ]
}
```

For Claude Desktop or Claude Code:

```json
{
  "mcpServers": {
    "hermes-paperclip": {
      "command": "python",
      "args": ["/path/to/skills/hermes-paperclip/scripts/mcp_server.py", "stdio"]
    }
  }
}
```

---

## Tool: `list_agents`

Returns all active Hermes workers registered in Paperclip.

**Input:** none

**Output example:**
```json
{
  "agents": [
    {
      "id": "ceo-001",
      "sessionId": "ceo-001",
      "role": "CEO",
      "department": "executive",
      "status": "working",
      "model": "openrouter/anthropic/claude-3.5-sonnet",
      "lastActiveAt": "2026-04-22T14:30:00Z"
    }
  ]
}
```

---

## Tool: `assign_task`

Queue a task to a specific agent or role.

**Input:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| task | string | ✓ | Task description |
| agent_id | string | one of | Target agent session ID |
| role | string | one of | Target role (Paperclip resolves to agent) |
| from_agent | string | | Delegating agent session ID (for audit trail) |
| priority | string | | `low \| normal \| high \| urgent` |
| due | string | | Due date YYYY-MM-DD |
| budget | number | | USD cap |
| escalate | boolean | | Flag for human board review |

**Output:** Created task record including `id`, `status: "queued"`.

**Example — agent delegating to another agent:**
```
assign_task(
  task="Write a market analysis report for Q2",
  role="Head of Research",
  from_agent="ceo-001",
  priority="high",
  due="2026-04-25",
  budget=10.00
)
```

---

## Tool: `query_agent`

Ask a Hermes agent a direct question. Synchronous — waits for the response.

**Input:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| agent_id | string | ✓ | Target agent session ID |
| query | string | ✓ | The question or prompt |

**Output:** Agent's text response (string).

**Timeout:** 120 seconds.

**Use this for:** Fast consultations where you need an answer before continuing. For non-blocking delegation use `assign_task` instead.

---

## Tool: `get_agent_memory`

Fetch recent memory entries from a Hermes agent.

**Input:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| agent_id | string | ✓ | Agent session ID |
| last | integer | | Number of entries (default: 20) |

**Output:** Array of memory objects from the agent's `memory.json`.

---

## Tool: `spawn_agent`

Create a new Hermes worker and register it in Paperclip.

**Input:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| role | string | ✓ | Job title |
| department | string | ✓ | Department name |
| session_id | string | ✓ | Stable session ID (e.g. `eng-lead-002`) |
| model | string | | Model string (default: claude-3.5-sonnet via OpenRouter) |
| system_prompt | string | | Role-specific system prompt |
| budget | number | | USD budget cap |

**Note:** This requires board approval in Paperclip's governance layer — the new agent won't activate until a human approves it.

---

## Tool: `escalate_to_human`

Create a board review item. The task pauses until the human acts.

**Input:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| reason | string | ✓ | Why this needs human review |
| context | string | | Background the human needs |
| from_agent | string | | Escalating agent session ID |
| task_id | string | | Associated task ID |

---

## Tool: `get_company_goals`

Returns the current OKR/goal cascade from Paperclip.

**Input:** none

**Output:**
```json
{
  "board_goals": [...],
  "departments": {
    "engineering": { "goals": [...] },
    "marketing":   { "goals": [...] }
  },
  "agents": {
    "ceo-001": { "goals": [...] }
  }
}
```

Use this at the start of a task to align work with current company strategy.
