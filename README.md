# Agent Orchestration Portfolio — Claude Code Agent SDK Application

**D. Michael Piscitelli** | Chicago, IL | hello@herakles.dev | [herakles.dev](https://herakles.dev)

200 projects. 90 containers. 95 AI agents. 4.7GB of `.claude/` configuration. All built through Claude Code on a self-hosted Linux server. This repo curates the work most relevant to the Agent SDK role.

---

## Featured Projects

### V11 Agent Orchestration Framework
**The direct parallel to the Agent SDK.** Eleven iterations of a spec-driven orchestration framework, each adapting as Claude Code shipped native features (Tasks, Agent Teams, tool policies).

- 95 agents across 8 team formations
- 12 enforcement hooks at PreToolUse/PostToolUse/Stop boundaries
- Typed artifact handoffs between agents with trace IDs
- Adversarial verification (agents challenge each other's work)
- 5-level autonomy system with auto-escalation/de-escalation
- Semantic memory with hybrid vector + BM25 search
- 78 agent definitions with YAML frontmatter (execution mode, formation roles, workflow graphs)
- Custom CLI for programmatic agent lifecycle management
- Web app for visual agent version control

**Architecture docs:** [herakles-agentic-architecture](https://github.com/herakles-dev/herakles-agentic-architecture)
**V11 showcase:** [claude-orchestrator-showcase](https://github.com/herakles-dev/claude-orchestrator-showcase)

---

### Nova Forge — Model-Portable Agent Framework
Production framework abstracting across three LLM providers (Anthropic, AWS Bedrock, OpenRouter) with a single interface. Provider adapters, structured output parsing, failover logic. The SDK design challenge: abstractions that don't leak provider details.

**18,000+ LOC | 723 tests | 3 providers**

**Source:** [nova-forge](https://github.com/herakles-dev/nova-forge)

---

### Zeus Terminal — Claude Code in the Browser
Browser-based terminal with WebGL rendering, tmux persistence, WebSocket multiplexing. Built because I needed to direct the platform from any device. Not a toy emulator — handles full Claude Code throughput.

**380 tests | TypeScript + Node.js | Docker deployed**

**Source:** [herakles-terminal](https://github.com/herakles-dev/herakles-terminal)
**Platform showcase:** [iolaus-zeus-showcase](https://github.com/herakles-dev/iolaus-zeus-showcase)

---

### Claude History Explorer — Session Analytics
Custom analytics dashboard indexing every Claude Code session. 2GB of conversation data — session duration, tool call frequency, token consumption. A dataset on how a power user interacts with Claude Code at scale.

**Next.js 15 | 21,000+ source files**

---

### Co-Processor Bridges
Two CLI tools that extend Claude Code's capabilities by routing work to other models:

- **[claude-gemini](https://github.com/herakles-dev/claude-gemini)** — Delegates heavy reasoning to Gemini API. Auto-routing, deep thinking tiers, SHA256 caching, daily budget enforcement. Python.
- **[claude-pi](https://github.com/herakles-dev/claude-pi)** — Delegates deterministic coding tasks to Pi agent. YOLO firewall, stall detection, parallel burst mode, YAML pipelines. TypeScript.

---

## Breadth of Work

Every project below was built through Claude Code.

| Project | What It Is | Link |
|---------|-----------|------|
| **Athenaeum** | Self-hosted semantic library — upload docs, search by meaning, chat with AI that cites sources. FastAPI + pgvector + Next.js + MCP. | [Source](https://github.com/herakles-dev/athenaeum) |
| **Claude Trader Pro** | AI crypto trading — multi-timeframe analysis, confidence scoring, auto-execution, OctoBot integration. | [Source](https://github.com/herakles-dev/claude-trader-pro) |
| **3-Body Problem** | GPU-accelerated N-body simulation — NVIDIA Warp, real-time 3D, audio-reactive, chaos analysis. | [Source](https://github.com/herakles-dev/3-body-problem) |
| **TOS Analyzer** | AI-powered Terms of Service analyzer — risk scoring, dark pattern detection. Gemini 2.5 Pro Vision. | [Source](https://github.com/herakles-dev/tos-analyzer) |
| **Manifold Visualizer** | WebGPU mathematical surface renderer — 25+ manifold types, WGSL compute shaders, audio-reactive. | [Source](https://github.com/herakles-dev/manifold-visualizer) |
| **Observability Stack** | Production monitoring — Grafana, Prometheus, Loki, Promtail, OpenTelemetry, Fail2ban. | [Source](https://github.com/herakles-dev/observability-showcase) |
| **CK Reynolds Tax** | Client SaaS platform — 55 API routes, 2FA, IRS compliant. Next.js, Supabase, Square. | [Showcase](https://github.com/herakles-dev/ckreynolds-tax-showcase) |
| **Portfolio Showcase** | Full platform overview — 33 services, 77 containers, SSO, observability. | [Source](https://github.com/herakles-dev/portfolio-showcase) |
| **MCP Inspector** | Visual testing tool for Model Context Protocol servers. | [Source](https://github.com/herakles-dev/inspector) |

---

## Platform Stats

| Metric | Count |
|--------|-------|
| Projects built through Claude Code | 200 |
| Running Docker containers | 90 |
| Registered services | 26 |
| Active AI agents | 69 (95 total) |
| Slash-command skills | 52 |
| Enforcement hooks | 12 |
| SSL-enabled domains | 44+ |
| GitHub repositories | 33 (22 public) |
| Claude Code hours | 1,600+ verified |
| Claude Code sessions | 2,000+ |

---

## Code Samples

Selected source files from the platform, browsable directly in this repo:

| File | What It Shows |
|------|---------------|
| [`samples/hooks/guard-write-gates.sh`](samples/hooks/guard-write-gates.sh) | PreToolUse — file ownership via formation registry, schema validation, task-state gating, plan-mode tracking |
| [`samples/hooks/track-autonomy.sh`](samples/hooks/track-autonomy.sh) | PostToolUse — 5-level trust escalation (A0→A4), JSONL audit with diff hashing, flock-safe writes, log rotation |
| [`samples/hooks/sync-tasks.sh`](samples/hooks/sync-tasks.sh) | PostToolUse — task lifecycle state machine, artifact persistence, formation heartbeats, background memory indexing |
| [`samples/hooks/enforce-test-coverage.sh`](samples/hooks/enforce-test-coverage.sh) | PreToolUse — deployment gate blocking below threshold, auto-detects pytest/jest/go/cargo/bun, cached detection |
| [`samples/agents/agent-architect.md`](samples/agents/agent-architect.md) | V11 agent definition — YAML frontmatter (formation_role, execution mode, workflow graph), 2-checkpoint protocol, artifact handoff |
| [`samples/agents/security-engineer.md`](samples/agents/security-engineer.md) | Domain agent — STRIDE threat modeling, OWASP Top 10 assessment, formation roles (security-review, feature-impl) |
| [`samples/agents/meta-agent.md`](samples/agents/meta-agent.md) | Self-referential agent — manages creation, versioning, deployment of all other agents in the ecosystem |
| [`samples/oss-contribution-engine/validate.sh`](samples/oss-contribution-engine/validate.sh) | 8-gate pre-flight validation for open source PRs — competing PRs, claims, labels, freshness, CLA, comprehension |
| [`samples/oss-contribution-engine/comprehend.sh`](samples/oss-contribution-engine/comprehend.sh) | 4-tier repo comprehension — inline read → CONTRIBUTING.md scan → deep clone analysis → Atheneum RAG |
| [`samples/oss-contribution-engine/pre-submit.sh`](samples/oss-contribution-engine/pre-submit.sh) | 10-check compliance gate — forbidden patterns, DCO, secrets scan, test evidence, AI disclosure rules |
| [`samples/oss-contribution-engine/scoring.yml`](samples/oss-contribution-engine/scoring.yml) | Weighted issue scoring algorithm — stars, reactions, label quality, solvability, credibility, freshness |

Production hooks (5,700+ executions). OSS engine has 4 open PRs to modelcontextprotocol and kubeflow.
Architecture methodology: [herakles-agentic-architecture](https://github.com/herakles-dev/herakles-agentic-architecture).

---

## Server

Intel i7-8700 (6C/12T) | 128GB RAM | 906GB storage | Debian Linux | Purchased at auction. No cloud provider, no team, no VC. Just a machine and Claude Code.

---

*Built with Claude Code. All of it.*
