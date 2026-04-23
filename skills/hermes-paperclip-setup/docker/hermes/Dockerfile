# Hermes Agent Worker — utility / git-workspace sidecar
#
# Provides:
#   - hermes CLI for direct task execution
#   - Credential pool: OpenRouter (round_robin) → Anthropic (least_used) → Gemini / OpenAI fallbacks
#   - Claude Code OAuth credential sharing from the Paperclip container
#   - Git workspace for agent branch commits
#
# Usage after `docker compose up -d`:
#   docker compose exec hermes-worker hermes chat -q "your task"
#   docker compose exec hermes-worker bash

FROM python:3.11-slim-bookworm

# ── System dependencies ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Hermes Agent (PyPI) ────────────────────────────────────────────────────────
RUN pip install hermes-agent --no-cache-dir

# ── Directories ────────────────────────────────────────────────────────────────
RUN mkdir -p /hermes/sessions /hermes/skills /root/.hermes /root/.claude

ENV HERMES_SESSIONS_DIR=/hermes/sessions
ENV HERMES_SKILLS_DIR=/hermes/skills

# ── Hermes config (base settings + pool rotation strategies) ──────────────────
COPY hermes-config.json /root/.hermes/config.json
COPY hermes-pool-config.yaml /root/.hermes/pool-config.yaml

# ── Entrypoint ─────────────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
