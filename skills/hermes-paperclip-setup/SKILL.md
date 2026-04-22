---
name: hermes-paperclip-setup
description: Step-by-step installation and setup of the Hermes Agent + Paperclip AI workforce stack running as Docker containers. Use this skill whenever the user wants to install, configure, or troubleshoot the stack on Windows (via Docker Desktop) or Ubuntu. Covers Docker prerequisites, environment configuration, first-run verification, and platform-specific gotchas. Also invoke when a user asks how to get the stack running, why containers won't start, or how to reset/rebuild the environment.
---

# Hermes + Paperclip — Docker Setup Skill

This skill installs and verifies the full AI workforce stack as Docker containers, on either a **Windows host** (Docker Desktop + WSL2) or an **Ubuntu host** (Docker Engine). The containers are Linux in both cases — the host OS only affects the Docker installation method.

## Stack overview

| Container | Image | Port | Purpose |
|-----------|-------|------|---------|
| `paperclip` | built from source | 3100 | Company OS — UI, API, embedded Postgres, task queue |
| `hermes-worker` | custom (Python 3.11 + Node 20) | — | Hermes Agent runtime + hermes-paperclip-adapter |
| `mcp-server` | custom (Python 3.11) | 8765 | MCP server for agent-to-agent tool calls |

Paperclip includes **embedded PostgreSQL** — no separate database container needed.

> **Windows note:** Hermes does not run natively on Windows. It runs inside a Linux container via Docker Desktop's WSL2 backend. This is fully transparent — you manage everything from PowerShell or Windows Terminal.

---

## Step 0: Detect your platform and start

Ask yourself:
- Am I on **Windows 10/11**? → follow the Windows path (read `references/windows.md`)
- Am I on **Ubuntu 20.04+**? → follow the Ubuntu path (read `references/ubuntu.md`)

Read the relevant reference file now for platform-specific details, then return here for the shared steps.

---

## Step 1: Clone and configure

```bash
# From your chosen working directory:
git clone https://github.com/paperclipai/paperclip.git
git clone https://github.com/nousresearch/hermes-agent.git
git clone https://github.com/nousresearch/hermes-paperclip-adapter.git
```

Copy our unified compose file and Dockerfiles into place:

```bash
# Copy the contents of this skill's docker/ folder into the paperclip repo
cp -r <skill-path>/docker/* paperclip/docker/workforce/
```

Then copy `.env.example` from this skill to `paperclip/docker/workforce/.env` and fill it in:

```bash
cp <skill-path>/.env.example paperclip/docker/workforce/.env
```

**Required values in `.env`:**

```dotenv
# At least one model provider key — OpenRouter gives access to 200+ models
OPENROUTER_API_KEY=sk-or-...

# Or Anthropic directly:
ANTHROPIC_API_KEY=sk-ant-...

# Paperclip admin password (you choose this)
PAPERCLIP_ADMIN_PASSWORD=changeme
```

Everything else has working defaults.

---

## Step 2: Build and start the stack

```bash
cd paperclip/docker/workforce
docker compose up --build -d
```

First build takes 3–8 minutes (downloading base images, installing dependencies). Subsequent starts take ~15 seconds.

Watch logs as it comes up:

```bash
docker compose logs -f
```

You should see:
```
paperclip     | Paperclip ready on http://0.0.0.0:3100
hermes-worker | Hermes v0.10.x initialised — session: default-worker
hermes-worker | Adapter polling Paperclip at http://paperclip:3100 every 30s
mcp-server    | MCP server listening on 0.0.0.0:8765
```

---

## Step 3: Open the interfaces

| Interface | URL | What it is |
|-----------|-----|------------|
| Paperclip UI | http://localhost:3100 | Company dashboard — org chart, tasks, budgets |
| MCP server | http://localhost:8765 | Agent-to-agent API (no browser UI) |
| Hermes logs | `docker compose logs hermes-worker -f` | Live agent output |

Log in to Paperclip with `admin` and the password you set in `.env`.

---

## Step 4: Run verification

```bash
docker compose exec mcp-server python /app/scripts/health_check.py
```

All checks should pass. If any fail, see the **Troubleshooting** section below or read `references/windows.md` / `references/ubuntu.md` for platform-specific fixes.

---

## Step 5: Initialise your first company

In the Paperclip UI:
1. Click **New Company**
2. Choose a template (Dev Shop, Research Lab, Content Studio, or blank)
3. Set your company name and board goals
4. The CEO agent will be auto-spawned — it maps to the `hermes-worker` container

The adapter polls Paperclip every 30 seconds. When you assign the CEO their first task, you'll see Hermes pick it up in `docker compose logs hermes-worker -f`.

---

## Useful commands

```bash
# Start / stop the stack
docker compose up -d
docker compose down

# Restart a single service
docker compose restart hermes-worker

# View live logs
docker compose logs -f
docker compose logs paperclip -f --tail 50

# Open a shell inside a container
docker compose exec hermes-worker bash
docker compose exec paperclip sh

# Run hermes commands directly inside the container
docker compose exec hermes-worker hermes --version
docker compose exec hermes-worker hermes model

# Rebuild after a code change
docker compose build hermes-worker
docker compose up -d hermes-worker

# Full reset (keeps volumes — data is preserved)
docker compose down && docker compose up -d

# Nuclear reset (destroys all data — start fresh)
docker compose down -v
```

---

## Persistent data

All data is stored in named Docker volumes:

| Volume | Contents |
|--------|----------|
| `paperclip-data` | Paperclip DB, org chart, tasks, goals, agent configs |
| `hermes-sessions` | Hermes session state, agent memory, auto-created skills |
| `hermes-skills` | Shared skills directory visible to all workers |

Volumes survive `docker compose down`. Only `docker compose down -v` removes them.

**Backup:**
```bash
docker run --rm -v paperclip-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/paperclip-data-backup.tar.gz /data

docker run --rm -v hermes-sessions:/data -v $(pwd):/backup alpine \
  tar czf /backup/hermes-sessions-backup.tar.gz /data
```

---

## Scaling workers

To run multiple Hermes workers (one per agent role), scale the service:

```bash
docker compose up -d --scale hermes-worker=3
```

Or define named workers in `docker-compose.yml` (see `references/scaling.md` — create this when you're ready to build out a full org chart with dedicated containers per role).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `paperclip` exits immediately | Port 3100 in use | Change `PAPERCLIP_PORT` in `.env` |
| `hermes-worker` can't reach Paperclip | Wrong internal URL | Internal URL is `http://paperclip:3100` — check `PAPERCLIP_API_URL` in `.env` |
| Hermes fails with "model not configured" | No API key set | Add `OPENROUTER_API_KEY` or `ANTHROPIC_API_KEY` to `.env`, then `docker compose up -d` |
| MCP server tools not reachable | Container not started or port blocked | Check `docker compose ps` and firewall rules for port 8765 |
| Windows: volume mount errors | Docker Desktop not sharing drive | Settings → Resources → File Sharing → add the drive |
| Ubuntu: permission denied on Docker socket | User not in docker group | `sudo usermod -aG docker $USER` then log out/in |
| Adapter not picking up tasks | Heartbeat interval too long | Lower `ADAPTER_HEARTBEAT_INTERVAL` in `.env` (default 30s) |

For platform-specific issues, read `references/windows.md` or `references/ubuntu.md`.

---

## Reference files

- `references/windows.md` — Docker Desktop install, WSL2 setup, path handling, volume tips
- `references/ubuntu.md` — Docker Engine install, group permissions, systemd service, firewall
- `docker/docker-compose.yml` — Full annotated compose file
- `docker/hermes/Dockerfile` — Hermes worker image (Python 3.11 + Node 20 + adapter)
- `docker/mcp/Dockerfile` — MCP server image
