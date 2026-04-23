# Hermes Agent — Full Gateway Container
#
# Installs hermes-agent from GitHub source with all extras so the full
# gateway stack is available: api_server, messaging platforms, credential
# pools, skills, memory, cron, MCP, etc.
#
# Services exposed:
#   port 8642 — Hermes API server (OpenAI-compatible: /v1/chat/completions)
#
# How Paperclip uses this:
#   hermes_local adapter: calls `hermes chat -q <task>` inside the Paperclip
#   container (hermes-agent also installed there via Paperclip Dockerfile).
#   The gateway container is a standalone service for direct API access,
#   credential pool management, and messaging platform bridges.

FROM python:3.11-slim-bookworm

# ── System dependencies ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl git ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

# ── uv (fast Python package manager) ──────────────────────────────────────────
RUN pip install uv --no-cache-dir

# ── Hermes Agent — full install from GitHub source (all extras) ───────────────
# Using [all] to include gateway, api_server, messaging platforms, cron, MCP
ENV HERMES_VENV=/opt/hermes-venv
RUN uv venv $HERMES_VENV --python 3.11

RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /opt/hermes-src \
 && uv pip install --python $HERMES_VENV -e "/opt/hermes-src[all]" --no-cache \
 || uv pip install --python $HERMES_VENV -e "/opt/hermes-src" --no-cache

ENV PATH="$HERMES_VENV/bin:$PATH"

# ── Directories ────────────────────────────────────────────────────────────────
RUN mkdir -p /hermes/sessions /hermes/skills /root/.hermes /root/.claude

ENV HERMES_SESSIONS_DIR=/hermes/sessions
ENV HERMES_SKILLS_DIR=/hermes/skills
ENV API_SERVER_PORT=8642

# ── Hermes base config ─────────────────────────────────────────────────────────
COPY hermes-config.json /root/.hermes/config.json

# ── Gateway platform config — enables api_server on port 8642 ─────────────────
COPY hermes-gateway.yaml /root/.hermes/gateway.yaml

# ── Credential pool rotation strategies ───────────────────────────────────────
COPY hermes-pool-config.yaml /root/.hermes/pool-config.yaml

# ── Entrypoint ─────────────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8642

HEALTHCHECK --interval=20s --timeout=5s --start-period=30s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8642/health', timeout=3)" \
    || exit 1

ENTRYPOINT ["/entrypoint.sh"]
