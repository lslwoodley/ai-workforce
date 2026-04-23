#!/bin/bash
# Hermes Worker entrypoint — credential pools, git workspace, keepalive
#
# Architecture:
#   hermes-agent (Python) runs here. Paperclip uses Claude Code (its own container).
#   This container is a utility sidecar:
#     1. Seeds credential pools from all available env vars
#     2. Shares Claude Code OAuth from the Paperclip volume (if mounted)
#     3. Manages the git workspace for agent branch commits
#     4. Stays alive for: docker compose exec hermes-worker hermes chat -q "..."
#
# Pool rotation order (same-provider):
#   OpenRouter  → round_robin  (multiple OR keys spread evenly)
#   Anthropic   → least_used   (OAuth via Claude Code + API key)
#   OpenAI      → fill_first
#   Google      → round_robin
#
# Cross-provider fallback:
#   If ALL pool keys exhausted → fallback_model (free Nemotron on OpenRouter)

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $*" >&2; }

handle_error() {
    err "STARTUP FAILED at line $1: $2 (exit $?)"
    exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

# ── Environment ────────────────────────────────────────────────────────────────
HERMES_SESSIONS_DIR="${HERMES_SESSIONS_DIR:-/hermes/sessions}"
HERMES_SKILLS_DIR="${HERMES_SKILLS_DIR:-/hermes/skills}"
HERMES_HOME="/root/.hermes"
CLAUDE_CREDS_DIR="/root/.claude"

echo ""
echo "════════════════════════════════════════════════"
echo "  Hermes Worker — credential pool bootstrap"
echo "════════════════════════════════════════════════"
echo ""

# ── Step 1: Verify Hermes CLI ──────────────────────────────────────────────────
log "Checking Hermes CLI..."
if ! command -v hermes &>/dev/null; then
    err "hermes CLI not found — image build failed"
    err "Rebuild: docker compose build --no-cache hermes-worker"
    exit 1
fi
HERMES_VERSION=$(hermes --version 2>&1 || echo "unknown")
ok "Hermes: $HERMES_VERSION"

# ── Step 2: Ensure data directories ───────────────────────────────────────────
for dir in "$HERMES_SESSIONS_DIR" "$HERMES_SKILLS_DIR" "$HERMES_HOME"; do
    [[ -d "$dir" ]] || mkdir -p "$dir"
done
ok "Directories ready"

# ── Step 3: Merge pool rotation config into config.yaml ───────────────────────
log "Applying pool rotation strategies..."
POOL_CFG="$HERMES_HOME/pool-config.yaml"
MAIN_CFG="$HERMES_HOME/config.yaml"

if [[ -f "$POOL_CFG" ]]; then
    # Append if not already present (idempotent)
    if ! grep -q "credential_pool_strategies" "$MAIN_CFG" 2>/dev/null; then
        cat "$POOL_CFG" >> "$MAIN_CFG"
        ok "Pool strategies written to config.yaml"
    else
        ok "Pool strategies already in config.yaml — skipping"
    fi
fi

# ── Step 4: Claude Code OAuth sharing ─────────────────────────────────────────
# Paperclip stores Claude credentials at /paperclip/.claude/.credentials.json
# (HOME=/paperclip for the node user). Mount paperclip-data:ro in compose to
# share them with this container automatically.
log "Checking for Claude Code OAuth credentials..."
PAPERCLIP_CREDS="/paperclip/.claude/.credentials.json"

if [[ -f "$PAPERCLIP_CREDS" ]]; then
    mkdir -p "$CLAUDE_CREDS_DIR"
    cp "$PAPERCLIP_CREDS" "$CLAUDE_CREDS_DIR/.credentials.json"
    ok "Claude Code OAuth shared from Paperclip volume"
    ok "Hermes will auto-discover Anthropic OAuth from ~/.claude/.credentials.json"
else
    log "No Claude Code credentials at $PAPERCLIP_CREDS"
    log "  To enable: run 'docker compose exec paperclip claude auth login'"
    log "  Then restart this container to pick up the credentials"
fi

# ── Step 5: Seed credential pools from environment variables ──────────────────
log "Seeding credential pools..."

seed_api_key() {
    local provider="$1"; local key="$2"; local label="$3"
    if [[ -n "$key" && "$key" != "sk-or-" && "$key" != "sk-ant-" && "$key" != "sk-" ]]; then
        hermes auth add "$provider" --type api-key --api-key "$key" --label "$label" \
            --non-interactive 2>/dev/null \
            && ok "  Pool [$provider] ← $label" \
            || warn "  Pool [$provider] ← $label (already exists or error — skipping)"
    fi
}

# OpenRouter — primary pool (free + paid models)
seed_api_key "openrouter" "${OPENROUTER_API_KEY:-}"   "OPENROUTER_API_KEY"
seed_api_key "openrouter" "${OPENROUTER_API_KEY_2:-}" "OPENROUTER_API_KEY_2"
seed_api_key "openrouter" "${OPENROUTER_API_KEY_3:-}" "OPENROUTER_API_KEY_3"

# Anthropic — least_used, pairs with Claude Code OAuth (auto-discovered above)
seed_api_key "anthropic" "${ANTHROPIC_API_KEY:-}"   "ANTHROPIC_API_KEY"
seed_api_key "anthropic" "${ANTHROPIC_API_KEY_2:-}" "ANTHROPIC_API_KEY_2"

# OpenAI — fill_first fallback
seed_api_key "openai" "${OPENAI_API_KEY:-}"   "OPENAI_API_KEY"
seed_api_key "openai" "${OPENAI_API_KEY_2:-}" "OPENAI_API_KEY_2"

# Google Gemini — via OpenAI-compatible endpoint (round_robin)
# Configured as custom provider so hermes uses the right base URL
if [[ -n "${GOOGLE_API_KEY:-}" ]]; then
    hermes model --provider openai \
        --api-key   "$GOOGLE_API_KEY" \
        --base-url  "https://generativelanguage.googleapis.com/v1beta/openai/" \
        --model     "${GOOGLE_MODEL:-gemini-2.0-flash-lite}" \
        --label     "Google Gemini" \
        --non-interactive 2>/dev/null \
        && ok "  Custom provider: Google Gemini" \
        || warn "  Google Gemini config failed (may already exist)"
fi
if [[ -n "${GOOGLE_API_KEY_2:-}" ]]; then
    hermes auth add "Google Gemini" --type api-key \
        --api-key "$GOOGLE_API_KEY_2" --label "GOOGLE_API_KEY_2" \
        --non-interactive 2>/dev/null \
        && ok "  Pool [Google Gemini] ← GOOGLE_API_KEY_2" \
        || warn "  Pool [Google Gemini] ← GOOGLE_API_KEY_2 (skipping)"
fi

# Ollama — local, zero cost
if [[ -n "${OLLAMA_BASE_URL:-}" ]]; then
    hermes model --provider openai \
        --api-key   "ollama" \
        --base-url  "${OLLAMA_BASE_URL}/v1" \
        --model     "${OLLAMA_MODEL:-llama3.2}" \
        --label     "Ollama (local)" \
        --non-interactive 2>/dev/null \
        && ok "  Custom provider: Ollama at ${OLLAMA_BASE_URL}" \
        || warn "  Ollama config failed (may already exist)"
fi

# ── Step 6: Show pool status ───────────────────────────────────────────────────
echo ""
log "Credential pool status:"
hermes auth list 2>/dev/null || warn "Could not list pools (hermes auth list failed)"
echo ""

# ── Step 7: Smoke test ─────────────────────────────────────────────────────────
log "Running smoke test..."
SMOKE=$(hermes chat -q "Reply with exactly: READY" --non-interactive 2>&1 || true)
if echo "$SMOKE" | grep -qi "READY\|ready"; then
    ok "Smoke test passed — Hermes is operational"
else
    warn "Smoke test unexpected response: ${SMOKE:0:120}"
    warn "First task may fail — check provider keys"
fi

# ── Step 8: Git workspace ──────────────────────────────────────────────────────
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
        git -C "$WORKSPACE_DIR" pull --ff-only origin main 2>&1 || warn "Could not pull — proceeding"
    else
        mkdir -p "$WORKSPACE_DIR"
        git clone "$AGENT_REPO_URL" "$WORKSPACE_DIR" 2>&1 || warn "Clone failed — check tokens"
    fi
    ok "Git: $GIT_USER <$GIT_EMAIL> → $AGENT_REPO_URL"
else
    log "Git workspace skipped (AGENT_GIT_TOKEN / AGENT_REPO_URL not set)"
fi

# ── Keepalive ──────────────────────────────────────────────────────────────────
ok "Hermes worker ready."
echo ""
echo "  To run a task:"
echo "    docker compose exec hermes-worker hermes chat -q \"your task here\""
echo "  To open a shell:"
echo "    docker compose exec hermes-worker bash"
echo ""

while true; do
    sleep 60
    log "heartbeat — pools healthy, hermes ready"
done
