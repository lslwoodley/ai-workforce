#!/bin/sh
# hermes-init.sh — runs at container start (as node user, before Paperclip server)
# Writes ~/.hermes/config.json based on available environment variables.
# Priority: OpenRouter → Ollama (local) → OpenAI/GPT → Gemini direct
# No Claude/Anthropic dependency.
set -e

HERMES_DIR="${HOME:-/paperclip}/.hermes"
HERMES_CONFIG="$HERMES_DIR/config.json"

mkdir -p "$HERMES_DIR"

# ── Provider auto-detection ───────────────────────────────────────────────────

PROVIDER=""
MODEL=""
BASE_URL=""
API_KEY_ENV=""

# 1. OpenRouter — best default: 200+ models, free tiers available
if [ -n "$OPENROUTER_API_KEY" ] && [ "$OPENROUTER_API_KEY" != "sk-or-" ]; then
    PROVIDER="openrouter"
    MODEL="${HERMES_MODEL:-openrouter/nvidia/nemotron-3-super-120b-a12b:free}"
    echo "[hermes-init] Provider: OpenRouter | Model: $MODEL"

# 2. Ollama — local LLMs, zero API cost
elif [ -n "$OLLAMA_BASE_URL" ]; then
    PROVIDER="openai"
    BASE_URL="${OLLAMA_BASE_URL}/v1"
    MODEL="${HERMES_MODEL:-llama3.2}"
    # Ollama doesn't check the key but the OpenAI SDK requires one
    export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
    export OPENAI_BASE_URL="$BASE_URL"
    echo "[hermes-init] Provider: Ollama (local) | URL: $BASE_URL | Model: $MODEL"

# 3. OpenAI / GPT
elif [ -n "$OPENAI_API_KEY" ] && [ "$OPENAI_API_KEY" != "sk-" ]; then
    PROVIDER="openai"
    MODEL="${HERMES_MODEL:-gpt-4o-mini}"
    echo "[hermes-init] Provider: OpenAI | Model: $MODEL"

# 4. Google Gemini — via OpenAI-compatible endpoint
elif [ -n "$GOOGLE_API_KEY" ]; then
    PROVIDER="openai"
    BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai/"
    MODEL="${HERMES_MODEL:-gemini-2.0-flash-lite}"
    export OPENAI_API_KEY="$GOOGLE_API_KEY"
    export OPENAI_BASE_URL="$BASE_URL"
    echo "[hermes-init] Provider: Google Gemini | Model: $MODEL"

else
    echo "[hermes-init] WARNING: No model API key found."
    echo "  Set one of: OPENROUTER_API_KEY, OLLAMA_BASE_URL, OPENAI_API_KEY, GOOGLE_API_KEY"
    echo "  Hermes adapter will be unconfigured until a key is provided."
    # Write a placeholder config so hermes doesn't crash on first probe
    PROVIDER="openrouter"
    MODEL="openrouter/nvidia/nemotron-3-super-120b-a12b:free"
fi

# ── Write config ──────────────────────────────────────────────────────────────

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

echo "[hermes-init] Config written to $HERMES_CONFIG"
