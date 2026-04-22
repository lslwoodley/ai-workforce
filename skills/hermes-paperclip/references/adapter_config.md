# Adapter Configuration Reference

The `hermes-paperclip-adapter` bridges Paperclip's task queue with Hermes Agent's execution engine.

## adapter.json (per-agent config)

Written to `HERMES_SESSIONS_DIR/<session-id>/adapter.json` by `spawn_agent.py`.

```json
{
  "sessionId":            "eng-head-001",
  "model":                "openrouter/anthropic/claude-3.5-sonnet",
  "paperclipApiUrl":      "http://localhost:3000",
  "paperclipApiKey":      "your_key",
  "heartbeatInterval":    30,
  "maxWorkers":           4,
  "systemPrompt":         "Optional: role-specific instructions prepended to every task"
}
```

| Field | Default | Description |
|-------|---------|-------------|
| sessionId | required | Stable ID — must match the Hermes session directory name |
| model | `openrouter/anthropic/claude-3.5-sonnet` | Model for this agent's tasks |
| heartbeatInterval | 30 | Seconds between Paperclip polls for new tasks |
| maxWorkers | 4 | Parallel Hermes threads (up to 8; Hermes's ThreadPoolExecutor cap) |
| systemPrompt | null | Prepended to every task prompt — good for role framing |

## Session lifecycle

```
Paperclip assigns task
        ↓
Adapter receives on heartbeat
        ↓
hermes --resume <sessionId> -q "<task>"
        ↓
Hermes loads session memory, skills, MCP tools
        ↓
Agent executes task (tool calls, memory nudges, skill creation)
        ↓
Response written to stdout
        ↓
Adapter posts result back to Paperclip /api/tasks/<id>/complete
        ↓
Session state persisted to HERMES_SESSIONS_DIR/<sessionId>/
```

## Session state files

| File | Contents |
|------|----------|
| `session.json` | Conversation history, compressed context |
| `memory.json` | Agent-curated memories (role, relationships, learnings) |
| `skills/` | Auto-created skills from this agent's tasks |
| `adapter.json` | Adapter config (written by spawn_agent.py) |

The `sessionCodec` in the adapter validates and migrates session state between adapter versions. You don't need to manage this manually.

## Upgrading

When upgrading `hermes-paperclip-adapter`:
1. Stop all running adapters
2. `npm install -g hermes-paperclip-adapter@latest`
3. The sessionCodec will migrate session state on the next heartbeat
4. Restart adapters

Sessions are not lost during upgrades.
