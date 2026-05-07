# Handoff — Windows→Ubuntu transition

**Last updated:** 2026-04-22 (end of day, Windows session).
**Read this first** when starting a new Claude Code session on Ubuntu server.

## TL;DR (30 seconds)

You're resuming work on a **multi-agent dev-team orchestrator** built on top of **OpenClaw**. Full architecture is in `ARCHITECTURE.md`. Today we spent the day on Windows hitting three-levels-deep subprocess env issues (`CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`, `PATH` not propagating); confirmed it's a Windows-only problem. **On Ubuntu it should Just Work** — that's why we're migrating.

Current branch: **`feat/devclaw-inspired`** — architecture + scripts committed, tested on Windows up to point of backend spawn failure. Next step on Ubuntu: install + `новый проект test1` + observe.

## What we built today

### Architecture (see `ARCHITECTURE.md`)
- **7 OpenClaw agents**: `main` (user-facing chat facade) + `tl/backend/frontend/tester/devops/reviewer`
- **State = GitHub issue labels** (FSM: `planning → todo:<role> → doing:<role> → review → done / blocked`)
- **Trello mirror** = `gh-to-trello.sh` maps labels to columns
- **Cron-heartbeat dispatcher** = `dispatcher.sh`, runs every 60s, **no LLM calls**. Finds one `todo:<role>` issue, flips label, calls `openclaw agent --to <role>` sequentially (blocking, no burst)
- **Inspired by** DevClaw (https://github.com/laurentenhoor/devclaw) — state-in-issues, heartbeat-without-LLM, retry+circuit-breaker — all adapted to our stack

### Scripts (`scripts/`)
| File | Purpose |
|---|---|
| `install.sh` | First-run: verify prerequisites, onboard openclaw, wire `~/.claude/.credentials.json`, seed workspace defaults |
| `install-roles.sh` | Register 6 worker agents via `openclaw agents add`, populate their workspaces, **install cron** (Linux) or Task Scheduler (Windows) for dispatcher |
| `start-gateway.sh` | Launch openclaw gateway with correct env (OAuth token, Agent Teams flag, preserve_env) |
| `new-project.sh` | Ritual: folder/git/GitHub-repo/Trello-card/root-issue/create-labels/spawn-tl |
| `dispatcher.sh` | Heartbeat (cron/Task Scheduler target). Sequential. No parallel spawn. |
| `gh-to-trello.sh` | Label → Trello column mapper |
| `manage-circuit.sh` | Per-role circuit breaker (5 fails = 1h pause) |
| `sync-agents.sh` | Mirror `agents/*.md` → `~/.openclaw/workspaces/<role>/AGENTS.md` for openclaw UI visibility |

### Role prompts (`agents/`)
- `main-AGENTS.md` — **minimalist facade**. Main triggers `new-project.sh`, answers status queries via `gh issue list` + `audit.ndjson`. NEVER spawns sub-agents directly. NEVER blocks in a turn.
- `tl.md`, `backend.md`, `frontend.md`, `tester.md`, `devops.md`, `reviewer.md` — **each is issue-driven**. Reads issue number from dispatcher's prompt, works in branch `<role>/issue-<N>`, opens PR, flips label `doing:<role> → review`. Uses `gh` CLI + git.

### What failed on Windows (don't panic — Ubuntu fixes)
1. **openclaw spawns `claude` child** → needs OAuth token. On Windows DPAPI keychain isn't visible to child, so we passed token via `CLAUDE_CODE_OAUTH_TOKEN` env. Works, but…
2. This routes claude-cli through **`api.anthropic.com/v1/messages`** (OAuth API lane), which has per-token burst-protection separate from Claude Pro/Max subscription quotas. Parallel spawns trip it.
3. When dispatcher spawns backend/tester/devops, **child-claude's Bash tool can't find `gh` or `GH_TOKEN`** — three-levels-deep env loss. Added fallback detection in dispatcher.sh + spawn scripts, but then `openclaw agent --to backend` from within a Bash tool call inside a claude child also struggles.
4. **On Linux**: child-claude reads `~/.claude/.credentials.json` directly → subscription lane, no burst limit. `gh` is in `/usr/local/bin` (global path). None of this workaround gymnastics needed.

## Branch map

```
main                                   ← Teams-architecture (first working attempt, had inbox-sync bugs)
feat/devclaw-inspired                  ← CURRENT: DevClaw-style GitHub-FSM + dispatcher
archive/teams-flow                     ← backup of Teams architecture
archive/inline-windows-workaround      ← inline coding-agent experiment (too-generic, no specialization)
teams-architecture-v1 (tag)            ← snapshot of teams approach
```

## On Ubuntu: first hour

```bash
# 1) Prerequisites
sudo apt install nodejs git                    # Node 20+
npm i -g @anthropic-ai/claude-code openclaw    # Global tools
claude setup-token                              # OAuth login (browser)

# 2) Clone
git clone https://github.com/Funderburker/orchestrator-project ~/orchestrator-project
cd ~/orchestrator-project
git checkout feat/devclaw-inspired

# 3) Config + secrets
cp .env.example .env && nano .env              # KIE_API_KEY, GITHUB_TOKEN, MC_PASS, etc — fill what applies
cp scripts/config.env.example scripts/config.env  # usually no changes

mkdir -p ~/.openclaw/secrets
echo "ghp_xxx"       > ~/.openclaw/secrets/github_token    # GitHub PAT with `repo` scope
echo "Funderburker"  > ~/.openclaw/secrets/github_owner    # Your GitHub username/org
# Trello (from https://trello.com/power-ups/admin):
echo "key..."   > ~/.openclaw/secrets/trello_key
echo "token..." > ~/.openclaw/secrets/trello_token
echo "board..." > ~/.openclaw/secrets/trello_board_id
# List IDs — get via:
#   source ~/.openclaw/secrets/trello_lists.env-partial
#   curl -sS "https://api.trello.com/1/boards/$BOARD/lists?key=$KEY&token=$TOKEN" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>JSON.parse(d).forEach(l=>console.log(l.id, l.name)))"
# Then compose ~/.openclaw/secrets/trello_lists.env (see DEPLOY_TODO.md)

# 4) Bootstrap
bash scripts/install.sh                     # main workspace + agents/*.md → ~/.claude/agents/
bash scripts/install-roles.sh               # 6 worker agents + cron installed

# 5) OpenClaw CLI auth
openclaw models auth login --provider anthropic --method cli --set-default

# 6) Run
bash scripts/start-gateway.sh               # foreground; move to background/systemd as you prefer

# 7) Open UI
# http://<server-ip>:18789/chat?session=agent:main:work
# Say: "кто ты?"   — should answer as Manager 🎯
# Say: "новый проект ping. GET /ping → {ok:true}. express. минимум тестов + docker."
```

## Expected flow (first test)

1. Main calls `bash scripts/new-project.sh ping "..."` — takes ~30s (git init, github repo, Trello card, root issue, tl spawn)
2. tl decomposes in ≤5 min, creates 2-3 sub-issues with `todo:<role>` labels, sets root issue to `tl-monitoring`
3. Main answers user "запустил ping, tl декомпозировал" — turn ends
4. **Cron** picks up first `todo:<role>` issue within ≤1 min → spawns that worker sequentially
5. Worker commits code, opens PR, flips label `doing → review`
6. Cron picks up next `todo:<role>` while reviewer handles `review` PR
7. When all 3 sub-issues done + tl has seen DONE, tl writes `~/projects/ping/DONE.md`, closes root issue, main reports to user

## What's fixed in latest commits (since Windows live test)

- `dispatcher.sh`: sort issues by number ASC, filter only `open` state, filter to 4 valid worker roles (not `tl-monitoring`), force-flip label on orphan worker, `set_labels` filters empty strings + logs HTTP failures
- `install-roles.sh`: cron on Linux / Task Scheduler on Windows / manual fallback
- `new-project.sh`: creates all FSM labels in the new repo before issuing first `planning` issue
- `agents/*.md`: each role's first action is `gh issue view <N>` + `git checkout -B <role>/issue-<N>` + work + PR + label flip

## Known rough edges to watch for on Ubuntu

- **Trello `comment_card`** adds markdown — check on busy cards formatting
- **`openclaw agent --to <role>` timeout** default 30s — `dispatcher.sh` needs to override if worker does heavy tasks (e.g. `--timeout 600000`). Current code doesn't; add `--timeout 600000` arg.
- **Circuit breaker file** `~/projects/.circuit/<role>.txt` — created on first fail; clean it between projects if you see persistent pauses
- **Audit log** `~/projects/<slug>/logs/audit.ndjson` — check this for every "something's off" moment
- **`openclaw models auth login` requires TTY** — can't script; run interactively once on server setup
- **`gh` prefers `GH_TOKEN` env over `gh auth login`** — our scripts source it; don't fight it
- **MCP config in openclaw.json's `cliBackends.claude-cli.reliability.watchdog.fresh.maxMs`** — raised to 900000 (15 min) from default 600000 to give opus thinking budget; keep or revert based on actual timing
- **Workspace soul-files** (`IDENTITY.md`, `USER.md`, `TOOLS.md`) — seeded from `agents/workspace-defaults/` by `install.sh` **only if absent**; edit freely on server, they won't be overwritten

## Issues to close ASAP on Ubuntu (day 1)

1. Run a full `test1` project through the pipeline — watch for any role that gets stuck
2. Verify `reviewer` auto-merge actually runs (he's the only one that touches `gh pr merge`)
3. Check `~/projects/.circuit/*.txt` after first run — should be all zero fails
4. Monitor `dispatcher.log` for ≥30 min to catch any recurring claim of the same issue (= label not flipping)

## Useful log locations

| What | Where |
|---|---|
| Gateway events | `~/.openclaw/gateway.log` |
| Dispatcher heartbeat | `~/.openclaw/dispatcher.log` |
| Per-project audit | `~/projects/<slug>/logs/audit.ndjson` |
| Per-worker output | `~/projects/<slug>/logs/<role>-<issue>.log` |
| Circuit breaker state | `~/projects/.circuit/<role>.txt` |

## Contact points (humans)

- User: **Funderburker** (Grizz) — Russian-speaking, timezone Moscow, Windows 10 at home + Ubuntu server (now)
- Language of chat: **Russian, informal (на ты)**
- Style: no fluff, direct, doesn't want "отличный вопрос!" etc

## If you (future Claude Code) are confused

1. Read `ARCHITECTURE.md` (source of truth for design)
2. Read `agents/main-AGENTS.md` to understand Manager's role
3. Read `scripts/dispatcher.sh` top-down — it's the brain
4. Check today's git log on `feat/devclaw-inspired` — last 6-8 commits tell the full story of fixes

Good luck on Ubuntu. The hard parts of this arch are settled. Enjoy the reliability win.
