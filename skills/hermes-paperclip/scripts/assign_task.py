#!/usr/bin/env python3
"""
assign_task.py — Assign a task to a Hermes agent via Paperclip.

Routes by session ID (specific agent) or by role (Paperclip picks the right worker).

Usage:
  python scripts/assign_task.py --agent eng-head-001 --task "Review open PRs"
  python scripts/assign_task.py --role "Head of Marketing" --task "Write launch email" --budget 5.00
  python scripts/assign_task.py --agent eng-head-001 --task "Escalate: need architecture decision" --escalate
"""

import argparse, os, json
from pathlib import Path
from dotenv import load_dotenv
import httpx

load_dotenv(Path(__file__).parent.parent / ".env")

PAPERCLIP_API_URL = os.getenv("PAPERCLIP_API_URL", "http://localhost:3000")
PAPERCLIP_API_KEY = os.getenv("PAPERCLIP_API_KEY", "")


def assign_task(
    task: str,
    agent_id: str | None = None,
    role: str | None = None,
    from_agent: str | None = None,
    priority: str = "normal",
    due: str | None = None,
    budget: float | None = None,
    escalate: bool = False,
) -> dict:
    if not agent_id and not role:
        raise ValueError("Provide either --agent <session-id> or --role <role name>")

    payload: dict = {
        "task": task,
        "priority": priority,
        "escalate": escalate,
    }
    if agent_id:
        payload["agentId"] = agent_id
    if role:
        payload["role"] = role
    if from_agent:
        payload["delegatedBy"] = from_agent
    if due:
        payload["dueDate"] = due
    if budget is not None:
        payload["budgetUsd"] = budget

    endpoint = f"{PAPERCLIP_API_URL}/api/tasks"
    r = httpx.post(
        endpoint,
        json=payload,
        headers={"Authorization": f"Bearer {PAPERCLIP_API_KEY}"},
        timeout=10,
    )
    r.raise_for_status()
    return r.json()


def main():
    parser = argparse.ArgumentParser(description="Assign a task to an agent")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--agent",  help="Target agent session ID")
    group.add_argument("--role",   help="Target role (Paperclip resolves to agent)")

    parser.add_argument("--task",        required=True, help="Task description")
    parser.add_argument("--from-agent",  default=None,  help="Delegating agent session ID")
    parser.add_argument("--priority",    default="normal", choices=["low", "normal", "high", "urgent"])
    parser.add_argument("--due",         default=None,  help="Due date (YYYY-MM-DD)")
    parser.add_argument("--budget",      type=float, default=None, help="USD budget cap")
    parser.add_argument("--escalate",    action="store_true", help="Flag for human board review")
    args = parser.parse_args()

    target = f"agent:{args.agent}" if args.agent else f"role:{args.role}"
    print(f"\nAssigning task → {target}")
    print(f"  Task: {args.task[:80]}{'…' if len(args.task) > 80 else ''}")
    if args.escalate:
        print("  \033[93m⚠ Escalation flag set — will appear in board queue\033[0m")

    try:
        result = assign_task(
            task=args.task,
            agent_id=args.agent,
            role=args.role,
            from_agent=args.from_agent,
            priority=args.priority,
            due=args.due,
            budget=args.budget,
            escalate=args.escalate,
        )
        print(f"\n\033[92m✓ Task queued. Task ID: {result.get('id', 'unknown')}\033[0m")
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(f"\n\033[91m✗ Assignment failed: {e}\033[0m")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
