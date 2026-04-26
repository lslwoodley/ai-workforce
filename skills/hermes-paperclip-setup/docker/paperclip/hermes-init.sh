#!/bin/sh
# hermes-init.sh — runs at container start (as node user, before Paperclip server)
# 1. Writes ~/.hermes/config.json with primary provider
# 2. Seeds credential pools for automatic failback:
#    OpenRouter (primary) → LM Studio GPU (free fallback) → Ollama → OpenAI → Gemini
# No Claude/Anthropic dependency.
set -e

HERMES_DIR="${HOME:-/paperclip}/.hermes"
HERMES_CONFIG="$HERMES_DIR/config.json"

mkdir -p "$HERMES_DIR"

# ── Step 1: Primary provider detection ───────────────────────────────────────
# Sets the default model written to config.json.
# Credential pool seeding below adds all providers as failbacks.

PROVIDER=""
MODEL=""

# 1. OpenRouter — best default: 200+ models, free tiers available
if [ -n "$OPENROUTER_API_KEY" ] && [ "$OPENROUTER_API_KEY" != "sk-or-" ]; then
    PROVIDER="openrouter"
    MODEL="${HERMES_MODEL:-nvidia/nemotron-3-super-120b-a12b:free}"
    echo "[hermes-init] Provider: OpenRouter | Model: $MODEL"

# 2. LM Studio — local Windows GPU, zero cost
elif [ -n "$LM_STUDIO_MODEL" ]; then
    PROVIDER="openai"
    LM_URL="${LM_STUDIO_BASE_URL:-http://host.docker.internal:1234}"
    MODEL="${LM_STUDIO_MODEL}"
    export OPENAI_API_KEY="lm-studio"
    export OPENAI_BASE_URL="${LM_URL}/v1"
    echo "[hermes-init] Provider: LM Studio GPU | URL: ${LM_URL} | Model: $MODEL"

# 3. Ollama — local LLMs, zero API cost
elif [ -n "$OLLAMA_BASE_URL" ]; then
    PROVIDER="openai"
    MODEL="${HERMES_MODEL:-llama3.2}"
    export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
    export OPENAI_BASE_URL="${OLLAMA_BASE_URL}/v1"
    echo "[hermes-init] Provider: Ollama (local) | URL: ${OLLAMA_BASE_URL} | Model: $MODEL"

# 4. OpenAI / GPT
elif [ -n "$OPENAI_API_KEY" ] && [ "$OPENAI_API_KEY" != "sk-" ]; then
    PROVIDER="openai"
    MODEL="${HERMES_MODEL:-gpt-4o-mini}"
    echo "[hermes-init] Provider: OpenAI | Model: $MODEL"

# 5. Google Gemini — via OpenAI-compatible endpoint
elif [ -n "$GOOGLE_API_KEY" ]; then
    PROVIDER="openai"
    MODEL="${HERMES_MODEL:-gemini-2.0-flash-lite}"
    export OPENAI_API_KEY="$GOOGLE_API_KEY"
    export OPENAI_BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai/"
    echo "[hermes-init] Provider: Google Gemini | Model: $MODEL"

else
    echo "[hermes-init] WARNING: No model API key found — defaulting to free OpenRouter model."
    PROVIDER="openrouter"
    MODEL="nvidia/nemotron-3-super-120b-a12b:free"
fi

# ── Step 2: Write primary configs ─────────────────────────────────────────────
# config.json  — legacy path kept for backward compat (some hermes versions read it)
cat > "$HERMES_CONFIG" << EOF
{
  "version": "1",
  "non_interactive": true,
  "provider": "$PROVIDER",
  "model": "$MODEL",
  "terminal_backend": "local",
  "tools": {
    "shell": true,
    "file_read": true,
    "file_write": true,
    "web_search": true,
    "web_fetch": true,
    "python": true,
    "memory": true
  },
  "memory": {
    "enabled": true,
    "nudge_interval": 5
  },
  "gateway": {
    "enabled": false
  }
}
EOF
echo "[hermes-init] config.json written to $HERMES_CONFIG"

# config.yaml — canonical hermes config (hermes_cli/config.py reads this)
# Also read by hermes-paperclip-adapter detectModel() which looks for:
#   model:\n  default: <value>\n  provider: <value>
# The nested model section is the format hermes supports natively (see config.py:3154).
HERMES_YAML="$HERMES_DIR/config.yaml"
cat > "$HERMES_YAML" << EOF
# Written by hermes-init.sh — regenerated on every container start
model:
  default: "$MODEL"
  provider: "$PROVIDER"
EOF
echo "[hermes-init] config.yaml written to $HERMES_YAML"

# ── Step 3: Seed credential pools for failback ───────────────────────────────
# hermes auth add is idempotent — safe to run every startup.
# Pool priority: OpenRouter → LM Studio GPU → Ollama → OpenAI → Gemini

seed_pool() {
    provider="$1"; key="$2"; label="$3"
    [ -z "$key" ] && return
    hermes auth add "$provider" --type api-key --api-key "$key" \
        --label "$label" --non-interactive 2>/dev/null \
        && echo "[hermes-init] Pool: [$provider] ← $label" \
        || echo "[hermes-init] Pool: [$provider] ← $label (exists/skip)"
}

# OpenRouter pool
seed_pool "openrouter" "${OPENROUTER_API_KEY:-}"   "OPENROUTER_API_KEY"
seed_pool "openrouter" "${OPENROUTER_API_KEY_2:-}" "OPENROUTER_API_KEY_2"
seed_pool "openrouter" "${OPENROUTER_API_KEY_3:-}" "OPENROUTER_API_KEY_3"

# DeepSeek pool — cheap cloud reasoning
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    hermes model --provider openai \
        --api-key  "$DEEPSEEK_API_KEY" \
        --base-url "https://api.deepseek.com/v1" \
        --model    "${DEEPSEEK_MODEL:-deepseek-reasoner}" \
        --label    "DeepSeek" \
        --non-interactive 2>/dev/null \
        && echo "[hermes-init] Pool: DeepSeek → ${DEEPSEEK_MODEL:-deepseek-reasoner}" \
        || echo "[hermes-init] Pool: DeepSeek (exists/skip)"
fi

# LM Studio GPU — local Windows host, zero cost, Kimi K2 or any loaded model
if [ -n "${LM_STUDIO_MODEL:-}" ]; then
    LM_URL="${LM_STUDIO_BASE_URL:-http://host.docker.internal:1234}"
    hermes model --provider openai \
        --api-key  "lm-studio" \
        --base-url "${LM_URL}/v1" \
        --model    "${LM_STUDIO_MODEL}" \
        --label    "LM Studio GPU" \
        --non-interactive 2>/dev/null \
        && echo "[hermes-init] Pool: LM Studio GPU at ${LM_URL} → ${LM_STUDIO_MODEL}" \
        || echo "[hermes-init] Pool: LM Studio GPU (exists/skip)"
fi

# Ollama pool
if [ -n "${OLLAMA_BASE_URL:-}" ]; then
    hermes model --provider openai \
        --api-key  "ollama" \
        --base-url "${OLLAMA_BASE_URL}/v1" \
        --model    "${OLLAMA_MODEL:-llama3.2}" \
        --label    "Ollama (local)" \
        --non-interactive 2>/dev/null \
        && echo "[hermes-init] Pool: Ollama at ${OLLAMA_BASE_URL}" \
        || echo "[hermes-init] Pool: Ollama (exists/skip)"
fi

# Anthropic pool (optional)
seed_pool "anthropic" "${ANTHROPIC_API_KEY:-}"   "ANTHROPIC_API_KEY"
seed_pool "anthropic" "${ANTHROPIC_API_KEY_2:-}" "ANTHROPIC_API_KEY_2"

# OpenAI pool
seed_pool "openai" "${OPENAI_API_KEY:-}" "OPENAI_API_KEY"

echo "[hermes-init] Credential pools seeded. Failback order: OpenRouter → LM Studio GPU → Ollama → Anthropic → OpenAI"
