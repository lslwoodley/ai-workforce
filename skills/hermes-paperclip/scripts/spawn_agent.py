#!/usr/bin/env python3
"""
spawn_agent.py — Register a new Hermes worker in a Paperclip role.

Usage:
  python scripts/spawn_agent.py \
    --role "Head of Engineering" \
    --department engineering \
    --session-id eng-head-001 \
    --model openrouter/anthropic/claude-3.5-sonnet \
    [--system-prompt "You are the Head of Engineering..."] \
    [--budget 50.00]
"""

import argparse, os, json, subprocess
from pathlib import Path
from dotenv import load_dotenv
import httpx

load_dotenv(Path(__file__).parent.parent / ".env")

PAPERCLIP_API_URL = os.getenv("PAPERCLIP_API_URL", "http://localhost:3000")
PAPERCLIP_API_KEY = os.getenv("PAPERCLIP_API_KEY", "")
HERMES_SESSIONS_DIR = Path(os.getenv("HERMES_SESSIONS_DIR", Path.home() / ".hermes" / "sessions"))


def spawn_agent(
    role: str,
    department: str,
    session_id: str,
    model: str,
    system_prompt: str | None = None,
    budget: float | None = None,
) -> dict:
    """
    1. Create Hermes session directory
    2. Write adapter config
    3. Register agent in Paperclip
    4. Return registration result
    """

    # ── 1. Prepare Hermes session ─────────────────────────────────────────
    session_dir = HERMES_SESSIONS_DIR / session_id
    session_dir.mkdir(parents=True, exist_ok=True)

    adapter_config = {
        "sessionId": session_id,
        "model": model,
        "paperclipApiUrl": PAPERCLIP_API_URL,
        "paperclipApiKey": PAPERCLIP_API_KEY,
        "heartbeatInterval": int(os.getenv("ADAPTER_HEARTBEAT_INTERVAL", "30")),
        "maxWorkers": int(os.getenv("ADAPTER_MAX_WORKERS", "4")),
    }
    if system_prompt:
        adapter_config["systemPrompt"] = system_prompt

    config_path = session_dir / "adapter.json"
    config_path.write_text(json.dumps(adapter_config, indent=2))
    print(f"  Adapter config written: {config_path}")

    # ── 2. Verify Hermes can resume/init the session ──────────────────────
    result = subprocess.run(
        ["hermes", "--resume", session_id, "-q", f"You are the {role} in the {department} department. Acknowledge your role in one sentence."],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Hermes session init failed: {result.stderr}")
    print(f"  Hermes session initialised. Agent response: {result.stdout.strip()[:120]}")

    # ── 3. Register in Paperclip ──────────────────────────────────────────
    payload: dict = {
        "sessionId": session_id,
        "role": role,
        "department": department,
        "model": model,
        "adapterConfigPath": str(config_path),
        "status": "idle",
    }
    if budget is not None:
        payload["budgetUsd"] = budget

    r = httpx.post(
        f"{PAPERCLIP_API_URL}/api/agents",
        json=payload,
        headers={"Authorization": f"Bearer {PAPERCLIP_API_KEY}"},
        timeout=10,
    )
    r.raise_for_status()
    agent = r.json()
    print(f"  Registered in Paperclip. Agent ID: {agent.get('id', session_id)}")
    return agent


def main():
    parser = argparse.ArgumentParser(description="Spawn a Hermes worker in a Paperclip role")
    parser.add_argument("--role",         required=True,  help="Job title / role name")
    parser.add_argument("--department",   required=True,  help="Department (engineering, marketing, etc.)")
    parser.add_argument("--session-id",   required=True,  help="Stable session ID for this agent (e.g. eng-head-001)")
    parser.add_argument("--model",        default="openrouter/anthropic/claude-3.5-sonnet", help="Model string")
    parser.add_argument("--system-prompt", default=None,  help="Optional system prompt override")
    parser.add_argument("--budget",       type=float, default=None, help="Budget cap in USD")
    args = parser.parse_args()

    print(f"\nSpawning agent: {args.role} ({args.department}) → session {args.session_id}")
    try:
        agent = spawn_agent(
            role=args.role,
            department=args.department,
            session_id=args.session_id,
            model=args.model,
            system_prompt=args.system_prompt,
            budget=args.budget,
        )
        print(f"\n\033[92m✓ Agent spawned successfully.\033[0m")
        print(json.dumps(agent, indent=2))
    except Exception as e:
        print(f"\n\033[91m✗ Spawn failed: {e}\033[0m")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
