#!/usr/bin/env bash
# install.sh — one-shot setup of Manager team orchestrator on a fresh machine.
#
# Prerequisites (DO THESE BY HAND FIRST):
#   1) Install Node.js >= 20
#   2) npm i -g @anthropic-ai/claude-code openclaw
#   3) claude setup-token         ← opens browser, authorizes, writes DPAPI/keychain
#   4) git clone this repo
#   5) cp .env.example .env       ← fill in YOUR tokens (GITHUB_TOKEN, KIE_API_KEY, etc.)
#   6) cp scripts/config.env.example scripts/config.env    ← fill in GITHUB_OWNER and any overrides
#   7) Create ~/.openclaw/secrets/ with your per-machine secrets:
#      - github_token (your ghp_*)
#      - github_owner (your GitHub username/org)
#      - trello_key, trello_token, trello_board_id
#      - trello_lists.env (TRELLO_LIST_BACKLOG/BACKEND/FRONTEND/TESTING/DEVOPS/DONE)
#
# Then run this script. It will:
#   - Verify tools, read config.env
#   - Bootstrap ~/.openclaw/ via `openclaw onboard` if needed
#   - Copy agents defs to ~/.claude/agents/ and mirror to ~/.openclaw/workspaces/
#   - Copy main workspace (AGENTS/IDENTITY/USER/TOOLS/SOUL) to ~/.openclaw/workspace/
#   - Wire ~/.claude/.credentials.json from the OAuth token (reading it from keychain if possible,
#     or asking user to paste)
#   - Wire anthropic:claude-cli auth profile in ~/.openclaw/agents/main/agent/auth-profiles.json
#   - Set ~/.claude/settings.json with CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
#
# After install.sh: run `bash scripts/start-gateway.sh` and point browser at http://localhost:18789/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# -------- 1) Load per-host config --------
CONFIG_FILE="$SCRIPT_DIR/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: $CONFIG_FILE not found." >&2
  echo "  cp $SCRIPT_DIR/config.env.example $CONFIG_FILE  and fill in your values." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${AGENTS_DIR:=$HOME/.claude/agents}"
: "${WORKSPACE_DIR:=$HOME/.openclaw/workspace}"
: "${WORKSPACES_DIR:=$HOME/.openclaw/workspaces}"
: "${SECRETS_DIR:=$HOME/.openclaw/secrets}"
: "${PROJECTS_DIR:=$HOME/projects}"

# -------- 2) Verify tools --------
for bin in node openclaw claude; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: $bin not found in PATH. Install it first (see prerequisites in this script)." >&2
    exit 1
  fi
done

# -------- 3) openclaw onboard (if no config) --------
if [ ! -f "$HOME/.openclaw/openclaw.json" ]; then
  echo "[install] openclaw not onboarded. Running onboard..."
  openclaw onboard --non-interactive --accept-risk --auth-choice skip
fi

# -------- 4) Ensure ~/.claude/.credentials.json exists --------
CREDS="$HOME/.claude/.credentials.json"
if [ ! -f "$CREDS" ]; then
  echo "[install] $CREDS not found."
  echo "  If you ran 'claude setup-token' on this machine, the token lives in the OS keychain."
  echo "  Extract it with: claude setup-token --print    (or re-run 'claude setup-token' and paste here)"
  read -r -p "  Paste OAuth token (sk-ant-oat01-...): " TOKEN
  if [ -z "$TOKEN" ]; then
    echo "ERROR: no token provided. Aborting." >&2
    exit 1
  fi
  # ~1 year expiry; Claude CLI renews via its own keychain flow if available
  EXPIRES_AT=$(node -e "console.log((Date.now()+365*24*3600*1000))")
  mkdir -p "$HOME/.claude"
  cat > "$CREDS" <<EOF
{
  "claudeAiOauth": {
    "accessToken": "$TOKEN",
    "expiresAt": $EXPIRES_AT
  }
}
EOF
  chmod 600 "$CREDS"
  echo "[install] $CREDS written."
fi

# -------- 5) Write ~/.claude/settings.json --------
SETTINGS="$HOME/.claude/settings.json"
if [ ! -f "$SETTINGS" ]; then
  cat > "$SETTINGS" <<'EOF'
{
  "permissions": { "allow": ["Read","Edit","Write","Glob","Grep","Bash"] },
  "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" }
}
EOF
  echo "[install] wrote default $SETTINGS"
fi

# -------- 6) Copy agents defs from repo -> ~/.claude/agents --------
mkdir -p "$AGENTS_DIR"
for f in "$REPO_ROOT/agents/"*.md; do
  name=$(basename "$f")
  # main-AGENTS.md goes to workspace, not agents dir
  if [ "$name" = "main-AGENTS.md" ]; then continue; fi
  cp "$f" "$AGENTS_DIR/$name"
done
echo "[install] synced subagent defs -> $AGENTS_DIR"

# -------- 7) Copy main workspace soul files --------
mkdir -p "$WORKSPACE_DIR"
cp "$REPO_ROOT/agents/main-AGENTS.md" "$WORKSPACE_DIR/AGENTS.md"
# IDENTITY/USER/TOOLS/SOUL are per-machine personality — don't overwrite if user customized.
# Here we only drop defaults if they don't exist yet.
for tpl in IDENTITY USER TOOLS SOUL HEARTBEAT; do
  target="$WORKSPACE_DIR/$tpl.md"
  src="$REPO_ROOT/agents/workspace-defaults/$tpl.md"
  if [ ! -f "$target" ] && [ -f "$src" ]; then
    cp "$src" "$target"
    echo "[install] seeded $target"
  fi
done
echo "[install] main workspace ready: $WORKSPACE_DIR"

# -------- 8) Mirror subagent defs to ~/.openclaw/workspaces (visibility) --------
bash "$SCRIPT_DIR/sync-agents.sh"

# -------- 9) Wire anthropic:claude-cli profile if missing --------
AUTH_PROFILES="$HOME/.openclaw/agents/main/agent/auth-profiles.json"
if [ -f "$AUTH_PROFILES" ]; then
  if ! grep -q '"anthropic:claude-cli"' "$AUTH_PROFILES"; then
    echo "[install] anthropic:claude-cli profile missing in $AUTH_PROFILES"
    echo "  Run this in a terminal with TTY:"
    echo "    openclaw models auth login --provider anthropic --method cli --set-default"
    echo "  Or copy the profile block from docs/auth-profile-example.json into $AUTH_PROFILES"
  else
    echo "[install] anthropic:claude-cli profile already present"
  fi
fi

# -------- 10) Sanity summary --------
echo ""
echo "============================================================"
echo " install.sh done"
echo "============================================================"
echo "  agents defs:   $AGENTS_DIR/"
echo "  main ws:       $WORKSPACE_DIR/"
echo "  workspaces:    $WORKSPACES_DIR/"
echo "  projects root: $PROJECTS_DIR/"
echo "  secrets:       $SECRETS_DIR/  (check that github_token, trello_*, github_owner exist)"
echo ""
echo "Next:"
echo "  bash scripts/start-gateway.sh"
echo "  open http://localhost:18789/  (or http://<this-host>:18789/ from remote)"
echo "  URL format: ?session=agent:main:<any-session-name>"
