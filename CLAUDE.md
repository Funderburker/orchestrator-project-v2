# Project context for Claude Code

You are working on a **multi-agent dev-team orchestrator** built on top of OpenClaw. This repo contains:

- **Architecture** → see `ARCHITECTURE.md` (source of truth)
- **Today's handoff** → **open `HANDOFF.md` FIRST** if this is a fresh session after Windows→Ubuntu migration
- **Setup** → `README.md`, `DEPLOY_TODO.md`, `scripts/install.sh`

## Quick orientation

- **Current branch:** `feat/devclaw-inspired` (primary working arch)
- **Archive branches:** `archive/teams-flow` (old), `archive/inline-windows-workaround` (experiment)
- **User:** Funderburker (grizz), Russian-speaking, на ты
- **Language of chat:** Russian, concise, no filler like "отличный вопрос"

## Conventions

- **Git commits:** Conventional commits (`feat:`, `fix:`, `docs:`, `chore:`). Always include `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
- **Scripts run:** always `bash scripts/<name>.sh`, never direct interpreter
- **Secrets:** in `~/.openclaw/secrets/` (never in git) + `~/.claude/.credentials.json` (OAuth token)
- **On Ubuntu:** `gh` in `/usr/local/bin`, use `export GH_TOKEN=$(cat ~/.openclaw/secrets/github_token)` if `gh auth login` doesn't work (token scope issues)

## If you are mid-Windows→Ubuntu transition

Read `HANDOFF.md` in full — it has everything the previous (Windows) session learned, including:
- What works / what failed on Windows and why
- Exact steps for first hour on Ubuntu
- Branch map & commit log context
- Known rough edges to watch

## When in doubt

- Design question → `ARCHITECTURE.md`
- How-to → `README.md` or `DEPLOY_TODO.md`
- Why did we pick X → git log on `feat/devclaw-inspired`, look at commit messages
- User's personality / preferences → `HANDOFF.md` "Contact points"
