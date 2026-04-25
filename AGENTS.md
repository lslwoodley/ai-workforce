# AI Workforce Agent Instructions

## Project Summary
What you're building: A fully autonomous AI company where Paperclip acts as the company OS (org chart, goals, governance) and Hermes Agent powers each employee (persistent memory, self-improving skills). You sit at the board level — approving strategy, reviewing agent work, never doing day-to-day execution.

What's been built and pushed to github.com/lslwoodley/aiworkforce:
The repo is the complete infrastructure foundation. It has a Docker Compose stack with three services: Paperclip (the company control plane on port 3100), a Hermes worker (the AI agent runtime, container-only since it won't run natively on Windows), and an MCP server (agent-to-agent tool calls on port 8765). All scripts are idempotent — safe to re-run. Shell scripts are enforced to LF line endings via .gitattributes so they don't break inside Docker containers.
GitHub Actions handles two workflows: one that builds and pushes Docker images to ghcr.io on every push to main, and one that automatically opens a pull request whenever an agent commits work to an agent/* branch — so you review everything before it takes effect. The workspace/agents/ directory is where agents drop their output.
There are two Claude skills in the repo: hermes-paperclip (ongoing management — assign tasks, query agents, spawn new roles) and hermes-paperclip-setup (one-time installation for Windows with Docker Desktop and Ubuntu hosts).

What still needs doing to go live:
First, add two GitHub secrets at github.com/lslwoodley/aiworkforce/settings/secrets/actions — a GHCR_TOKEN PAT with write:packages scope (so CI can push images) and an AGENT_GIT_TOKEN fine-grained PAT with repo contents write (so agents can commit their work).
Then copy .env.example to .env in skills/hermes-paperclip-setup/docker/, add your model API key (OpenRouter is the most flexible — gives access to 200+ models including Claude), and run docker compose up -d. Paperclip will be at http://localhost:3100. Pick a company template, the adapter connects Hermes workers automatically, and you run your first task end-to-end.

## Key Technologies
- **Agent Runtime**: Hermes Agent (Python 3.11) with persistent memory and self-improving skills
- **Company OS**: Paperclip (Node.js 20 + embedded Postgres) for org chart, task queue, governance
- **Integration**: hermes-paperclip-adapter bridges systems via MCP (Model Context Protocol)
- **Deployment**: Docker Compose with 3 containers (paperclip, hermes-worker, mcp-server)

## Build & Run Commands
- **Setup**: Run OS-specific script (`setup_windows.ps1` or `setup_ubuntu.sh`) - idempotent and safe to re-run
- **Start**: `cd skills/hermes-paperclip-setup/docker && docker compose up --build -d`
- **Health Check**: `python skills/hermes-paperclip/scripts/health_check.py`
- **List Agents**: `python skills/hermes-paperclip/scripts/list_agents.py`
- **Spawn Agent**: `python skills/hermes-paperclip/scripts/spawn_agent.py --role "Role Name" --department dept --session-id unique-id`
- **Assign Task**: `python skills/hermes-paperclip/scripts/assign_task.py --agent session-id --task "Task description"`

## Key Conventions
- Agents commit work to `workspace/agents/<session-id>/` on feature branches; PRs auto-open for human approval
- Skills are VS Code agent customizations in `skills/` directory
- Environment variables in `.env` (API keys required: OPENROUTER_API_KEY, ANTHROPIC_API_KEY, or OPENAI_API_KEY)
- Session state persists in `~/.hermes/sessions/<session-id>/`

## Common Pitfalls
- Hermes requires Linux; use Docker Desktop + WSL2 on Windows
- Tasks poll every ~30s; expect delay after assignment
- Agents need AGENT_GIT_TOKEN for commits
- Clear `~/.hermes/sessions/` destroys agent memory

## Essential Documentation
- [Architecture Decision Record](docs/ADR-001-hermes-paperclip-ai-company.md) - Full system rationale
- [Quick Start Guide](README.md) - Setup and overview
- [Operational Skill](skills/hermes-paperclip/SKILL.md) - Management commands
- [Setup Troubleshooting](skills/hermes-paperclip-setup/references/) - OS-specific issues</content>
<parameter name="filePath">c:\Users\bruce\Documents\Claude\Projects\AI Management\AGENTS.md