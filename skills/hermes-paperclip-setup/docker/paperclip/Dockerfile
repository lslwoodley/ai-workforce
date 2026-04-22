# Paperclip — AI Company OS
#
# Builds from the official Paperclip source.
# Using a local Dockerfile (not a direct GitHub build URL) gives us:
#   - Build caching between runs
#   - Ability to pin a version via PAPERCLIP_VERSION arg
#   - Clearer error messages if the build fails

FROM node:20-alpine AS base

# Install git for cloning and wget for healthcheck
RUN apk add --no-cache git wget python3 make g++

# ── Clone Paperclip ───────────────────────────────────────────────────────────
ARG PAPERCLIP_VERSION=main
WORKDIR /build

# Clone only the specified ref (shallow clone for speed)
RUN git clone --depth 1 --branch ${PAPERCLIP_VERSION} \
    https://github.com/paperclipai/paperclip.git . \
    || git clone --depth 1 https://github.com/paperclipai/paperclip.git .

# ── Install dependencies and build ────────────────────────────────────────────
# Use npm ci for reproducible installs; fall back to npm install if no lockfile
RUN npm ci --prefer-offline 2>/dev/null || npm install

# Build the production bundle
RUN npm run build 2>&1 || { echo "Build failed — check node/npm versions"; exit 1; }

# ── Runtime stage (smaller final image) ───────────────────────────────────────
FROM node:20-alpine AS runtime

RUN apk add --no-cache wget

# Copy built app from build stage
WORKDIR /app
COPY --from=base /build/dist ./dist
COPY --from=base /build/node_modules ./node_modules
COPY --from=base /build/package.json ./package.json

# Pre-install Anthropic Claude CLI and OpenAI Codex CLI
# (Paperclip's Docker image includes these — we match that behaviour)
RUN npm install -g @anthropic-ai/claude-code@latest 2>/dev/null || true
RUN npm install -g @openai/codex@latest 2>/dev/null || true

# Data directory (backed by named volume at runtime)
RUN mkdir -p /paperclip
ENV PAPERCLIP_HOME=/paperclip
ENV HOST=0.0.0.0

EXPOSE 3100

HEALTHCHECK --interval=15s --timeout=10s --start-period=45s --retries=5 \
    CMD wget -qO- --tries=1 http://localhost:3100/api/health || exit 1

CMD ["node", "dist/server.js"]
