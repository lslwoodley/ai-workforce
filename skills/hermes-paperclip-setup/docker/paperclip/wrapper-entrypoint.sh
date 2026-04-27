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

# ── Clear stale embedded-PostgreSQL PID file ─────────────────────────────────
# Paperclip's embedded Postgres writes a postmaster.pid to the data volume.
# If the container was killed/restarted the old PID is dead but the file
# persists in the named volume.  Paperclip then says "already running (pidN)"
# and skips startup, leaving nothing listening on the port → ECONNREFUSED.
find /paperclip -name "postmaster.pid" -delete 2>/dev/null || true
find /paperclip -name ".s.PGSQL.*" -delete 2>/dev/null || true

# Fix ownership — silence errors if volume is empty or already correct
chown -R node:node /paperclip 2>/dev/null || true

# Configure git credentials for private repo access
if [ -n "${AGENT_GIT_TOKEN:-}" ]; then
    REPO_HOST=$(echo "${AGENT_REPO_URL:-github.com}" | sed 's|https://||' | cut -d/ -f1)
    mkdir -p /paperclip
    echo "https://${AGENT_GIT_USER:-git}:${AGENT_GIT_TOKEN}@${REPO_HOST}" > /paperclip/.git-credentials
    cat > /paperclip/.gitconfig << GITCFG
[credential]
    helper = store --file /paperclip/.git-credentials
[user]
    name = ${AGENT_GIT_USER:-ai-workforce-bot}
    email = agents@localhost
GITCFG
    chown node:node /paperclip/.git-credentials /paperclip/.gitconfig 2>/dev/null || true
fi

# Hand off to Paperclip's official entrypoint (which does the real gosu)
exec /app/scripts/docker-entrypoint.sh "$@"
