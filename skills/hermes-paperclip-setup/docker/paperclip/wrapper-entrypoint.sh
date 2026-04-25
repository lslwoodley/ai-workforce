#!/bin/sh
# wrapper-entrypoint.sh — runs as root before Paperclip's official entrypoint
#
# Why this exists:
#   Paperclip's docker-entrypoint.sh creates files in /paperclip as root on
#   first run (instance .env, Postgres init, etc.), then gosu-drops to node.
#   After a restart the node process can't read those root-owned files, causing:
#     EACCES: permission denied, open '/paperclip/instances/default/.env'
#
#   This wrapper runs as root PID 1, fixes ownership, then hands off to the
#   official entrypoint. It runs every time — idempotent, fast, ~0.1s overhead.

# Fix ownership — silence errors if volume is empty or already correct
chown -R node:node /paperclip 2>/dev/null || true

# Configure git credentials for private repo access (runs as root, sets for node user)
if [ -n "${AGENT_GIT_TOKEN:-}" ]; then
    REPO_HOST=$(echo "${AGENT_REPO_URL:-github.com}" | sed 's|https://||' | cut -d/ -f1)
    mkdir -p /home/node
    echo "https://${AGENT_GIT_USER:-git}:${AGENT_GIT_TOKEN}@${REPO_HOST}" > /home/node/.git-credentials
    git config --global credential.helper "store --file /home/node/.git-credentials"
    git config --global user.name "${AGENT_GIT_USER:-ai-workforce-bot}"
    git config --global user.email "agents@localhost"
    chown node:node /home/node/.git-credentials 2>/dev/null || true
fi

# Hand off to Paperclip's official entrypoint (which does the real gosu)
exec /app/scripts/docker-entrypoint.sh "$@"
