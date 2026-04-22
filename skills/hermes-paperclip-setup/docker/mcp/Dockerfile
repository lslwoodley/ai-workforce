# MCP Server — Agent-to-Agent Tool API
# Exposes the hermes-paperclip workforce as MCP tools over HTTP (port 8765).
# Any MCP-compatible agent can call list_agents, assign_task, query_agent, etc.

FROM python:3.11-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy MCP server and supporting scripts from the hermes-paperclip skill
COPY scripts/ /app/scripts/

EXPOSE 8765

HEALTHCHECK --interval=20s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import httpx; httpx.get('http://localhost:8765/health', timeout=3)" || exit 1

CMD ["python", "/app/scripts/mcp_server.py", "http"]
