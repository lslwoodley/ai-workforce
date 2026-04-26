#!/usr/bin/env python3
"""
hermes-wrapper — self-healing shim for the hermes CLI.

Sits in front of the real hermes binary and intercepts --resume <session_id>
calls. If the session ID is invalid (e.g. "from", a single word, or any string
that doesn't match the hermes session ID format), it strips the --resume flag
and starts a fresh session instead.

Why this exists:
  hermes-paperclip-adapter stores the last session ID in Paperclip's DB and
  passes it as --resume on every heartbeat. If a previous run failed and the
  adapter parsed garbage (like the word "from" out of an error message) as the
  session ID, every subsequent heartbeat fails with:
      Session not found: from
  This wrapper breaks the cycle automatically — no manual DB cleanup required.

Session ID format: 20260426_140538_a38249  (YYYYMMDD_HHMMSS_hex6+)
"""

import os
import re
import sys

HERMES_REAL = "/usr/local/bin/hermes.real"
SESSION_ID_RE = re.compile(r"^\d{8}_\d{6}_[a-zA-Z0-9]+$")


def is_valid_session_id(value: str) -> bool:
    return bool(SESSION_ID_RE.match(value))


def main():
    args = list(sys.argv[1:])
    clean_args = []
    i = 0
    stripped = False

    while i < len(args):
        if args[i] == "--resume" and i + 1 < len(args):
            session_id = args[i + 1]
            if not is_valid_session_id(session_id):
                print(
                    f"[hermes-wrapper] Invalid session ID '{session_id}' — "
                    f"stripping --resume and starting fresh session",
                    file=sys.stderr,
                )
                i += 2  # skip both --resume and the bad ID
                stripped = True
                continue
        clean_args.append(args[i])
        i += 1

    if stripped:
        print(
            f"[hermes-wrapper] Running fresh: hermes {' '.join(clean_args[:6])}...",
            file=sys.stderr,
        )

    os.execv(HERMES_REAL, [HERMES_REAL] + clean_args)


if __name__ == "__main__":
    main()
