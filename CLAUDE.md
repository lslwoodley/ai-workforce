# AI Workforce — Project Context for Claude Code

## What this is
A self-hosted AI company stack. Paperclip is the company OS (org chart, goals, governance, budget controls). Hermes Agent is the worker runtime (persistent memory, self-improving skills). The hermes-paperclip-adapter is the official NousResearch bridge between them.

Owner (Lao) acts as board of directors — approves strategy, reviews agent PRs, never does day-to-day work.

## Repo
`github.com/lslwoodley/aiworkforce` — private, already pushed.

## Stack
- **Paperclip** — Node.js, port 3100, embedded Postgres, no separate DB needed
- **Hermes Agent** — Python 3.11, does NOT run natively on Windows, Linux container only
- **hermes-paperclip-adapter** — polls Paperclip, spawns `hermes --resume <id> -q <task>` per heartbeat
- **MCP server** — Python FastMCP, port 8765, exposes 7 agent-to-agent tools

## Docker layout
```
skills/hermes-paperclip-setup/docker/
├── docker-compose.yml       # 3 services: paperclip, hermes-worker, mcp-server
├── .env.example             # copy to .env, fill in API keys
├── paperclip/Dockerfile     # clones from GitHub, pnpm install, pnpm start
├── hermes/
│   ├── Dockerfile           # installs hermes-agent + adapter from GitHub source
│   ├── entrypoint.sh        # wait for paperclip → configure model → start adapter
│   └── hermes-config.json   # non-interactive config for container use
└── mcp/
    ├── Dockerfile
    ├── requirements.txt
    └── scripts/mcp_server.py
```

## CRITICAL: Line endings
`.gitattributes` enforces LF on all `.sh`, `Dockerfile*`, `.yml` files.
**Never let Windows convert entrypoint.sh to CRLF** — it causes "exec format error" in Docker and the container will not start.

## To bring up the stack
```powershell
cd "skills\hermes-paperclip-setup\docker"
copy .env.example .env
# Edit .env — add OPENROUTER_API_KEY or ANTHROPIC_API_KEY (at least one required)
docker compose up --build -d
# Paperclip UI: http://localhost:3100
# MCP tools: http://localhost:8765
```

## GitHub secrets still needed
Go to: `github.com/lslwoodley/aiworkforce/settings/secrets/actions`
- `GHCR_TOKEN` — GitHub PAT with `write:packages` scope (CI builds images to ghcr.io)
- `AGENT_GIT_TOKEN` — Fine-grained PAT, repo contents write (agents commit their work)

## Agent workspace
Agents write output to `workspace/agents/<session-id>/` on a branch named `agent/<session-id>/<topic>`.
GitHub Actions auto-opens a PR with label `agent-work`. **Agents cannot merge their own PRs.**

## Known install approach
Both `hermes-agent` and `hermes-paperclip-adapter` are installed from GitHub source (not PyPI/npm) because their published package names are unconfirmed. See `hermes/Dockerfile`.

## Next step
`docker compose up --build -d` and watch the logs. Most likely first failure point is the Paperclip build — if `pnpm start` fails, check the actual Paperclip repo's README for the correct start command and update `paperclip/Dockerfile` CMD accordingly.

## References
- Hermes Agent: https://github.com/NousResearch/hermes-agent
- Paperclip: https://github.com/paperclipai/paperclip
- Adapter: https://github.com/NousResearch/hermes-paperclip-adapter
- ADR: docs/ADR-001-hermes-paperclip-ai-company.md
