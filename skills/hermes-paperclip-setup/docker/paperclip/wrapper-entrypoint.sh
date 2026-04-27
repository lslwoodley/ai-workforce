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
# Removing the stale PID here (as root, before gosu-drop) lets Paperclip start
# a fresh Postgres instance on every container boot.
find /paperclip -name "postmaster.pid" -delete 2>/dev/null || true
find /paperclip -name ".s.PGSQL.*" -delete 2>/dev/null || true

# Fix ownership — silence errors if volume is empty or already correct
chown -R node:node /paperclip 2>/dev/null || true

# Configure git credentials for private repo access
# node user HOME=/paperclip (set in Dockerfile ENV), so write gitconfig there
if [ -n "${AGENT_GIT_TOKEN:-}" ]; then
    REPO_HOST=$(echo "${AGENT_REPO_URL:-github.com}" | sed 's|https://||' | cut -d/ -f1)
    mkdir -p /paperclip
    # Credentials file — node user's HOME is /paperclip
    echo "https://${AGENT_GIT_USER:-git}:${AGENT_GIT_TOKEN}@${REPO_HOST}" > /paperclip/.git-credentials
    # Global gitconfig for the node user (HOME=/paperclip → /paperclip/.gitconfig)
    cat > /paperclip/.gitconfig << GITCFG
[credential]
    helper = store --file /paperclip/.git-credentials
[user]
    name = ${AGENT_GIT_USER:-ai-workforce-bot}
    email = agents@localhost
GITCFG
    chown node:node /paperclip/.git-credentials /paperclip/.gitconfig 2>/dev/null || true
fi

# ── Seed Paperclip instance config.json ──────────────────────────────────────
# The CLI tool (pnpm paperclipai) and hostname-allow middleware read from
# /paperclip/instances/default/config.json. If this file is missing (e.g. after
# a container rebuild or first boot) the CLI fails and hostname checks break.
# We write it here on every start so it is always present and up to date.
#
# PAPERCLIP_ALLOWED_HOSTNAMES: comma-separated list of extra allowed hostnames.
# Always includes 'localhost'; add your Tailscale IP via the env var.
INSTANCE_DIR="/paperclip/instances/default"
CONFIG_JSON="$INSTANCE_DIR/config.json"
mkdir -p "$INSTANCE_DIR"

# Build JSON array of allowed hostnames
EXTRA_HOSTS="${PAPERCLIP_ALLOWED_HOSTNAMES:-}"
HOSTS_JSON='"localhost"'
for host in $(echo "$EXTRA_HOSTS" | tr ',' ' '); do
    host=$(echo "$host" | tr -d ' ')
    [ -n "$host" ] && HOSTS_JSON="$HOSTS_JSON,\"$host\""
done

cat > "$CONFIG_JSON" << PAPERCLIP_CFG
{"allowedHostnames":[$HOSTS_JSON]}
PAPERCLIP_CFG
chown node:node "$CONFIG_JSON" 2>/dev/null || true
echo "[wrapper] config.json written — allowedHostnames: localhost $EXTRA_HOSTS"

# Hand off to Paperclip's official entrypoint (which does the real gosu)
exec /app/scripts/docker-entrypoint.sh "$@"
