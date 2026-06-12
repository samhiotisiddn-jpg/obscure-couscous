# SDK_PLAN.md — Multi-Agent Orchestration Mesh on OpenHands Software Agent SDK

## 1. Overview

A single-file Python application (`output/agent_mesh.py`) built on the OpenHands
Software Agent SDK. An **Orchestrator** agent delegates to three registered
specialist sub-agents, sharing persistent memory and a local RAG store:

| Agent | Role |
|---|---|
| `orchestrator` | Routes work, tracks tasks, merges results into reports |
| `rss_researcher` | Pulls live RSS feeds, indexes into RAG store, scores items |
| `github_admin` | Administers repos, GitHub Pages, Actions runners via GitHub MCP |
| `monetization_scout` | Studies candidate OSS projects, produces opportunity reports |

## 2. Runtime Configuration

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `LLM_API_KEY` | yes | — | LLM provider key (wrapped in `SecretStr`) |
| `LLM_BASE_MODEL` | no | `openhands/claude-sonnet-4-5-20250929` | Model id |
| `GITHUB_TOKEN` | for admin agent | — | Auth for GitHub MCP server |
| `MESH_DATA_DIR` | no | `./.mesh` | Root for persistence, memory, RAG db |

The program exits with a clear error at startup if `LLM_API_KEY` is unset.

## 3. Core SDK Wiring

```python
llm = LLM(
    model=os.getenv("LLM_BASE_MODEL", "openhands/claude-sonnet-4-5-20250929"),
    api_key=SecretStr(os.environ["LLM_API_KEY"]),
    usage_id="agent-mesh",
)
```

Sub-agents are registered with `register_agent(name, factory_func, description)`
and invoked by the orchestrator through `TaskToolSet` (`Tool(name=TaskToolSet.name)`),
with `tool_concurrency_limit=2` so researcher + scout can run in parallel while
GitHub admin actions stay serialized.

Each agent gets an `AgentContext` with a `Skill` carrying its role prompt.

## 4. Specialist Agents

### 4.1 RSS + RAG Researcher (`rss_researcher`)

**Feeds (configurable list constant, four focus areas):**
- Open-source trending/releases: GitHub trending (via rss proxy), Hacker News, Lobsters
- AI/ML: arXiv cs.AI/cs.LG, AI lab blogs
- Dev-tools & SaaS market: Product Hunt, dev-tool changelogs
- Crypto/web3: protocol blogs, ecosystem digests

**Custom tools** (full Action/Observation/Executor/ToolDefinition pattern):
- `FetchFeedsTool` — pulls all feeds with `feedparser`, dedupes by URL hash,
  inserts into the RAG store.
- `RagQueryTool` — full-text query over the store (SQLite **FTS5**, stdlib-only),
  returns top-k items with scores.
- `ScoreItemTool` — writes relevance/outcome scores back onto items.

**Adaptive source weighting ("reinforcement loop"):** each feed source has a
weight in shared memory. When the scout later marks an item useful/useless, the
source weight is updated (simple bandit-style increment/decay). Ranking =
FTS rank × source weight × recency decay. This is the honest, working version
of "RSS reinforcement learning tunnels" — a feedback-weighted ranking loop, not
a neural RL policy.

### 4.2 GitHub Admin (`github_admin`)

Attached MCP servers via `mcp_config`:

```python
mcp_config = {
  "mcpServers": {
    "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": os.environ["GITHUB_TOKEN"]}},
    "fetch":  {"command": "uvx", "args": ["mcp-server-fetch"]},
  }
}
```

Capabilities: repo settings audits, Pages enablement checks, Actions runner /
workflow inventory, issue & PR hygiene automation. **Guardrail:** the skill
prompt forbids destructive operations (delete repo, force-push) without an
explicit instruction in the delegated task prompt.

### 4.3 Monetization Scout (`monetization_scout`)

Tools: `RagQueryTool` + `MemoryTool` + built-in `TerminalTool`/`FileEditorTool`
(shallow-clones candidates into a sandbox dir to inspect license, activity,
packaging). Output: a markdown opportunity report per candidate —
license compatibility (MIT/Apache vs GPL implications), maintenance signals,
gap analysis, suggested monetization/automation angle. Reports land in
`$MESH_DATA_DIR/reports/` and useful/useless verdicts feed source weights (§4.1).

## 5. Shared Persistent Memory

- **Conversation persistence:** `Conversation(persistence_dir=..., conversation_id=...)`
  — resumable runs, one stable UUID per pipeline stored in `$MESH_DATA_DIR/state.json`.
- **Cross-agent memory:** `MemoryTool` (custom) over `$MESH_DATA_DIR/memory.json` —
  namespaced get/put/list (e.g. `sources.weights`, `scout.verdicts`, `admin.inventory`).
  All agents mount the same tool; this is the "multi memory" layer.

## 6. RAG Store

SQLite database `$MESH_DATA_DIR/rag.db`:
- `items(id, source, url, title, summary, published, score, fetched_at)`
- `items_fts` — FTS5 virtual table over title+summary
No external vector dependency in v1; an optional embeddings upgrade is noted as
future work (the query tool interface won't change).

## 7. CLI & Logging

```
python output/agent_mesh.py run            # full pipeline: research → scout → report
python output/agent_mesh.py research       # researcher only
python output/agent_mesh.py scout          # scout only (uses existing RAG data)
python output/agent_mesh.py admin "task"   # delegated GitHub admin task
python output/agent_mesh.py resume         # resume last conversation
```

`logging` to stderr with timestamps; a conversation callback prints every agent
event (tool calls, observations, LLM messages) so the terminal shows live progress.
Accumulated cost printed at exit via `llm.metrics.accumulated_cost`.

## 8. Pipeline Flow (see flow-diagram.html)

1. CLI parses command, validates env, builds LLM.
2. Orchestrator conversation starts (persistent).
3. Orchestrator delegates `research` task → researcher fetches feeds → indexes → ranks.
4. Orchestrator delegates `scout` task with top-k items → scout studies candidates → writes reports + verdicts.
5. Verdicts update source weights in shared memory (loop back to ranking).
6. Optional: orchestrator delegates publication of a digest (e.g. commit report to a repo) to `github_admin`.
7. Final summary + cost printed.

## 9. Dependencies

`openhands-sdk`, `openhands-tools`, `feedparser`. Everything else is stdlib.
Install: `pip install openhands-sdk openhands-tools feedparser` (pinned in header docstring).

## 10. Risks / Notes

- GitHub MCP server requires Node (`npx`) at runtime; degrade gracefully with a
  clear error if missing.
- Feeds can be slow/unavailable — per-feed timeout and skip-with-warning.
- Single-file constraint means ~600–800 lines; sections are delimited with
  banner comments for navigability.
- No secrets are ever written to memory/RAG files.

## 11. Acceptance Checklist

- [ ] `LLM_API_KEY` missing → friendly startup error
- [ ] `research` populates `rag.db` from at least 2 focus areas
- [ ] `scout` produces ≥1 markdown report and updates source weights
- [ ] `admin` performs a read-only inventory against a scoped repo
- [ ] `resume` continues the prior conversation
- [ ] Terminal shows live event logging; exit prints cost
