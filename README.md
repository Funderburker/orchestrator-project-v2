# Manager Team Orchestrator

Multi-agent dev team, chat-driven via OpenClaw panel, powered by Claude Code Agent Teams.

- **Manager 🎯** — main dispatcher; you talk to him in the chat
- **tl 🛠️** — tech lead; decomposes projects, assigns tasks, merges branches, moves Trello cards
- **backend / frontend / tester / devops** — workers, each in their role
- All teammates coordinate via inbox + `SendMessage`, `TaskCreate/Update`

Manager runs the ritual for every project you ask for (`новый проект X`):
1. `~/projects/X/` + git init + directory structure
2. Private GitHub repo under `$GITHUB_OWNER/X`
3. Trello card in `BACKLOG`
4. `.active` + row in `~/projects/REGISTRY.md`
5. `TeamCreate` + spawn 5 teammates
6. `CronCreate` — every 3 min: read inbox, update STATUS, escalate blockers
7. Reports back in chat

## Quick start

### On a fresh machine (Ubuntu or Windows Git Bash)

```bash
# 1. Install prerequisites
#    - Node.js >= 20
#    - npm i -g @anthropic-ai/claude-code openclaw
#    - claude setup-token      # OAuth login via browser

# 2. Clone
git clone https://github.com/<owner>/orchestrator-project
cd orchestrator-project

# 3. Configure
cp .env.example .env                          # fill in tokens (GitHub, Trello, etc.)
cp scripts/config.env.example scripts/config.env  # optional: override paths

# 4. Prepare secrets dir
mkdir -p ~/.openclaw/secrets
echo "<your-ghp-token>"    > ~/.openclaw/secrets/github_token
echo "<your-github-owner>" > ~/.openclaw/secrets/github_owner
# + trello_key, trello_token, trello_board_id, trello_lists.env (see DEPLOY_TODO.md)

# 5. Bootstrap
bash scripts/install.sh
# This wires ~/.claude/agents, ~/.openclaw/workspace, auth profiles, settings.json.

# 6. Finish one-time auth (TTY required)
openclaw models auth login --provider anthropic --method cli --set-default

# 7. Run
bash scripts/start-gateway.sh
# open http://localhost:18789/?session=agent:main:work
```

### Everyday

- Open chat at `http://<host>:18789/?session=agent:main:<any-name>`
- Say: `новый проект X. задача: ...`
- Watch the manager spawn the team, answer his escalations (stack choice, etc.)
- Project ships to `~/projects/X/`, GitHub, Trello moves to DONE

## Layout

```
orchestrator-project/
├── agents/
│   ├── main-AGENTS.md              # manager workflow (installed to ~/.openclaw/workspace/AGENTS.md)
│   ├── tl.md backend.md frontend.md tester.md devops.md
│   │                                # subagent defs (installed to ~/.claude/agents/)
│   └── workspace-defaults/
│       └── IDENTITY USER TOOLS SOUL HEARTBEAT
│                                    # soul files; seeded to ~/.openclaw/workspace/ if absent
├── scripts/
│   ├── install.sh                   # one-shot setup on fresh machine
│   ├── start-gateway.sh             # launch openclaw gateway with all env
│   ├── sync-agents.sh               # sync agents <-> workspaces after edits
│   └── config.env.example           # per-host overrides template
├── proxy/                           # optional Kie.ai fallback FastAPI proxy
├── .env.example                     # tokens template
├── DEPLOY_TODO.md                   # full migration checklist
└── SETUP_UBUNTU.md                  # legacy Ubuntu notes (reference only)
```

## What's where at runtime

| Path | What | Committed? |
|---|---|---|
| `~/.claude/agents/*.md` | Subagent defs (source of truth for roles) | no (per-machine; seeded by install.sh from `agents/`) |
| `~/.claude/.credentials.json` | OAuth token from `claude setup-token` | no |
| `~/.claude/settings.json` | Claude Code env + permissions | no (templated by install.sh) |
| `~/.openclaw/openclaw.json` | OpenClaw config | no |
| `~/.openclaw/workspace/*.md` | Manager soul files | no (seeded) |
| `~/.openclaw/workspaces/<role>/` | Mirror of subagent defs (openclaw UI visibility) | no (populated by `sync-agents.sh`) |
| `~/.openclaw/secrets/` | GitHub/Trello/etc tokens | no — **never commit** |
| `~/.openclaw/agents/main/` | Runtime auth-profiles + sessions | no (generated) |
| `~/.claude/teams/<project>/` | Agent Teams runtime state | no (ephemeral) |
| `~/.claude/tasks/<project>/` | Task queue per project | no (ephemeral) |
| `~/projects/<project>/` | Built projects (code + Docker + DEPLOY.md) | each own git repo, pushed to GitHub |

## Why Agent Teams

See `DEPLOY_TODO.md` section "What's inside" and commit history for the full story.
TL;DR: after trying Mission Control, Claude Code sub-agent inline, and OpenClaw-native,
Agent Teams won because it provides built-in inbox, `TaskCreate`, `SendMessage`, cron,
and parallel spawn — the infrastructure we'd otherwise build by hand.

## Known rough edges

- `rate_limit_error` on parallel spawn of 5 teammates → Anthropic throttles even on Max.
  Mitigation on the roadmap: sequential spawn instead of parallel.
- `team-lead` (system id of lead) vs `techlead` — naming collision. Fixed by renaming
  teammate to `tl` and using full-form IDs (`tl@<project>`) in all SendMessage calls.
- Manager doesn't auto-read inbox between turns — cron-task now includes an explicit
  inbox scan every 3 minutes.
- Windows `symlink` requires admin → we use `cp` via `sync-agents.sh` to mirror defs.

## License

Private repo; internal use.
