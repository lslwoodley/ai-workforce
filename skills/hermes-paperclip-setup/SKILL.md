---
name: hermes-paperclip-setup
description: Step-by-step installation and setup of the Hermes Agent + Paperclip AI workforce stack running as Docker containers. Use this skill whenever the user wants to install, configure, or troubleshoot the stack on Windows (via Docker Desktop) or Ubuntu. Covers Docker prerequisites, environment configuration, first-run verification, credential pools, and all known gotchas discovered in production. Also invoke when a user asks how to get the stack running, why containers won't start, or how to reset/rebuild the environment.
---

# Hermes + Paperclip — Docker Setup Skill

This skill installs and verifies the full AI workforce stack as Docker containers on either a **Windows host** (Docker Desktop + WSL2) or an **Ubuntu host** (Docker Engine).

---

## Architecture

### How the pieces fit together

```
┌─────────────────────────────────────────────────────────┐
│  Paperclip  (port 3100)                                 │
│  ─ Company OS: UI, org chart, task queue, Postgres      │
│  ─ hermes_local adapter → calls `hermes` CLI subprocess │
│  ─ hermes-agent installed INSIDE this container         │
└──────────────────────┬──────────────────────────────────┘
                       │ agent task dispatch
┌──────────────────────▼──────────────────────────────────┐
│  hermes-gateway  (port 8642)                            │
│  ─ Standalone Hermes API server (OpenAI-compatible)     │
│  ─ POST /v1/chat/completions                            │
│  ─ GET  /v1/models                                      │
│  ─ GET  /health                                         │
│  ─ Credential pools: OpenRouter → Anthropic → OpenAI    │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  mcp-server  (port 8765)                                │
│  ─ Agent-to-agent tool API (FastMCP)                   │
│  ─ list_agents, assign_task, query_agent, etc.          │
└─────────────────────────────────────────────────────────┘
```

**Critical architectural facts:**
- `hermes-agent` is pip-installed **inside the Paperclip container** so the `hermes_local` adapter can call it as a subprocess. It is NOT on PyPI — install from GitHub source.
- The `hermes-gateway` container is a **separate** standalone Hermes instance with the OpenAI-compatible API server. Paperclip does not use it directly; it's for external API access and direct integrations.
- There is **no separate hermes-paperclip-adapter CLI** to install or run. The adapter is a TypeScript library bundled inside Paperclip's pnpm install.

### Container summary

| Container | Image | Port | Purpose |
|-----------|-------|------|---------|
| `paperclip` | built from source (node:lts-trixie-slim) | 3100 | Company OS + embedded hermes-agent |
| `hermes-gateway` | custom (python:3.11-slim) | 8642 | Standalone Hermes API server + credential pools |
| `mcp-server` | custom (Python) | 8765 | MCP tool server for agent-to-agent calls |

---

## Step 0: Prerequisites

**Windows:**
- Docker Desktop 4.x+ with WSL2 backend enabled
- Windows Terminal or PowerShell 7+
- `&&` does not work as a command separator in Windows PowerShell — use `;` or two separate commands

**Ubuntu:**
- Docker Engine + Docker Compose plugin (`docker compose`, not `docker-compose`)
- User in the `docker` group: `sudo usermod -aG docker $USER`

---

## Step 1: Get the files

```powershell
# Navigate to the docker folder inside this skill
cd "skills\hermes-paperclip-setup\docker"

# Copy the example env and fill it in
cp .env.example .env
```

**Required values in `.env`:**

```dotenv
# At least one — OpenRouter gives 200+ models including free tiers
OPENROUTER_API_KEY=sk-or-...

# Paperclip admin password (you choose)
PAPERCLIP_ADMIN_PASSWORD=changeme

# Auth secret — must be 32+ characters
BETTER_AUTH_SECRET=some-random-string-at-least-32-chars-long

# For private repo workspace cloning (GitHub fine-grained PAT, repo contents write)
AGENT_GIT_TOKEN=github_pat_...
AGENT_REPO_URL=https://github.com/your-org/your-repo
```

Everything else has working defaults.

---

## Step 2: Build and start

```powershell
docker compose up --build -d
```

First build takes 5–10 minutes (clones Paperclip source, pnpm install, pip installs hermes-agent from GitHub). Subsequent starts take ~15 seconds.

Watch logs as it comes up:

```powershell
docker compose logs -f
```

Expected healthy state:

```
paperclip      | Server listening on 0.0.0.0:3100
hermes-gateway | ✓ Smoke test passed
hermes-gateway | ✓ Starting Hermes gateway (api_server on port 8642)...
mcp-server     | MCP server running on 0.0.0.0:8765
```

---

## Step 3: Verify all services

```powershell
# Check container status — all should show healthy
docker compose ps

# Verify Hermes API server
Invoke-RestMethod http://localhost:8642/health
# Expected: {"status": "ok", "platform": "hermes-agent"}

# Verify MCP server
Invoke-RestMethod http://localhost:8765/health

# Check Paperclip UI
# Open http://localhost:3100 in your browser
```

---

## Step 4: Open the interfaces

| Interface | URL | Notes |
|-----------|-----|-------|
| Paperclip UI | http://localhost:3100 | Login: admin + your PAPERCLIP_ADMIN_PASSWORD |
| Hermes API | http://localhost:8642/v1 | OpenAI-compatible JSON API — no browser UI |
| MCP server | http://localhost:8765 | Agent-to-agent tools — no browser UI |

> Hermes has **no web UI**. The Paperclip UI at port 3100 is the control plane for managing agents and tasks. The Hermes gateway at port 8642 is a JSON API only.

---

## Step 5: First company setup

In Paperclip:
1. Click **New Company**
2. Choose a template or start blank
3. Set company name and goals
4. Create your first agent and assign it a task

When you assign a task, Paperclip's `hermes_local` adapter spawns a Hermes subprocess inside the Paperclip container to handle it.

---

## Key environment variables

### Paperclip container

| Variable | Purpose | Default |
|----------|---------|---------|
| `HERMES_YOLO_MODE` | **Bypass all dangerous-command approval prompts** — required for non-interactive agent runs | `1` |
| `HERMES_ACCEPT_HOOKS` | Auto-approve shell tool hooks without TTY | `1` |
| `AGENT_GIT_TOKEN` | GitHub PAT for Paperclip to clone private repo workspaces | — |
| `HERMES_MODEL` | Override default model (e.g. `openrouter/anthropic/claude-3.5-sonnet`) | free Nemotron |

### Hermes Gateway container

| Variable | Purpose | Default |
|----------|---------|---------|
| `API_SERVER_ENABLED` | **Must be `true`** — env var enables the API server (gateway.yaml is ignored) | `true` |
| `GATEWAY_ALLOW_ALL_USERS` | Needed only if not writing to `~/.hermes/.env` at startup | set by entrypoint |
| `OPENROUTER_API_KEY` | Primary credential pool key | — |
| `ANTHROPIC_API_KEY` | Secondary pool key | — |

---

## Credential pools

The hermes-gateway supports same-provider key rotation. Add `_2`, `_3` variants in `.env`:

```dotenv
OPENROUTER_API_KEY=sk-or-abc...    # primary
OPENROUTER_API_KEY_2=sk-or-def...  # rotated on 429/402
OPENROUTER_API_KEY_3=sk-or-ghi...  # tertiary

ANTHROPIC_API_KEY=sk-ant-abc...
ANTHROPIC_API_KEY_2=sk-ant-def...
```

Pool rotation strategies (configured in `hermes/hermes-pool-config.yaml`):

| Provider | Strategy | Reason |
|----------|---------|--------|
| OpenRouter | `round_robin` | Spread load evenly |
| Anthropic | `least_used` | Protect quota |
| OpenAI | `fill_first` | Use primary until exhausted |
| Google | `round_robin` | Even rotation |

---

## Useful commands

```powershell
# Start / stop the full stack
docker compose up -d
docker compose down

# Restart a single service (no rebuild)
docker compose restart paperclip
docker compose restart hermes-gateway

# View live logs
docker compose logs -f
docker compose logs paperclip --tail 50
docker compose logs hermes-gateway --tail 50

# Open a shell inside a container
docker compose exec paperclip bash
docker compose exec hermes-gateway bash

# Check hermes inside Paperclip container
docker compose exec paperclip hermes --version
docker compose exec paperclip hermes auth list

# Check API server health
Invoke-RestMethod http://localhost:8642/health
Invoke-RestMethod http://localhost:8642/v1/models

# Rebuild after config changes
docker compose build paperclip
docker compose up -d paperclip

# Full reset (keeps volumes — data preserved)
docker compose down
docker compose up -d

# Nuclear reset (destroys all data)
docker compose down -v
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `hermes` not found in PATH after pip install | `uv` puts binaries in non-standard location on node:trixie-slim | Skip uv entirely — use `pip3 install "git+https://github.com/NousResearch/hermes-agent.git" --break-system-packages` |
| `hermes-agent` not on PyPI | Package not published to PyPI | Always install from GitHub: `git+https://github.com/NousResearch/hermes-agent.git` |
| `EACCES: permission denied /paperclip/instances/default/.env` | Paperclip creates files as root then gosu-drops to node; root-owned files persist across restarts | Fixed by `wrapper-entrypoint.sh` which `chown -R node:node /paperclip` before official entrypoint |
| `exec hermes gateway start` fails with "WSL detected but systemd not available" | `gateway start` tries systemd; use `gateway run` for foreground Docker use | Fix entrypoint to use `exec hermes gateway run` |
| Hermes API server port 8642 not listening | API server is controlled by `API_SERVER_ENABLED=true` env var — the `gateway.yaml` file is **ignored** | Add `API_SERVER_ENABLED: "true"` to hermes-gateway environment in docker-compose.yml |
| curl to port 8642 returns "connection closed" | Server is up but old container running without `API_SERVER_ENABLED` | Restart: `docker compose up -d hermes-gateway` |
| Agent runs show `⚠️ DANGEROUS COMMAND` and auto-deny | Hermes security scanner auto-denies in non-interactive mode | Set `HERMES_YOLO_MODE: "1"` in Paperclip environment |
| Git clone fails: "could not read Username" | Paperclip has no git credentials for private repo | Set `AGENT_GIT_TOKEN` in `.env` and `AGENT_REPO_URL`; wrapper-entrypoint.sh writes `/home/node/.git-credentials` |
| `BETTER_AUTH_SECRET must be set` | Paperclip auth requires 32+ char secret | Set `BETTER_AUTH_SECRET=<32+ random chars>` in `.env` |
| `GET /api/health 403` | Authenticated mode returns 403 on health endpoint | Healthcheck uses `wget -qO- ... >/dev/null 2>&1; exit 0` — always exits 0 |
| `hermes chat -q` returns help text (wrong smoke test) | Correct syntax is `hermes -q "<prompt>"` not `hermes chat -q` | Fix entrypoint smoke test command |
| `fallback_model should be a dict with 'provider' and 'model', got str` | Pool config format changed in newer Hermes | Use dict format: `fallback_model:\n  provider: openrouter\n  model: "nvidia/..."` |
| PowerShell `&&` not valid | PowerShell doesn't support `&&` as command separator | Use `;` or separate commands |

---

## Persistent data

| Volume | Contents |
|--------|----------|
| `paperclip-data` | Paperclip DB, org chart, tasks, goals, agent configs, Claude OAuth |
| `hermes-sessions` | Hermes session state, agent memory |
| `hermes-skills` | Shared skills visible to all workers |

Volumes survive `docker compose down`. Only `docker compose down -v` removes them.

The `paperclip-data` volume is mounted read-only into `hermes-gateway` so both containers can share Claude Code OAuth credentials if authenticated.

---

## File layout

```
skills/hermes-paperclip-setup/docker/
├── docker-compose.yml         # 3 services: paperclip, hermes-gateway, mcp-server
├── .env.example               # copy to .env, fill in API keys
├── paperclip/
│   ├── Dockerfile             # clones Paperclip from GitHub, pnpm build, pip installs hermes-agent
│   ├── wrapper-entrypoint.sh  # root PID 1: chowns /paperclip + configures git creds, then gosu
│   └── hermes-init.sh         # runs as node user: writes ~/.hermes/config.json from env vars
└── hermes/
    ├── Dockerfile             # python:3.11-slim + uv + hermes-agent[all] from GitHub source
    ├── entrypoint.sh          # seeds credential pools, writes GATEWAY_ALLOW_ALL_USERS, runs `hermes gateway run`
    ├── hermes-config.json     # non-interactive config, all tools enabled
    ├── hermes-gateway.yaml    # platform config (NOTE: ignored at runtime — use API_SERVER_ENABLED env var)
    └── hermes-pool-config.yaml # pool rotation strategies, merged into config.yaml at startup
└── mcp/
    ├── Dockerfile
    ├── requirements.txt
    └── scripts/mcp_server.py  # FastMCP server exposing 7 agent-to-agent tools
```
