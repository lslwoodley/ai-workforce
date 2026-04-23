# Paperclip — AI Company OS + Hermes Agent runtime
#
# Mirrors the official Paperclip Dockerfile with Hermes Agent added.
# Hermes runs inside this container so Paperclip's adapter system can find it.
# Provider priority: OpenRouter → Ollama (local) → OpenAI → Gemini direct
# No Claude/Anthropic dependency — fully model-agnostic.

# ── Base ──────────────────────────────────────────────────────────────────────
FROM node:lts-trixie-slim AS base

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates gosu curl git wget ripgrep python3 python3-pip \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable

# ── Deps + Build ──────────────────────────────────────────────────────────────
FROM base AS build

ARG PAPERCLIP_VERSION=master
WORKDIR /app

RUN git clone --depth 1 --branch ${PAPERCLIP_VERSION} \
        https://github.com/paperclipai/paperclip.git . \
    || git clone --depth 1 https://github.com/paperclipai/paperclip.git .

RUN pnpm install --frozen-lockfile

RUN pnpm --filter @paperclipai/ui build \
 && pnpm --filter @paperclipai/plugin-sdk build \
 && pnpm --filter @paperclipai/server build \
 && test -f server/dist/index.js \
    || (echo "ERROR: server/dist/index.js not found — build failed" && exit 1)

# ── Production image ──────────────────────────────────────────────────────────
FROM base AS production

WORKDIR /app
COPY --from=build /app /app

# Hermes Agent — installed to system Python so Paperclip's adapter can find it
# Supports: OpenRouter, OpenAI/GPT, Gemini, NVIDIA NIM, local Ollama
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssh-client jq \
  && rm -rf /var/lib/apt/lists/* \
  && pip3 install hermes-agent --break-system-packages \
  && mkdir -p /paperclip \
  && chown node:node /paperclip

# Hermes config initialiser — detects provider from env vars at startup
COPY hermes-init.sh /usr/local/bin/hermes-init.sh
RUN chmod +x /usr/local/bin/hermes-init.sh

# Wrapper entrypoint — fixes volume ownership before official entrypoint runs
COPY wrapper-entrypoint.sh /wrapper-entrypoint.sh
RUN chmod +x /wrapper-entrypoint.sh \
 && chmod +x /app/scripts/docker-entrypoint.sh

ENV NODE_ENV=production \
    HOME=/paperclip \
    HOST=0.0.0.0 \
    PORT=3100 \
    SERVE_UI=true \
    PAPERCLIP_HOME=/paperclip \
    PAPERCLIP_INSTANCE_ID=default \
    PAPERCLIP_DEPLOYMENT_MODE=authenticated \
    PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
    OPENCODE_ALLOW_ALL_MODELS=true

VOLUME ["/paperclip"]
EXPOSE 3100

HEALTHCHECK --interval=15s --timeout=10s --start-period=90s --retries=6 \
    CMD wget -qO- --tries=1 --timeout=5 http://localhost:3100/ >/dev/null 2>&1; exit 0

ENTRYPOINT ["/wrapper-entrypoint.sh"]
# hermes-init runs first (as node user, after gosu), then the server starts
CMD ["sh", "-c", "/usr/local/bin/hermes-init.sh && node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js"]
