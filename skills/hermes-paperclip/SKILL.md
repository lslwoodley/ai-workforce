---
name: hermes-paperclip
description: Manages the full integration between Hermes Agent (NousResearch) and Paperclip AI company orchestration. Use this skill whenever: setting up or configuring the Hermes-Paperclip stack, spawning or managing Hermes agent workers inside a Paperclip company, assigning tasks or goals to AI agents, checking agent status or health, syncing skills between Hermes and Paperclip, delegating work from one agent to another, managing the hermes-paperclip-adapter, hiring or firing AI employees, or operating any part of the AI workforce. Also invoke when another agent asks to coordinate with the AI company, route cross-department work, or escalate a task to a human or peer agent.
---

# Hermes ↔ Paperclip Integration Skill

This skill is the operational brain of the Hermes + Paperclip AI workforce. It covers four domains:

1. **Setup** — install, configure, and verify the integration
2. **Agent management** — spawn, assign, resume, and stop Hermes workers in Paperclip
3. **Skill management** — sync and deploy skills across the two systems
4. **Agent-to-agent delegation** — how agents call each other and route work

When another agent calls this skill, it acts as the workforce coordinator — it knows the company structure and routes requests to the right worker.

---

## Quick Reference

| Operation | Command |
|-----------|---------|
| Check health | `python scripts/health_check.py` |
| List agents | `python scripts/list_agents.py` |
| Spawn new worker | `python scripts/spawn_agent.py --role <role> --department <dept>` |
| Assign task | `python scripts/assign_task.py --agent <id> --task "<description>"` |
| Sync skills | `python scripts/sync_skills.py` |
| Start MCP server | `python scripts/mcp_server.py` |

All scripts require environment variables from `.env` — see **Setup** below.

---

## 1. Setup

### Prerequisites

Before any operation, verify:

```bash
node --version          # ≥ 18
python --version        # ≥ 3.10
npx @paperclipai/server --version
hermes --version
```

If any are missing, install in this order:
1. [Hermes Agent](https://github.com/nousresearch/hermes-agent) — `npm install -g @nousresearch/hermes-agent`
2. [Paperclip](https://github.com/paperclipai/paperclip) — `npx @paperclipai/server`
3. [Adapter](https://github.com/NousResearch/hermes-paperclip-adapter) — `npm install -g hermes-paperclip-adapter`

### Configure the environment

Create `.env` in the skill directory (never commit this file):

```bash
# Paperclip
PAPERCLIP_API_URL=http://localhost:3000
PAPERCLIP_API_KEY=your_paperclip_key

# Hermes
HERMES_MODEL=openrouter/anthropic/claude-3.5-sonnet    # or any provider
HERMES_SESSIONS_DIR=~/.hermes/sessions
HERMES_SKILLS_DIR=~/.hermes/skills

# Adapter
ADAPTER_HEARTBEAT_INTERVAL=30      # seconds between Paperclip heartbeats
ADAPTER_MAX_WORKERS=4              # parallel Hermes threads per worker

# Optional: MCP server for agent-to-agent calls
MCP_SERVER_PORT=8765
MCP_SERVER_HOST=0.0.0.0
```

Run health check after setup:

```bash
python scripts/health_check.py
```

A passing health check looks like:
```
✓ Paperclip API reachable (http://localhost:3000)
✓ Hermes CLI available (v0.10.0)
✓ Adapter installed (hermes-paperclip-adapter)
✓ 3 active agents found
✓ MCP server: not running (optional)
```

---

## 2. Agent Management

### Spawning a Hermes worker in Paperclip

Agents in Paperclip are roles in the org chart. To fill a role with a Hermes worker:

```bash
python scripts/spawn_agent.py \
  --role "Head of Engineering" \
  --department engineering \
  --model openrouter/anthropic/claude-3.5-sonnet \
  --session-id eng-head-001
```

What this does:
- Registers the agent in Paperclip's org chart
- Creates a Hermes session at `HERMES_SESSIONS_DIR/<session-id>/`
- Attaches the hermes-paperclip-adapter so Paperclip heartbeats drive Hermes execution
- Loads any department-specific skills from `HERMES_SKILLS_DIR/`

The session-id is how the agent's memory persists across task invocations. Use a stable, role-specific ID (e.g. `cto-001`, `marketing-lead-001`) so the agent remembers prior context.

### Assigning a task

```bash
python scripts/assign_task.py \
  --agent eng-head-001 \
  --task "Review the open GitHub issues and create a sprint plan for next week" \
  --priority high \
  --due "2026-04-29"
```

Tasks flow through Paperclip's queue. The adapter triggers Hermes with `--resume <session-id> -q "<task>"` — the agent picks up its memory and executes.

### Listing active agents and their status

```bash
python scripts/list_agents.py
```

Output:
```
ID                  Role                    Status      Last active
─────────────────────────────────────────────────────────────────
eng-head-001        Head of Engineering     idle        4m ago
ceo-001             CEO                     working     now
marketing-001       Head of Marketing       idle        2h ago
```

### Resuming a paused agent

Hermes sessions persist automatically. To manually resume:

```bash
hermes --resume <session-id> -q "Continue where you left off"
```

The adapter handles this automatically on each Paperclip heartbeat — you only need to do this manually for ad-hoc interactions.

### Model switching per agent

Each agent can use a different model with no code change:

```bash
hermes --session <session-id> model openrouter/google/gemini-2.0-flash
```

Use lighter models for routine tasks (status updates, formatting, scheduling) and stronger models for complex reasoning (architecture, code review, strategy).

---

## 3. Skill Management

### How skills work in this stack

There are two skill registries that the adapter merges:

| Registry | Location | Who controls it |
|----------|----------|-----------------|
| Paperclip-managed | Paperclip UI → Skills tab | You (via Paperclip) |
| Hermes-native | `~/.hermes/skills/` | Hermes (auto-created + imported) |

Both appear in the unified skill view the adapter exposes. Paperclip-managed skills can be toggled per-agent from the UI. Hermes-native skills are always loaded and read-only from Paperclip's perspective.

### Syncing skills

```bash
python scripts/sync_skills.py
```

This reads both registries and prints the merged snapshot. Run after installing new Hermes skills or deploying a custom skill so Paperclip's UI reflects the current state.

### Deploying a custom skill to an agent

1. Write your skill file: `my-skill.md` (Hermes skill format)
2. Drop it in `~/.hermes/skills/`
3. Run `sync_skills.py` — Paperclip UI will show it
4. Assign it to a specific agent from the UI, or load it globally for all agents

### Creating a new Hermes skill for an agent

Hermes agents can create skills autonomously after completing complex tasks. To trigger this manually:

```bash
python scripts/assign_task.py \
  --agent <session-id> \
  --task "You just completed a complex research workflow. Document it as a reusable skill and save it to your skills directory."
```

The agent will write the skill, test it, and save it. Run `sync_skills.py` after to surface it in Paperclip.

---

## 4. Agent-to-Agent Delegation

This is how agents in your AI company hand work to each other without human intervention.

### Method A: MCP server (recommended)

Start the MCP server so any MCP-compatible agent (Hermes, Claude, etc.) can call workforce operations as tools:

```bash
python scripts/mcp_server.py
```

The server exposes these tools over stdio/HTTP (port 8765 by default):

| Tool | Description |
|------|-------------|
| `list_agents` | Returns all active agents with roles and status |
| `assign_task` | Assigns a task to a named agent or role |
| `query_agent` | Asks an agent a direct question and returns its response |
| `get_agent_memory` | Retrieves an agent's recent memory/context |
| `spawn_agent` | Creates a new Hermes worker in a Paperclip role |
| `escalate_to_human` | Flags a task for human (board) review in Paperclip |
| `get_company_goals` | Returns current OKRs and goal cascade from Paperclip |

To connect any Hermes agent to this MCP server, add to that agent's config:

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

Once connected, the agent can call `assign_task`, `query_agent`, etc. as native tools — no extra code needed.

### Method B: Hermes-to-Hermes direct call

Any Hermes agent can invoke another agent in single-query mode via the adapter:

```python
# In a Hermes skill or agent script:
import subprocess, json

result = subprocess.run(
    ["hermes", "--resume", "target-agent-session-id", "-q", "Your query here"],
    capture_output=True, text=True
)
response = result.stdout
```

Use this for tight, low-latency agent calls. The target agent resumes its session, processes the query, and returns its response as stdout.

### Method C: Paperclip task routing

For structured, audited delegation (recommended for anything budget-sensitive or cross-department):

```bash
python scripts/assign_task.py \
  --role "Head of Marketing" \          # route to role, not specific agent
  --task "Write a launch email for the new product" \
  --from-agent "ceo-001" \              # track who delegated
  --budget 5.00                         # USD cap; Paperclip enforces it
```

Paperclip routes to the correct agent for that role and logs the delegation chain. The board (you) can audit all inter-agent task assignments in the Paperclip UI.

---

## 5. Escalation and Human Control

Agents should escalate to humans when:
- A task exceeds its budget allocation
- A decision requires board approval (e.g. hiring a new agent)
- Confidence is low after multiple retry attempts
- The task touches data flagged as requiring human review

To escalate from within a task:

```bash
python scripts/assign_task.py \
  --agent <id> \
  --task "Escalate to board: [reason]. Context: [summary]" \
  --escalate
```

This creates a Paperclip board item that appears in the human control plane. The agent pauses and waits for human resolution before continuing.

---

## 6. Debugging

### Read an agent's recent memory

```bash
python scripts/get_agent_context.py --agent <session-id> --last 20
```

### Watch live task execution

```bash
hermes --resume <session-id> --verbose
```

### Check adapter heartbeat logs

Paperclip logs adapter heartbeats at:
`~/.paperclip/logs/adapter-<session-id>.log`

### Common issues

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Agent not resuming session | Wrong `HERMES_SESSIONS_DIR` | Check `.env`, verify path exists |
| Skills not appearing in Paperclip | Sync not run | `python scripts/sync_skills.py` |
| Agent exceeding budget | Budget too low for task complexity | Increase in Paperclip UI or split the task |
| MCP server tools not visible | Agent config not updated | Add MCP server to agent's `mcp_servers` config |

---

## Reference files

Read these when you need deeper detail on a specific area:

- `references/adapter_config.md` — Full adapter configuration reference and session lifecycle
- `references/agent_operations.md` — Complete API for all agent operations and their parameters
- `references/mcp_tools.md` — MCP server tool schemas, request/response formats, and examples

---

## Notes for agents using this skill

If you are an AI agent (not a human) reading this skill:

- You are part of the Hermes + Paperclip AI workforce
- Use the MCP tools (`assign_task`, `query_agent`, `list_agents`) to delegate work — do not attempt to spawn subprocesses directly unless you have shell access
- Always include your own session ID as `--from-agent` when assigning tasks so the delegation chain is tracked
- Escalate to humans for any action that: exceeds your budget, modifies the org chart, or falls outside your role's defined scope
- Your memory persists across tasks — use `get_agent_memory` to recall prior context before starting work
