# ADR-001: AI Company Stack — Hermes Agent + Paperclip

**Status:** Proposed  
**Date:** 2026-04-22  
**Deciders:** Lao (Owner / Board of Directors)

---

## Context

The goal is to build a fully autonomous AI company — one where AI agents handle roles (CEO, department heads, individual contributors), coordinate on goals, manage budgets, and self-improve over time — with a human operator acting as the board of directors rather than a day-to-day manager.

Two open-source tools are being combined to achieve this:

- **[Paperclip](https://github.com/paperclipai/paperclip)** — the control plane. It models a company with an org chart, goals, budgets, and governance. You set strategy; agents execute it.
- **[Hermes Agent](https://github.com/nousresearch/hermes-agent)** — the agent runtime. Self-improving, multi-platform, multi-model AI agents with persistent memory, 80+ skills, MCP tool support, and a built-in learning loop.
- **[hermes-paperclip-adapter](https://github.com/NousResearch/hermes-paperclip-adapter)** — the official bridge. Runs Hermes Agent as a managed Paperclip employee, giving each agent session persistence, unified skill management, and heartbeat-driven execution.

---

## Decision

Deploy Paperclip as the company operating system and populate it with Hermes Agent workers via the official adapter. The human owner acts as board — approving agent hires, reviewing CEO strategy, setting budgets — while the AI layer handles all execution autonomously.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    HUMAN CONTROL PLANE                  │
│              (Board of Directors — You)                 │
│         Paperclip Web UI  ·  Budget Approvals           │
│         Org Chart Review  ·  Strategy Sign-off          │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│                  PAPERCLIP CORE                         │
│                                                         │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │  Org Chart  │  │   Goals &    │  │    Budget &   │  │
│  │  (CEO +     │  │   Strategy   │  │   Governance  │  │
│  │  Depts)     │  │   Engine     │  │   Controls    │  │
│  └─────────────┘  └──────────────┘  └───────────────┘  │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │           Agent Orchestration Layer             │    │
│  │  Task queues · Heartbeats · Skill registry      │    │
│  └─────────────────────────────────────────────────┘    │
└──────────────────────────┬──────────────────────────────┘
                           │  hermes-paperclip-adapter
┌──────────────────────────▼──────────────────────────────┐
│                  HERMES AGENT WORKERS                   │
│                                                         │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐           │
│  │  CEO      │  │  Dept     │  │  IC       │           │
│  │  Agent    │  │  Head     │  │  Agents   │           │
│  │  (Hermes) │  │  Agents   │  │  (N)      │           │
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘           │
│        │              │              │                  │
│  ┌─────▼──────────────▼──────────────▼──────────────┐   │
│  │               Hermes Runtime                     │   │
│  │  Persistent memory · Session resume (--resume)   │   │
│  │  Self-improving skills · Context compression     │   │
│  │  ThreadPoolExecutor (8 parallel workers)         │   │
│  └──────────────────────┬────────────────────────────┘   │
└─────────────────────────┼───────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────┐
│                    TOOL LAYER (MCP)                     │
│                                                         │
│  Web search · Code execution · File I/O · APIs         │
│  Notion · GitHub · Slack · Email · Calendar            │
│  Custom MCP servers (add any external service)         │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────┐
│                    MODEL LAYER                          │
│                                                         │
│  Nous Portal · OpenRouter (200+ models) · OpenAI       │
│  NVIDIA NIM · Local models (Ollama)                    │
│  Switchable per-agent via: hermes model <name>         │
└─────────────────────────────────────────────────────────┘
```

---

## Layer-by-Layer Breakdown

### 1. Paperclip — Company OS

Paperclip is the single source of truth for company structure and governance. It provides:

- **Org chart** — define roles (CEO, CTO, Head of Marketing, etc.), each mapped to a Hermes Agent instance
- **Goal system** — cascading OKRs from board → CEO → departments → ICs
- **Budget controls** — per-agent spending limits; agents can't exceed allocation without your approval
- **Hire approval** — agents cannot spawn new agents without board sign-off
- **Pre-built templates** — 16 company types (dev shop, research lab, security auditor, content studio, etc.) with 440+ pre-defined agent roles and 500+ skills ready to load

### 2. hermes-paperclip-adapter — The Bridge

The official NousResearch adapter (`github.com/NousResearch/hermes-paperclip-adapter`) is the glue between the two systems:

- Spawns Hermes Agent in **single-query mode** (`-q`) per Paperclip task heartbeat
- Uses Hermes `--resume` flag so each agent picks up its memory and session state between heartbeats
- Exposes a **unified skill view** — merges Paperclip-managed skills (togglable from UI) with Hermes-native skills (`~/.hermes/skills/`)
- `sessionCodec` validates and migrates session state across versions, so agents don't lose context on upgrades

### 3. Hermes Agent — Worker Runtime

Each Paperclip "employee" is a Hermes Agent instance with:

- **Persistent memory** — agent-curated memory with periodic nudges; builds a model of its role and relationships over time
- **Self-improving skills** — after complex tasks, the agent creates new skills; skills improve during use
- **80+ native skills** — code execution, web research, file manipulation, communication, etc.
- **MCP client** — discovers and calls external tools (Notion, GitHub, Slack, etc.) at startup
- **Model flexibility** — each agent can use a different model; switch with `hermes model <name>`, no code change required

### 4. MCP Tool Layer

Both Hermes and Paperclip support MCP. This means you can extend any agent's capabilities by pointing it at an MCP server:

| Tool | What it enables |
|------|----------------|
| GitHub MCP | Code agent can open PRs, review issues, push commits |
| Notion MCP | Agents can read/write docs, databases, project pages |
| Slack MCP | Agents report status, escalate blockers, notify humans |
| Brave/Tavily | Web research for any agent |
| Custom MCP | Wrap any internal API as a tool in minutes |

---

## Options Considered

### Option A: Paperclip + Hermes via hermes-paperclip-adapter (Recommended)

| Dimension | Assessment |
|-----------|------------|
| Complexity | Medium — two tools with one official bridge |
| Cost | Low (self-hosted, BYOM — bring your own model) |
| Scalability | High — Paperclip handles N agents; Hermes runs 8 parallel workers per instance |
| Self-improvement | Yes — Hermes learns from each task; skills evolve automatically |
| Human control | High — Paperclip's governance layer keeps you in the loop |

**Pros:** Official integration; session persistence across tasks; unified skill registry; model-agnostic; MIT licensed both tools  
**Cons:** Two systems to maintain; adapter adds a thin dependency; Paperclip is relatively new (launched March 2026)

### Option B: Paperclip only with generic LLM agents

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low |
| Cost | Medium (depends on model API costs) |
| Scalability | High |
| Self-improvement | None — agents don't learn or build skills |
| Human control | High |

**Pros:** Simpler stack  
**Cons:** No memory, no self-improvement, skills must be manually authored

### Option C: Hermes Agent only (no Paperclip)

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low |
| Cost | Low |
| Scalability | Medium — no org chart or multi-agent coordination built-in |
| Self-improvement | Yes |
| Human control | Low — no governance layer |

**Pros:** Simpler; great personal assistant or small team use  
**Cons:** No company-level orchestration, budgets, or approval workflows

---

## Trade-off Analysis

The core trade-off is **control vs. capability**. Paperclip alone gives you governance without intelligence growth. Hermes alone gives you a smart, self-improving agent without company-scale coordination. The adapter bridges them: Paperclip owns the what and who, Hermes owns the how and memory.

The main risk is the adapter's maturity — it's a relatively new project. Mitigation: start with a single department or pre-built company template, validate the adapter's session persistence, then scale.

---

## Consequences

**What becomes easier:**
- Scaling from 1 to N agents without changing your oversight model
- Agents that improve at their jobs the longer they run
- Model cost optimization — route cheap tasks to smaller models, complex tasks to stronger ones
- Adding new tools to any agent via MCP without code changes

**What becomes harder:**
- Debugging multi-agent workflows (which agent did what, when)
- Keeping Paperclip + Hermes versions in sync after upgrades
- Estimating real compute/API costs before agents start running at scale

**What to revisit:**
- Deployment model (local → cloud VPS) once agent workload is understood
- Model selection per role (cost vs. capability per department)
- Whether the self-evolution framework (`hermes-agent-self-evolution`, ICLR 2026 Oral) is worth adding for DSPy-based skill optimization

---

## Action Items

1. [ ] Install Paperclip locally: `npx @paperclipai/server` and complete setup wizard
2. [ ] Install Hermes Agent: follow `hermes-agent` README (Node + Python deps)
3. [ ] Install hermes-paperclip-adapter and connect it to your Paperclip instance
4. [ ] Choose a pre-built company template to start (e.g. dev shop, research lab, or content studio)
5. [ ] Configure at least one Hermes worker with a model (start with OpenRouter for flexibility)
6. [ ] Add 1-2 MCP servers to extend agent tooling (e.g. GitHub + web search)
7. [ ] Run a first task end-to-end and inspect the Paperclip task log + Hermes session memory
8. [ ] Decide on deployment (local vs. VPS) after validating the local setup
9. [ ] Review `hermes-agent-self-evolution` for skill auto-optimization (optional, advanced)

---

## References

- [Hermes Agent GitHub](https://github.com/nousresearch/hermes-agent)
- [Hermes Agent Docs](https://hermes-agent.nousresearch.com/docs/)
- [Paperclip GitHub](https://github.com/paperclipai/paperclip)
- [hermes-paperclip-adapter](https://github.com/NousResearch/hermes-paperclip-adapter)
- [Paperclip MCP Server](https://github.com/Wizarck/paperclip-mcp)
- [Hermes Self-Evolution (ICLR 2026)](https://github.com/NousResearch/hermes-agent-self-evolution)
