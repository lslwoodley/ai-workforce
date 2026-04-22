# Agent Workspace

This directory is where Hermes agents commit their work. It is part of the repo so all agent output is version-controlled, auditable, and human-reviewable before it affects anything outside the sandbox.

## Structure

```
workspace/
└── agents/
    └── <session-id>/     ← One directory per agent (matches their Hermes session ID)
        ├── research/     ← Research reports, market analysis, web findings
        ├── code/         ← Code the agent wrote or modified
        ├── plans/        ← Plans, proposals, strategies the agent drafted
        └── logs/         ← Task logs and agent reasoning traces
```

## How agents commit here

When a Hermes agent completes work it wants to persist, it:

1. Writes its output to `/workspace/agents/<session-id>/<category>/`
2. Runs a git commit attributed to itself: `git commit -m "agent(<session-id>): <description>"`
3. Pushes to a branch named `agent/<session-id>/<topic>`
4. The `agent-workspace.yml` GitHub Actions workflow auto-opens a pull request for human review

Agents **cannot merge their own PRs** — that requires a human.

## Reviewing agent work

```bash
# See all open agent PRs
gh pr list --label agent-work

# Review a specific agent's branch
git checkout agent/ceo-001/market-research
```

## Git identity

All agent commits are signed with:
- **Author:** `ai-workforce-bot <agents@localhost>` (configurable via `AGENT_GIT_USER` / `AGENT_GIT_EMAIL`)
- **Committer:** same

This makes it easy to filter: `git log --author="ai-workforce-bot"`
