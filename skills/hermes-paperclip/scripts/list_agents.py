#!/usr/bin/env python3
"""
list_agents.py — Show all active Hermes workers registered in Paperclip.

Usage:
  python scripts/list_agents.py [--json]
"""

import argparse, os, json
from pathlib import Path
from datetime import datetime, timezone
from dotenv import load_dotenv
import httpx

load_dotenv(Path(__file__).parent.parent / ".env")

PAPERCLIP_API_URL = os.getenv("PAPERCLIP_API_URL", "http://localhost:3000")
PAPERCLIP_API_KEY = os.getenv("PAPERCLIP_API_KEY", "")


def format_ago(iso_str: str | None) -> str:
    if not iso_str:
        return "never"
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        delta = datetime.now(timezone.utc) - dt
        s = int(delta.total_seconds())
        if s < 60:       return f"{s}s ago"
        if s < 3600:     return f"{s // 60}m ago"
        if s < 86400:    return f"{s // 3600}h ago"
        return f"{s // 86400}d ago"
    except Exception:
        return iso_str


def status_color(status: str) -> str:
    colors = {"working": "\033[92m", "idle": "\033[94m", "paused": "\033[93m", "error": "\033[91m"}
    reset = "\033[0m"
    return f"{colors.get(status, '')}{status}{reset}"


def main():
    parser = argparse.ArgumentParser(description="List all Hermes agents in Paperclip")
    parser.add_argument("--json", action="store_true", help="Output raw JSON")
    args = parser.parse_args()

    try:
        r = httpx.get(
            f"{PAPERCLIP_API_URL}/api/agents",
            headers={"Authorization": f"Bearer {PAPERCLIP_API_KEY}"},
            timeout=10,
        )
        r.raise_for_status()
        agents = r.json().get("agents", [])
    except Exception as e:
        print(f"\033[91m✗ Could not fetch agents: {e}\033[0m")
        raise SystemExit(1)

    if args.json:
        print(json.dumps(agents, indent=2))
        return

    if not agents:
        print("No agents registered. Use spawn_agent.py to add workers.")
        return

    col = [
        ("ID",          24),
        ("Role",        28),
        ("Department",  16),
        ("Status",      12),
        ("Model",       36),
        ("Last active", 14),
    ]
    header = "  ".join(f"{h:<{w}}" for h, w in col)
    divider = "─" * len(header)
    print(f"\n{header}")
    print(divider)

    for a in agents:
        row = [
            a.get("sessionId", a.get("id", "?")),
            a.get("role", "?"),
            a.get("department", "?"),
            status_color(a.get("status", "unknown")),
            a.get("model", "?"),
            format_ago(a.get("lastActiveAt")),
        ]
        # status_color adds ANSI codes which throw off column width
        status_raw = a.get("status", "unknown")
        padded = []
        for i, (val, (_, w)) in enumerate(zip(row, col)):
            if i == 3:  # status column with colour codes
                padded.append(f"{val}{' ' * max(0, w - len(status_raw))}")
            else:
                padded.append(f"{str(val):<{w}}")
        print("  ".join(padded))

    print()
    total   = len(agents)
    working = sum(1 for a in agents if a.get("status") == "working")
    idle    = sum(1 for a in agents if a.get("status") == "idle")
    print(f"Total: {total}  |  Working: {working}  |  Idle: {idle}")


if __name__ == "__main__":
    main()
