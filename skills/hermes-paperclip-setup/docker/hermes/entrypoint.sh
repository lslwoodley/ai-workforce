#!/bin/bash
# Hermes Worker entrypoint — idempotent startup with full error reporting
#
# Responsibilities:
#   1. Wait for Paperclip API to be ready (with timeout and clear errors)
#   2. Configure Hermes model from environment variables (idempotent)
#   3. Configure git identity so agents can commit work to the repo
#   4. Verify Hermes is functional
#   5. Start the hermes-paperclip-adapter (PID 1 via exec)
#
# On error: prints diagnostics and exits with non-zero code so Docker
# can apply the restart policy and the logs are clear about what failed.

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Output helpers
# ══════════════════════════════════════════════════════════════════════════════

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $*" >&2; }

# ══════════════════════════════════════════════════════════════════════════════
# Error trap — print context and exit clearly
# ══════════════════════════════════════════════════════════════════════════════

handle_error() {
    local exit_code=$?
    local line_no=$1
    local cmd=$2

    err "════════════════════════════════════════"
    err "  STARTUP FAILED"
    err "  Line   : $line_no"
    err "  Command: $cmd"
    err "  Exit   : $exit_code"
    err "════════════════════════════════════════"
    err ""
    err "  Common causes:"
    err "    • No model API key set (OPENROUTER_API_KEY / ANTHROPIC_API_KEY)"
    err "    • Paperclip API not reachable at $PAPERCLIP_API_URL"
    err "    • hermes-paperclip-adapter not installed"
    err ""
    err "  To debug: docker compose exec hermes-worker bash"
    exit $exit_code
}

trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

# ══════════════════════════════════════════════════════════════════════════════
# Environment validation
# ══════════════════════════════════════════════════════════════════════════════

PAPERCLIP_API_URL="${PAPERCLIP_API_URL:-http://paperclip:3100}"
PAPERCLIP_API_KEY="${PAPERCLIP_API_KEY:-}"
HERMES_MODEL="${HERMES_MODEL:-openrouter/anthropic/claude-3.5-sonnet}"
HERMES_SESSIONS_DIR="${HERMES_SESSIONS_DIR:-/hermes/sessions}"
HERMES_SKILLS_DIR="${HERMES_SKILLS_DIR:-/hermes/skills}"
ADAPTER_HEARTBEAT_INTERVAL="${ADAPTER_HEARTBEAT_INTERVAL:-30}"
ADAPTER_MAX_WORKERS="${ADAPTER_MAX_WORKERS:-4}"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Hermes Agent Worker"
echo "  Paperclip : $PAPERCLIP_API_URL"
echo "  Model     : $HERMES_MODEL"
echo "  Sessions  : $HERMES_SESSIONS_DIR"
echo "  Skills    : $HERMES_SKILLS_DIR"
echo "  Heartbeat : ${ADAPTER_HEARTBEAT_INTERVAL}s"
echo "  Workers   : $ADAPTER_MAX_WORKERS"
echo "═══════════════════════════════════════════════════"
echo ""

# Validate at least one API key is present
API_KEY_SET=false
for key_var in OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY; do
    val="${!key_var:-}"
    if [[ -n "$val" && "$val" != "sk-or-" && "$val" != "sk-ant-" ]]; then
        API_KEY_SET=true
        break
    fi
done

if [[ "$API_KEY_SET" != "true" ]]; then
    err "No model API key is set."
    err "Set at least one of: OPENROUTER_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY"
    err "Edit your .env file and run: docker compose up -d"
    exit 1
fi

# Validate directories exist (mounted volumes)
for dir in "$HERMES_SESSIONS_DIR" "$HERMES_SKILLS_DIR"; do
    if [[ ! -d "$dir" ]]; then
        warn "Directory $dir does not exist — creating..."
        mkdir -p "$dir" || { err "Cannot create $dir — check volume mount"; exit 1; }
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
# Step 1: Wait for Paperclip
# ══════════════════════════════════════════════════════════════════════════════

log "Waiting for Paperclip API at $PAPERCLIP_API_URL ..."

MAX_WAIT=120   # seconds
INTERVAL=5
elapsed=0

until curl -sf --max-time 3 "${PAPERCLIP_API_URL}/api/health" > /dev/null 2>&1; do
    if [[ $elapsed -ge $MAX_WAIT ]]; then
        err "Paperclip did not become ready after ${MAX_WAIT}s."
        err ""
        err "  Check Paperclip logs: docker compose logs paperclip --tail 30"
        err "  Is the Paperclip container running? docker compose ps"
        exit 1
    fi
    log "  Paperclip not ready yet (${elapsed}s elapsed) — retrying in ${INTERVAL}s..."
    sleep $INTERVAL
    elapsed=$((elapsed + INTERVAL))
done

ok "Paperclip is ready (${elapsed}s)"

# ══════════════════════════════════════════════════════════════════════════════
# Step 2: Verify Hermes CLI
# ══════════════════════════════════════════════════════════════════════════════

log "Checking Hermes CLI..."

if ! command -v hermes &>/dev/null; then
    err "hermes CLI not found in PATH."
    err "This means the Docker image build failed or the venv PATH is wrong."
    err "Rebuild the image: docker compose build --no-cache hermes-worker"
    exit 1
fi

HERMES_VERSION=$(hermes --version 2>&1 || echo "unknown")
ok "Hermes CLI: $HERMES_VERSION"

# ══════════════════════════════════════════════════════════════════════════════
# Step 3: Configure Hermes model (idempotent)
# ══════════════════════════════════════════════════════════════════════════════

log "Configuring Hermes model..."

# Check if already configured to the right model
CURRENT_MODEL=$(hermes config get model 2>/dev/null || echo "")

if [[ "$CURRENT_MODEL" == "$HERMES_MODEL" ]]; then
    ok "Hermes model already set to $HERMES_MODEL — skipping"
else
    if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
        hermes config set provider openrouter --non-interactive 2>/dev/null || warn "Could not set provider (may already be set)"
        hermes config set model "$HERMES_MODEL" --non-interactive 2>/dev/null || warn "Could not set model (may already be set)"
        ok "Model configured: $HERMES_MODEL via OpenRouter"

    elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        hermes config set provider anthropic --non-interactive 2>/dev/null || warn "Could not set provider"
        hermes config set model "claude-sonnet-4-6" --non-interactive 2>/dev/null || warn "Could not set model"
        ok "Model configured: claude-sonnet-4-6 via Anthropic"

    elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
        hermes config set provider openai --non-interactive 2>/dev/null || warn "Could not set provider"
        hermes config set model "gpt-4o" --non-interactive 2>/dev/null || warn "Could not set model"
        ok "Model configured: gpt-4o via OpenAI"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 4: Smoke-test Hermes (non-interactive, single query)
# ══════════════════════════════════════════════════════════════════════════════

log "Running Hermes smoke test..."

SMOKE_RESPONSE=$(hermes -q "Reply with exactly: READY" --non-interactive 2>&1 || true)
if echo "$SMOKE_RESPONSE" | grep -qi "READY\|ready"; then
    ok "Hermes smoke test passed"
else
    warn "Hermes smoke test returned unexpected response: ${SMOKE_RESPONSE:0:100}"
    warn "This may indicate a model API issue. Adapter will still start — first task may fail."
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 5: Verify adapter
# ══════════════════════════════════════════════════════════════════════════════

log "Checking hermes-paperclip-adapter..."

if ! command -v hermes-paperclip &>/dev/null; then
    err "hermes-paperclip-adapter not found in PATH."
    err "Rebuild the image: docker compose build --no-cache hermes-worker"
    exit 1
fi

ADAPTER_VERSION=$(hermes-paperclip --version 2>&1 || echo "unknown")
ok "Adapter: $ADAPTER_VERSION"

# ══════════════════════════════════════════════════════════════════════════════
# Step 6: Start the adapter (replaces this process via exec — becomes PID 1)
# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# Step 5: Configure git for agent commits (optional — only if token is set)
# ══════════════════════════════════════════════════════════════════════════════

if [[ -n "${AGENT_GIT_TOKEN:-}" && -n "${AGENT_REPO_URL:-}" ]]; then
    log "Configuring git for agent workspace commits..."

    GIT_USER="${AGENT_GIT_USER:-ai-workforce-bot}"
    GIT_EMAIL="${AGENT_GIT_EMAIL:-agents@localhost}"

    git config --global user.name  "$GIT_USER"
    git config --global user.email "$GIT_EMAIL"

    # Store credentials so agents can push without prompts
    # Uses the credential store (plaintext in container — token is scoped & revocable)
    git config --global credential.helper store
    # Write the token into the credential store
    REPO_HOST=$(echo "$AGENT_REPO_URL" | sed 's|https://||' | cut -d/ -f1)
    echo "https://${GIT_USER}:${AGENT_GIT_TOKEN}@${REPO_HOST}" > /root/.git-credentials
    chmod 600 /root/.git-credentials

    # Clone or update the workspace
    WORKSPACE_DIR="${AGENT_WORKSPACE_MOUNT:-/workspace}"
    if [[ -d "$WORKSPACE_DIR/.git" ]]; then
        log "Workspace repo already cloned at $WORKSPACE_DIR — pulling latest..."
        git -C "$WORKSPACE_DIR" pull --ff-only origin main 2>&1 || \
            warn "Could not pull latest — proceeding with existing state"
    elif [[ -d "$WORKSPACE_DIR" && -n "$(ls -A $WORKSPACE_DIR 2>/dev/null)" ]]; then
        warn "Workspace dir $WORKSPACE_DIR exists but is not a git repo — agents will write files but cannot push"
    else
        log "Cloning repo into $WORKSPACE_DIR..."
        mkdir -p "$WORKSPACE_DIR"
        git clone "$AGENT_REPO_URL" "$WORKSPACE_DIR" 2>&1 || \
            warn "Clone failed — check AGENT_REPO_URL and AGENT_GIT_TOKEN"
    fi

    ok "Git configured: $GIT_USER <$GIT_EMAIL>"
    ok "Agents can push to: $AGENT_REPO_URL"
    ok "Branch prefix: ${AGENT_REPO_BRANCH_PREFIX:-agent}/<session-id>/<topic>"
else
    log "Agent git config skipped (AGENT_GIT_TOKEN or AGENT_REPO_URL not set)"
    log "  To enable: add AGENT_GIT_TOKEN and AGENT_REPO_URL to .env"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 6: Start the adapter
# ══════════════════════════════════════════════════════════════════════════════

log "Starting hermes-paperclip-adapter..."
echo ""

AUTH_ARGS=()
if [[ -n "$PAPERCLIP_API_KEY" ]]; then
    AUTH_ARGS=(--paperclip-key "$PAPERCLIP_API_KEY")
fi

exec hermes-paperclip start \
    --paperclip-url  "$PAPERCLIP_API_URL" \
    "${AUTH_ARGS[@]}" \
    --sessions-dir   "$HERMES_SESSIONS_DIR" \
    --skills-dir     "$HERMES_SKILLS_DIR" \
    --heartbeat      "$ADAPTER_HEARTBEAT_INTERVAL" \
    --max-workers    "$ADAPTER_MAX_WORKERS"
