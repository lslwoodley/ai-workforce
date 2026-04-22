# AI Workforce

Private infrastructure for a self-improving AI company built on **[Hermes Agent](https://github.com/nousresearch/hermes-agent)** + **[Paperclip](https://github.com/paperclipai/paperclip)**, running as Docker containers on Windows or Ubuntu hosts.

## What this is

- **Paperclip** acts as the company OS — org chart, goals, budgets, task queue, governance
- **Hermes Agent** powers each employee — persistent memory, self-improving skills, multi-model
- **hermes-paperclip-adapter** connects them — agents pick up Paperclip tasks and persist session state between runs
- **MCP server** exposes the workforce as tools — agents delegate work to each other via HTTP

You operate as the board of directors. Agents run autonomously within the limits you set.

## Repository structure

```
.
├── .github/
│   └── workflows/
│       ├── build-images.yml      # Build & push Docker images to ghcr.io on push to main
│       └── agent-workspace.yml   # PR review workflow for agent-committed work
├── docs/
│   └── ADR-001-hermes-paperclip-ai-company.md  # Architecture decision record
├── skills/
│   ├── hermes-paperclip/         # Skill: manage the Hermes-Paperclip integration
│   └── hermes-paperclip-setup/   # Skill: install & configure the stack (Windows + Ubuntu)
├── workspace/
│   └── agents/                   # Agent work committed here (one dir per agent session)
├── scripts/
│   └── init_github.sh            # One-time repo initialisation script
└── docker-compose.prod.yml       # Production override: uses ghcr.io images instead of local builds
```

## Quick start

### 1. Clone and configure

```bash
git clone https://github.com/<your-username>/ai-workforce.git
cd ai-workforce
cp skills/hermes-paperclip-setup/docker/.env.example skills/hermes-paperclip-setup/docker/.env
# Edit .env — add OPENROUTER_API_KEY or ANTHROPIC_API_KEY
```

### 2. Start the stack

**Windows:**
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\skills\hermes-paperclip-setup\scripts\setup_windows.ps1
```

**Ubuntu:**
```bash
chmod +x skills/hermes-paperclip-setup/scripts/setup_ubuntu.sh
./skills/hermes-paperclip-setup/scripts/setup_ubuntu.sh
```

Both scripts are idempotent — safe to re-run.

### 3. Open the interfaces

| Interface | URL |
|-----------|-----|
| Paperclip UI | http://localhost:3100 |
| MCP server (agent-to-agent) | http://localhost:8765 |

## CI/CD

GitHub Actions builds Docker images on every push to `main` and publishes them to the GitHub Container Registry (`ghcr.io`).

To use pre-built images instead of building locally:

```bash
docker compose -f skills/hermes-paperclip-setup/docker/docker-compose.yml \
               -f docker-compose.prod.yml up -d
```

Required repository secrets (Settings → Secrets → Actions):

| Secret | Description |
|--------|-------------|
| `GHCR_TOKEN` | GitHub PAT with `write:packages` scope |

## Agent workspace

Hermes agents commit their work (research, code, reports, analysis) to `workspace/agents/<session-id>/` on dedicated branches. Each commit is attributed to the agent. The `agent-workspace.yml` workflow auto-creates a pull request for human review when an agent pushes a branch.

To grant an agent commit access, add its session ID and a fine-grained GitHub PAT to `.env`:

```dotenv
AGENT_GIT_TOKEN=github_pat_...
AGENT_GIT_USER=ai-workforce-bot
AGENT_GIT_EMAIL=agents@yourorg.com
```

## Architecture

See [`docs/ADR-001-hermes-paperclip-ai-company.md`](docs/ADR-001-hermes-paperclip-ai-company.md) for the full architecture decision record.

## License

Private — all rights reserved.
