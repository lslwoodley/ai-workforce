# Hermes Agent Worker + hermes-paperclip-adapter
#
# This image bundles:
#   - Python 3.11 + uv  (Hermes Agent runtime)
#   - Node.js 20        (hermes-paperclip-adapter)
#   - The adapter process that polls Paperclip and invokes hermes -q per task
#
# Hermes does not support native Windows — this Linux container is the solution
# for Windows hosts running Docker Desktop with WSL2 backend.

FROM python:3.11-slim-bookworm AS base

# ── System dependencies ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        git \
        ca-certificates \
        gnupg \
        build-essential \
        sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js 20 (for hermes-paperclip-adapter) ─────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── uv (fast Python package manager) ──────────────────────────────────────────
RUN pip install uv --no-cache-dir

# ── Hermes Agent ───────────────────────────────────────────────────────────────
# Install via uv in a virtual environment for clean isolation
ENV HERMES_VENV=/opt/hermes-venv
RUN uv venv $HERMES_VENV --python 3.11
ENV PATH="$HERMES_VENV/bin:$PATH"

# Install Hermes with all extras (tools, voice deps excluded for server use)
RUN uv pip install --python $HERMES_VENV "hermes-agent[tools,memory,mcp]" --no-cache

# Make hermes available system-wide
RUN ln -s $HERMES_VENV/bin/hermes /usr/local/bin/hermes

# ── hermes-paperclip-adapter ───────────────────────────────────────────────────
RUN npm install -g hermes-paperclip-adapter --no-fund --no-audit

# ── MCP Python SDK (for in-process MCP calls) ─────────────────────────────────
RUN uv pip install --python $HERMES_VENV "mcp>=1.6.0" "httpx>=0.27.0" "python-dotenv>=1.0.0"

# ── App setup ─────────────────────────────────────────────────────────────────
WORKDIR /app

# Copy the adapter entrypoint script
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Hermes data directories — these are mounted as named volumes at runtime
RUN mkdir -p /hermes/sessions /hermes/skills
ENV HERMES_SESSIONS_DIR=/hermes/sessions
ENV HERMES_SKILLS_DIR=/hermes/skills

# ── Hermes initial config ──────────────────────────────────────────────────────
# Create a minimal hermes config so it doesn't prompt interactively on first run
RUN mkdir -p /root/.hermes
COPY hermes-config.json /root/.hermes/config.json

ENTRYPOINT ["/app/entrypoint.sh"]
