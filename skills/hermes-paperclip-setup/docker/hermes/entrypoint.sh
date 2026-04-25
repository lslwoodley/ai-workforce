#!/bin/bash
# Hermes Gateway entrypoint
#
# 1. Verify hermes CLI is installed
# 2. Seed credential pools from all available env vars
# 3. Share Claude Code OAuth from Paperclip volume (if mounted)
# 4. Apply pool rotation strategies to config.yaml
# 5. Run smoke test
# 6. exec hermes gateway start  ← becomes PID 1, serves port 8642

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $*" >&2; }

handle_error() { err "FAILED at line $1: $2"; exit 1; }
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

HERMES_HOME="/root/.hermes"
CLAUDE_CREDS_DIR="/root/.claude"

echo ""
echo "════════════════════════════════════════════════"
echo "  Hermes Gateway"
echo "  API server : http://0.0.0.0:${API_SERVER_PORT:-8642}"
echo "  Sessions   : ${HERMES_SESSIONS_DIR:-/hermes/sessions}"
echo "  Skills     : ${HERMES_SKILLS_DIR:-/hermes/skills}"
echo "════════════════════════════════════════════════"
echo ""

# ── Step 1: Verify hermes ──────────────────────────────────────────────────────
log "Checking Hermes CLI..."
if ! command -v hermes &>/dev/null; then
    err "hermes not found — image build failed"
    err "Rebuild: docker compose build --no-cache hermes-gateway"
    exit 1
fi
ok "Hermes: $(hermes --version 2>&1 || echo unknown)"

# ── Step 2: Data directories ───────────────────────────────────────────────────
for dir in "${HERMES_SESSIONS_DIR:-/hermes/sessions}" "${HERMES_SKILLS_DIR:-/hermes/skills}" "$HERMES_HOME"; do
    [[ -d "$dir" ]] || mkdir -p "$dir"
done

# Write gateway .env — open access so API server accepts all requests
HERMES_ENV="$HERMES_HOME/.env"
grep -q "GATEWAY_ALLOW_ALL_USERS" "$HERMES_ENV" 2>/dev/null \
    || echo "GATEWAY_ALLOW_ALL_USERS=true" >> "$HERMES_ENV"
ok "Gateway access: open (GATEWAY_ALLOW_ALL_USERS=true)"

# ── Step 3: Merge pool rotation strategies ─────────────────────────────────────
POOL_CFG="$HERMES_HOME/pool-config.yaml"
MAIN_CFG="$HERMES_HOME/config.yaml"
if [[ -f "$POOL_CFG" ]] && ! grep -q "credential_pool_strategies" "$MAIN_CFG" 2>/dev/null; then
    cat "$POOL_CFG" >> "$MAIN_CFG"
    ok "Pool rotation strategies applied"
fi

# ── Step 4: Share Claude Code OAuth from Paperclip volume ─────────────────────
PAPERCLIP_CREDS="/paperclip/.claude/.credentials.json"
if [[ -f "$PAPERCLIP_CREDS" ]]; then
    mkdir -p "$CLAUDE_CREDS_DIR"
    cp "$PAPERCLIP_CREDS" "$CLAUDE_CREDS_DIR/.credentials.json"
    ok "Claude Code OAuth shared from Paperclip volume → Anthropic pool"
else
    log "No Claude OAuth at $PAPERCLIP_CREDS (run: docker compose exec paperclip claude auth login)"
fi

# ── Step 5: Seed credential pools ─────────────────────────────────────────────
log "Seeding credential pools..."

seed_key() {
    local provider="$1" key="$2" label="$3"
    [[ -z "$key" || "$key" == "sk-or-" || "$key" == "sk-ant-" || "$key" == "sk-" ]] && return
    hermes auth add "$provider" --type api-key --api-key "$key" --label "$label" \
        --non-interactive 2>/dev/null \
        && ok "  [$provider] ← $label" \
        || warn "  [$provider] ← $label (exists/error — skip)"
}

# OpenRouter — primary (round_robin)
seed_key "openrouter" "${OPENROUTER_API_KEY:-}"   "OPENROUTER_API_KEY"
seed_key "openrouter" "${OPENROUTER_API_KEY_2:-}" "OPENROUTER_API_KEY_2"
seed_key "openrouter" "${OPENROUTER_API_KEY_3:-}" "OPENROUTER_API_KEY_3"

# Anthropic — least_used (pairs with Claude Code OAuth above)
seed_key "anthropic" "${ANTHROPIC_API_KEY:-}"   "ANTHROPIC_API_KEY"
seed_key "anthropic" "${ANTHROPIC_API_KEY_2:-}" "ANTHROPIC_API_KEY_2"

# OpenAI — fill_first fallback
seed_key "openai" "${OPENAI_API_KEY:-}"   "OPENAI_API_KEY"
seed_key "openai" "${OPENAI_API_KEY_2:-}" "OPENAI_API_KEY_2"

# Google Gemini — OpenAI-compatible custom endpoint
if [[ -n "${GOOGLE_API_KEY:-}" ]]; then
    hermes model --provider openai \
        --api-key  "$GOOGLE_API_KEY" \
        --base-url "https://generativelanguage.googleapis.com/v1beta/openai/" \
        --model    "${GOOGLE_MODEL:-gemini-2.0-flash-lite}" \
        --label    "Google Gemini" \
        --non-interactive 2>/dev/null \
        && ok "  Custom: Google Gemini" || warn "  Gemini config failed (may exist)"
    [[ -n "${GOOGLE_API_KEY_2:-}" ]] && \
        hermes auth add "Google Gemini" --type api-key \
            --api-key "$GOOGLE_API_KEY_2" --label "GOOGLE_API_KEY_2" \
            --non-interactive 2>/dev/null \
        && ok "  [Google Gemini] ← GOOGLE_API_KEY_2" || true
fi

# Ollama — local LLMs, zero cost
if [[ -n "${OLLAMA_BASE_URL:-}" ]]; then
    hermes model --provider openai \
        --api-key  "ollama" \
        --base-url "${OLLAMA_BASE_URL}/v1" \
        --model    "${OLLAMA_MODEL:-llama3.2}" \
        --label    "Ollama (local)" \
        --non-interactive 2>/dev/null \
        && ok "  Custom: Ollama at ${OLLAMA_BASE_URL}" || warn "  Ollama config failed"
fi

echo ""
log "Credential pool status:"
hermes auth list 2>/dev/null || warn "hermes auth list failed"

# ── Step 6: Smoke test ─────────────────────────────────────────────────────────
log "Smoke test..."
SMOKE=$(hermes -q "Reply with exactly: READY" 2>&1 || true)
if echo "$SMOKE" | grep -qi "READY"; then
    ok "Smoke test passed"
else
    warn "Unexpected smoke response: ${SMOKE:0:120}"
    warn "Gateway will start — first task may fail"
fi

# ── Step 7: Git workspace ──────────────────────────────────────────────────────
if [[ -n "${AGENT_GIT_TOKEN:-}" && -n "${AGENT_REPO_URL:-}" ]]; then
    log "Configuring git workspace..."
    git config --global user.name  "${AGENT_GIT_USER:-ai-workforce-bot}"
    git config --global user.email "${AGENT_GIT_EMAIL:-agents@localhost}"
    git config --global credential.helper store
    REPO_HOST=$(echo "$AGENT_REPO_URL" | sed 's|https://||' | cut -d/ -f1)
    echo "https://${AGENT_GIT_USER:-ai-workforce-bot}:${AGENT_GIT_TOKEN}@${REPO_HOST}" \
        > /root/.git-credentials
    chmod 600 /root/.git-credentials
    WORKSPACE_DIR="${AGENT_WORKSPACE_MOUNT:-/workspace}"
    if [[ -d "$WORKSPACE_DIR/.git" ]]; then
        git -C "$WORKSPACE_DIR" pull --ff-only origin main 2>&1 || warn "Pull failed"
    else
        mkdir -p "$WORKSPACE_DIR"
        git clone "$AGENT_REPO_URL" "$WORKSPACE_DIR" 2>&1 || warn "Clone failed"
    fi
    ok "Git ready: ${AGENT_REPO_URL}"
fi

# ── Step 8: Start gateway (becomes PID 1) ─────────────────────────────────────
ok "Starting Hermes gateway (api_server on port ${API_SERVER_PORT:-8642})..."
echo ""
exec hermes gateway run
