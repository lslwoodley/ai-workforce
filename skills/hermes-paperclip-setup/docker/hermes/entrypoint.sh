#!/bin/bash
# Hermes Worker entrypoint — utility/git-workspace sidecar
#
# Architecture note:
#   The hermes-paperclip-adapter is a TypeScript LIBRARY that runs INSIDE
#   Paperclip (via the hermes_local adapter registry). There is no adapter CLI.
#   Hermes CLI is installed directly in the Paperclip container so Paperclip
#   can call `hermes chat -q <task>` as a subprocess.
#
#   This container's roles:
#     1. Git workspace manager — clones repo, lets agents push branches/PRs
#     2. Direct task runner — `docker compose exec hermes-worker hermes chat -q "..."`
#     3. Dev utility — shell into container for hermes debugging
#
# On error: prints diagnostics, exits non-zero so Docker can restart.

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $*" >&2; }

handle_error() {
    local exit_code=$?
    local line_no=$1
    local cmd=$2
    err "════════════════════════════════"
    err "  STARTUP FAILED  line $line_no"
    err "  Command: $cmd"
    err "  Exit   : $exit_code"
    err "════════════════════════════════"
    exit $exit_code
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

# ── Environment ────────────────────────────────────────────────────────────────

PAPERCLIP_API_URL="${PAPERCLIP_API_URL:-http://paperclip:3100}"
HERMES_MODEL="${HERMES_MODEL:-openrouter/anthropic/claude-3.5-sonnet}"
HERMES_SESSIONS_DIR="${HERMES_SESSIONS_DIR:-/hermes/sessions}"
HERMES_SKILLS_DIR="${HERMES_SKILLS_DIR:-/hermes/skills}"

echo ""
echo "═══════════════════════════════════════════════"
echo "  Hermes Worker (git-workspace / utility)"
echo "  Paperclip : $PAPERCLIP_API_URL"
echo "  Model     : $HERMES_MODEL"
echo "  Sessions  : $HERMES_SESSIONS_DIR"
echo "  Skills    : $HERMES_SKILLS_DIR"
echo "═══════════════════════════════════════════════"
echo ""

# ── Step 1: Validate at least one API key ─────────────────────────────────────

API_KEY_SET=false
for key_var in OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY; do
    val="${!key_var:-}"
    if [[ -n "$val" && "$val" != "sk-or-" && "$val" != "sk-ant-" && "$val" != "sk-" ]]; then
        API_KEY_SET=true
        break
    fi
done

if [[ "$API_KEY_SET" != "true" ]]; then
    warn "No model API key set — hermes will not be able to run tasks."
    warn "Set OPENROUTER_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY in .env"
fi

# ── Step 2: Ensure data directories exist ─────────────────────────────────────

for dir in "$HERMES_SESSIONS_DIR" "$HERMES_SKILLS_DIR"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || { err "Cannot create $dir — check volume mount"; exit 1; }
    fi
done
ok "Data directories ready"

# ── Step 3: Verify Hermes CLI ──────────────────────────────────────────────────

log "Checking Hermes CLI..."
if ! command -v hermes &>/dev/null; then
    err "hermes CLI not found — image build may have failed"
    err "Rebuild: docker compose build --no-cache hermes-worker"
    exit 1
fi
HERMES_VERSION=$(hermes --version 2>&1 || echo "unknown")
ok "Hermes CLI: $HERMES_VERSION"

# ── Step 4: Configure Hermes model (idempotent) ───────────────────────────────

log "Configuring Hermes model..."
CURRENT_MODEL=$(hermes config get model 2>/dev/null || echo "")
if [[ "$CURRENT_MODEL" == "$HERMES_MODEL" ]]; then
    ok "Hermes model already set to $HERMES_MODEL"
else
    if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
        hermes config set provider openrouter 2>/dev/null || warn "Could not set provider"
        hermes config set model "$HERMES_MODEL" 2>/dev/null || warn "Could not set model"
        ok "Model: $HERMES_MODEL via OpenRouter"
    elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
        hermes config set provider openai 2>/dev/null || warn "Could not set provider"
        hermes config set model "${HERMES_MODEL:-gpt-4o-mini}" 2>/dev/null || warn "Could not set model"
        ok "Model: ${HERMES_MODEL:-gpt-4o-mini} via OpenAI"
    elif [[ -n "${GOOGLE_API_KEY:-}" ]]; then
        hermes config set provider openai 2>/dev/null || warn "Could not set provider"
        hermes config set model "${HERMES_MODEL:-gemini-2.0-flash-lite}" 2>/dev/null || warn "Could not set model"
        ok "Model: ${HERMES_MODEL:-gemini-2.0-flash-lite} via Gemini"
    fi
fi

# ── Step 5: Git workspace setup (only if tokens are provided) ─────────────────

if [[ -n "${AGENT_GIT_TOKEN:-}" && -n "${AGENT_REPO_URL:-}" ]]; then
    log "Configuring git workspace..."

    GIT_USER="${AGENT_GIT_USER:-ai-workforce-bot}"
    GIT_EMAIL="${AGENT_GIT_EMAIL:-agents@localhost}"

    git config --global user.name  "$GIT_USER"
    git config --global user.email "$GIT_EMAIL"
    git config --global credential.helper store

    REPO_HOST=$(echo "$AGENT_REPO_URL" | sed 's|https://||' | cut -d/ -f1)
    echo "https://${GIT_USER}:${AGENT_GIT_TOKEN}@${REPO_HOST}" > /root/.git-credentials
    chmod 600 /root/.git-credentials

    WORKSPACE_DIR="${AGENT_WORKSPACE_MOUNT:-/workspace}"
    if [[ -d "$WORKSPACE_DIR/.git" ]]; then
        log "Workspace already cloned — pulling latest..."
        git -C "$WORKSPACE_DIR" pull --ff-only origin main 2>&1 || \
            warn "Could not pull — proceeding with existing state"
    elif [[ -d "$WORKSPACE_DIR" && -n "$(ls -A $WORKSPACE_DIR 2>/dev/null)" ]]; then
        warn "$WORKSPACE_DIR exists but is not a git repo — agents can write files but cannot push"
    else
        log "Cloning $AGENT_REPO_URL into $WORKSPACE_DIR..."
        mkdir -p "$WORKSPACE_DIR"
        git clone "$AGENT_REPO_URL" "$WORKSPACE_DIR" 2>&1 || \
            warn "Clone failed — check AGENT_REPO_URL and AGENT_GIT_TOKEN"
    fi

    ok "Git: $GIT_USER <$GIT_EMAIL>"
    ok "Repo: $AGENT_REPO_URL"
else
    log "Git workspace skipped (AGENT_GIT_TOKEN / AGENT_REPO_URL not set)"
    log "  Add these to .env to enable agent commits & PRs"
fi

# ── Step 6: Keepalive ─────────────────────────────────────────────────────────
# This container stays running so you can:
#   docker compose exec hermes-worker hermes chat -q "..."
#   docker compose exec hermes-worker bash

ok "Hermes worker ready."
echo ""
echo "  Usage:"
echo "    docker compose exec hermes-worker hermes chat -q \"your task here\""
echo "    docker compose exec hermes-worker bash"
echo ""

# Heartbeat loop — keeps the container alive and logs that it's healthy
while true; do
    sleep 60
    log "heartbeat — container alive, hermes ready"
done
