#!/usr/bin/env python3
"""
health_check.py — Verify the Hermes + Paperclip integration is correctly wired.
Run this after setup or any time something seems off.
"""

import os, sys, subprocess, json
from pathlib import Path
from dotenv import load_dotenv
import httpx

load_dotenv(Path(__file__).parent.parent / ".env")

PAPERCLIP_API_URL = os.getenv("PAPERCLIP_API_URL", "http://localhost:3000")
PAPERCLIP_API_KEY = os.getenv("PAPERCLIP_API_KEY", "")
MCP_SERVER_PORT   = int(os.getenv("MCP_SERVER_PORT", "8765"))

PASS  = "\033[92m✓\033[0m"
FAIL  = "\033[91m✗\033[0m"
WARN  = "\033[93m⚠\033[0m"

results = []

def check(label: str, passed: bool, detail: str = ""):
    icon = PASS if passed else FAIL
    line = f"{icon} {label}"
    if detail:
        line += f"  ({detail})"
    print(line)
    results.append(passed)


# ── 1. Paperclip API ────────────────────────────────────────────────────────
try:
    r = httpx.get(
        f"{PAPERCLIP_API_URL}/api/health",
        headers={"Authorization": f"Bearer {PAPERCLIP_API_KEY}"},
        timeout=5,
    )
    check("Paperclip API reachable", r.status_code == 200, PAPERCLIP_API_URL)
    if r.status_code == 200:
        agents = r.json().get("agents", [])
        check(f"{len(agents)} active agent(s) found", True)
except Exception as e:
    check("Paperclip API reachable", False, str(e))


# ── 2. Hermes CLI ───────────────────────────────────────────────────────────
try:
    out = subprocess.run(["hermes", "--version"], capture_output=True, text=True, timeout=5)
    version = out.stdout.strip() or out.stderr.strip()
    check("Hermes CLI available", out.returncode == 0, version)
except FileNotFoundError:
    check("Hermes CLI available", False, "not found — run: npm install -g @nousresearch/hermes-agent")


# ── 3. hermes-paperclip-adapter ─────────────────────────────────────────────
try:
    out = subprocess.run(["hermes-paperclip", "--version"], capture_output=True, text=True, timeout=5)
    version = out.stdout.strip() or out.stderr.strip()
    check("Adapter installed", out.returncode == 0, version)
except FileNotFoundError:
    check("Adapter installed", False, "not found — run: npm install -g hermes-paperclip-adapter")


# ── 4. Sessions directory ────────────────────────────────────────────────────
sessions_dir = Path(os.getenv("HERMES_SESSIONS_DIR", Path.home() / ".hermes" / "sessions"))
check(
    "Hermes sessions directory exists",
    sessions_dir.exists(),
    str(sessions_dir) if sessions_dir.exists() else f"missing: {sessions_dir}",
)


# ── 5. Skills directory ──────────────────────────────────────────────────────
skills_dir = Path(os.getenv("HERMES_SKILLS_DIR", Path.home() / ".hermes" / "skills"))
if skills_dir.exists():
    skill_count = len(list(skills_dir.glob("*.md")))
    check("Hermes skills directory exists", True, f"{skill_count} skill(s) found at {skills_dir}")
else:
    print(f"{WARN} Hermes skills directory not found ({skills_dir}) — will be created on first run")


# ── 6. MCP server (optional) ─────────────────────────────────────────────────
try:
    r = httpx.get(f"http://localhost:{MCP_SERVER_PORT}/health", timeout=2)
    check("MCP server running", r.status_code == 200, f"port {MCP_SERVER_PORT}")
except Exception:
    print(f"{WARN} MCP server: not running (optional — start with: python scripts/mcp_server.py)")


# ── Summary ──────────────────────────────────────────────────────────────────
print()
passed = sum(results)
total  = len(results)
if passed == total:
    print(f"\033[92mAll {total} checks passed.\033[0m")
    sys.exit(0)
else:
    failed = total - passed
    print(f"\033[91m{failed}/{total} check(s) failed. Review output above.\033[0m")
    sys.exit(1)
