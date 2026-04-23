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

# Hand off to Paperclip's official entrypoint (which does the real gosu)
exec /app/scripts/docker-entrypoint.sh "$@"
