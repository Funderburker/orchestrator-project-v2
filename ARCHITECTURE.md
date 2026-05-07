# Architecture v2 — DevClaw-inspired, bash-driven

This doc is the source of truth. If any .sh / .md diverges, fix the .sh / .md, not this file.

## TL;DR

- **OpenClaw-native multi-agent** — 7 isolated agents (`main + tl + backend + frontend + tester + devops + reviewer`), each with its own workspace
- **State lives in GitHub issues** — labels are the FSM (`planning → todo → doing-<role> → review → done / blocked`)
- **Trello mirrors GitHub** — labels drive Trello list moves via bash
- **Heartbeat dispatcher** = bash cron every 60s, **no LLM tokens**. Scans issues, dispatches work via `openclaw agent --to <role>` (blocking CLI). Sequential, never parallel — so no burst-limit on OAuth lane.
- **Manager never blocks** — all heavy lifting lives in cron-dispatcher or triggered workers. Main only talks to user and reads state files.

## Agents (7)

| ID | Model | Workspace | Role |
|---|---|---|---|
| `main` | sonnet | `~/.openclaw/workspace` | user chat, dispatch trigger, status responder |
| `tl` | opus | `~/.openclaw/workspaces/tl` | break project into GH issues, assign owners, merge PRs |
| `backend` | sonnet | `~/.openclaw/workspaces/backend` | server/ code |
| `frontend` | sonnet | `~/.openclaw/workspaces/frontend` | web/ code |
| `tester` | sonnet | `~/.openclaw/workspaces/tester` | tests/ code |
| `devops` | sonnet | `~/.openclaw/workspaces/devops` | Docker + compose + DEPLOY.md |
| `reviewer` | sonnet | `~/.openclaw/workspaces/reviewer` | review open PRs before merge |

Tier-models (jun/med/sen) — **not in v2**. Add later if cost matters.

## State machine (GitHub issue labels)

```
[new issue created]
      ↓
  planning     ← tl analyzes project, creates sub-issues, assigns
      ↓
  todo:<role>  ← ready for pickup by role
      ↓
  doing:<role> ← role started
      ↓
  review       ← PR opened, reviewer checking
      ↓         ↘
   done         blocked ← escalate to user via main
```

All state transitions go through labels. No other state exists.

### Labels contract

Exactly one `todo:*`, `doing:*`, or `review/done/blocked` label per issue.

| Label | Meaning | Who sets |
|---|---|---|
| `planning` | tl still decomposing | tl |
| `todo:backend` / `todo:frontend` / `todo:tester` / `todo:devops` | ready for the named role | tl |
| `doing:backend` / ... | role picked up, working | dispatcher.sh |
| `review` | PR opened, reviewer should check | role (on finish) |
| `done` | merged to main, done | reviewer (on approve+merge) |
| `blocked` | stuck, needs human | any role |

## Trello mapping

Labels → Trello lists (from `trello_lists.env`):

| GitHub label | Trello list | Env var |
|---|---|---|
| `planning` | Backlog | `TRELLO_LIST_BACKLOG` |
| `todo:backend` / `doing:backend` | Backend | `TRELLO_LIST_BACKEND` |
| `todo:frontend` / `doing:frontend` | Frontend | `TRELLO_LIST_FRONTEND` |
| `todo:tester` / `doing:tester` | Testing | `TRELLO_LIST_TESTING` |
| `todo:devops` / `doing:devops` | Devops | `TRELLO_LIST_DEVOPS` |
| `review` | Testing (closest available) | `TRELLO_LIST_TESTING` |
| `done` | Done | `TRELLO_LIST_DONE` |
| `blocked` | Backlog (+ red comment) | `TRELLO_LIST_BACKLOG` |

Trello is a **mirror**, not a source of truth. If trello goes out of sync, re-derive from GitHub.

## Files per project

```
~/projects/<name>/
├── server/, web/, tests/, etc         # code
├── STATUS.md                          # current stage (updated by workers)
├── DONE.md                            # final summary (by tl at end)
├── DEPLOY.md                          # by devops
├── API.md                             # by backend (first)
├── logs/
│   ├── audit.ndjson                   # append-only event log
│   └── trello-card.txt                # CARD_ID for the project
└── .git/
```

Cross-project:
```
~/projects/
├── .active                            # current project slug (one line)
├── REGISTRY.md                        # catalog of all projects
└── .circuit/                          # circuit breaker state per role
    └── <role>.txt                     # "fail_count=N; paused_until=timestamp"
```

## Components (what we build)

### 1) `scripts/install-roles.sh`
One-shot: `openclaw agents add` for all 7 agents with correct workspaces. Populates `~/.openclaw/workspaces/<role>/AGENTS.md` from `agents/<role>.md` in repo. Installs cron for dispatcher.

### 2) `scripts/dispatcher.sh`
Cron target. Every 60s:
1. Read `~/projects/.active`
2. `gh issue list` on project repo
3. For each `todo:<role>` issue:
   - If circuit closed for role → move label `todo:→doing:`, update Trello, spawn worker sync: `openclaw agent --to <role> --message "work on issue #N"`
   - If worker succeeds → label `review`, Trello move
   - If worker fails → retry ×3, then label `blocked`, increment circuit counter
4. For each `blocked` → pipe to main's inbox (via `openclaw agent --to main`)
5. For each `review` → spawn reviewer if not already doing
6. `audit.ndjson` every action

**Never parallel.** Process issues one at a time.

### 3) `scripts/new-project.sh`
Called by main on "новый проект X". Args: `$1=slug`, `$2="TZ text"`.
1. `mkdir ~/projects/$slug`, git init, `~/projects/.active := $slug`
2. `gh repo create Funderburker/$slug --private`, push
3. `gh issue create --title "Project: $slug" --label planning --body "$TZ"`
4. `curl ... trello/cards → BACKLOG list` (save CARD_ID to logs/trello-card.txt)
5. `openclaw agent --to tl --message "Issue #1 in $slug. Decompose it into sub-issues."` (blocking, up to 5 min)
6. Echo results to stdout for main to relay

### 4) `scripts/gh-to-trello.sh <issue-id> <new-label>`
Maps label to Trello column, calls `move_card` or `comment_card`. Used by dispatcher whenever it flips a label.

### 5) `scripts/manage-circuit.sh <role> <action>` where action in `fail|succeed|check`
Tracks consecutive failures per role in `~/projects/.circuit/<role>.txt`. After 5 consecutive fails → paused 1h. Dispatcher checks before spawning.

### 6) New `agents/main-AGENTS.md` (minimalist)
Main's role is drastically smaller now:
- Accept "новый проект X" → run `scripts/new-project.sh`, echo summary to user, END TURN
- Accept "что с X / статус" → `gh issue list` on project, read audit.ndjson tail, summarize
- Accept "в X добавь Y" → `gh issue create --title Y --label planning`, `openclaw agent --to tl --message "new issue $N, decompose"`
- Accept "X заблокирован" from dispatcher → forward to user
- **Never** block waiting for a worker. Never spawn teammates directly. Dispatcher does everything.

### 7) Per-role `agents/<role>.md`
Each role's workspace gets its own AGENTS.md telling it:
- Pick up issue by `--label todo:<role>` then pull via arg
- Work in git branch `<role>/issue-N`
- When done → PR + label `review`
- If blocked → comment + label `blocked`

## Windows viability

Sequential, blocking CLI calls. Each `openclaw agent --to` = one subprocess, one `/v1/messages` call. Spaced by 60s cron tick + bash processing. **No parallel burst → no OAuth rate-limit trip.**

Watchdog already raised to 10 min fresh / 10 min resume — enough for any single role's turn.

If Windows still tripsomething, fallback is `OPENCLAW_BIND=loopback` + sandbox rules from sandbox docs.

## Open questions we'll resolve during local test

- Does `openclaw agent --to X --message ...` return the agent's text reply in stdout, so dispatcher can parse it? (read-only, should be `--json` flag)
- How to reliably capture "task_finished" from a worker's turn? Rely on label change via `gh issue edit` (worker does it explicitly), fallback: pattern-match "DONE" in stdout.
- Can `reviewer` auto-approve PRs, or always pause for human? Start with human-pause.

## Deferred (not v2)

- Tier-based models (jun/med/sen) — later
- Multi-workspace git branch per role — start with single branch, direct commits
- Parallel worker dispatch — one-by-one until stable
- Hooks-based label sync — use bash polling first
