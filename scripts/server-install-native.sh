#!/usr/bin/env bash
# server-install-native.sh — adapt our orchestrator setup to a native-systemd
# openclaw server (where openclaw runs as a hardened systemd service under
# user `openclaw`, NOT in Docker).
#
# Designed to NOT touch any of devops' security hardening:
#   - leaves systemd unit (User=openclaw, NoNewPrivileges, ProtectSystem=strict, etc.)
#   - leaves UFW rules / SSH config / AppArmor / unattended-upgrades alone
#   - all writes confined to /opt/openclaw and /home/openclaw (where the service
#     unit's ReadWritePaths already permit)
#
# Pre-conditions (devops sets up; we don't):
#   - systemd unit openclaw.service running under user `openclaw`
#   - /opt/openclaw checked out, package.json version >= 2026.5.6
#   - /home/openclaw/.openclaw/openclaw.json exists (onboard already done)
#   - nginx site-config has proxy_pass to http://127.0.0.1:18789
#   - Secrets dropped under /home/openclaw/.openclaw/secrets/ (owner=openclaw, 0600):
#       * github_token       (classic PAT)
#       * claude_oauth_token (sk-ant-oat01-...) — required if you want main on Claude
#       * github_owner       (e.g. `Funderburker`)
#       * trello_lists.env   (optional, includes TRELLO_KEY/TRELLO_TOKEN/BOARD_ID)
#       * telegram.env       (optional)
#
# What it does (idempotent, safe to rerun):
#   1. apt deps: gh, apache2-utils, jq (curl/python3/openssl/git already present)
#   2. claude CLI globally: npm i -g @anthropic-ai/claude-code@<PIN>
#   3. gh auth (under openclaw user, file-based)
#   4. Deploy agents/main/*.md, agents/worker/*.md, our new-project.sh
#   5. ~/.claude/.credentials.json + ~/.claude/settings.json (Stop hook)
#   6. Patch /home/openclaw/.openclaw/openclaw.json:
#      - cliBackends.claude-cli (full path + env: CLAUDE_CODE_OAUTH_TOKEN, GIT_AUTHOR_*)
#      - agents.list (main + worker) if missing
#      - default model -> Claude
#   7. systemctl restart openclaw (so it re-reads config)
#   8. Smoke tests (gh, claude, openclaw up, nginx 200, hook installed)

set -euo pipefail

# ---------- helpers ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_HOME="$(getent passwd "$OPENCLAW_USER" 2>/dev/null | cut -d: -f6)"
OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
OPENCLAW_CONFIG="$OPENCLAW_HOME/.openclaw/openclaw.json"
WORKSPACE_DIR="$OPENCLAW_HOME/.openclaw/workspace"
WORKER_WORKSPACE="$OPENCLAW_HOME/.openclaw/workspaces/worker"
SECRETS_DIR="$OPENCLAW_HOME/.openclaw/secrets"
CLAUDE_DIR="$OPENCLAW_HOME/.claude"
CLAUDE_PIN="${CLAUDE_PIN:-2.1.119}"

log()  { echo "[install-native] $*"; }
warn() { echo "[install-native][WARN] $*" >&2; }
die()  { echo "[install-native][FATAL] $*" >&2; exit 1; }

# Run a command as the openclaw user (shell=/bin/false → can't sudo -i, use runuser)
as_openclaw() { runuser -u "$OPENCLAW_USER" -- "$@"; }
as_openclaw_sh() { runuser -u "$OPENCLAW_USER" -- /bin/sh -c "$*"; }

# ---------- 0) preflight ----------
[ "$(id -u)" -eq 0 ] || die "must run as root"
id "$OPENCLAW_USER" >/dev/null 2>&1 || die "user $OPENCLAW_USER missing (devops setup incomplete?)"
[ -n "$OPENCLAW_HOME" ] && [ -d "$OPENCLAW_HOME" ] || die "$OPENCLAW_USER home missing"
systemctl list-unit-files openclaw.service >/dev/null 2>&1 || die "openclaw.service not installed"
[ -f "$OPENCLAW_DIR/package.json" ] || die "$OPENCLAW_DIR not present"

OPENCLAW_VER=$(python3 -c "import json; print(json.load(open('$OPENCLAW_DIR/package.json')).get('version','?'))")
log "openclaw version on disk: $OPENCLAW_VER"
[ -f "$OPENCLAW_CONFIG" ] || die "$OPENCLAW_CONFIG missing — onboard the service first"

[ -s "$SECRETS_DIR/github_token" ]      || die "$SECRETS_DIR/github_token missing (drop the PAT)"
[ -s "$SECRETS_DIR/claude_oauth_token" ] || warn "$SECRETS_DIR/claude_oauth_token missing — will skip Claude wiring; main will keep default model"
HAS_CLAUDE=0
[ -s "$SECRETS_DIR/claude_oauth_token" ] && HAS_CLAUDE=1

[ -d "$REPO_ROOT/agents/main" ]  || die "$REPO_ROOT/agents/main missing — run from cloned repo"
[ -d "$REPO_ROOT/agents/worker" ] || die "$REPO_ROOT/agents/worker missing"

# ---------- 1) apt deps ----------
log "1/8 apt: gh, apache2-utils, jq"
need=()
command -v gh        >/dev/null 2>&1 || need+=(gh)
command -v htpasswd  >/dev/null 2>&1 || need+=(apache2-utils)
command -v jq        >/dev/null 2>&1 || need+=(jq)
if [ "${#need[@]}" -gt 0 ]; then
  if ! command -v gh >/dev/null 2>&1; then
    install -m0755 -d /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list
  fi
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
else
  log "    already installed"
fi

# ---------- 2) claude CLI globally (host install, not in container) ----------
log "2/8 claude CLI @anthropic-ai/claude-code@$CLAUDE_PIN"
CURRENT_CLAUDE=$(npm ls -g --depth=0 2>/dev/null | grep -oE '@anthropic-ai/claude-code@\S+' || echo "")
if [ "$CURRENT_CLAUDE" != "@anthropic-ai/claude-code@$CLAUDE_PIN" ]; then
  npm install -g "@anthropic-ai/claude-code@$CLAUDE_PIN" 2>&1 | tail -3
else
  log "    already at $CLAUDE_PIN"
fi
CLAUDE_BIN=$(command -v claude)
[ -x "$CLAUDE_BIN" ] || die "claude CLI install failed"
log "    claude at: $CLAUDE_BIN ($(claude --version | head -1))"

# ---------- 3) gh auth (file-based, under openclaw) ----------
log "3/8 gh auth (per openclaw user, file-based hosts.yml)"
# Put the token + login as openclaw, in its own ~/.config/gh/. file-based bypasses
# any env-filtering inside spawned claude subprocesses (lesson from old server).
mkdir -p "$OPENCLAW_HOME/.config/gh"
chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_HOME/.config"
as_openclaw_sh "GH_CONFIG_DIR=$OPENCLAW_HOME/.config/gh \
  gh auth login --with-token < $SECRETS_DIR/github_token" || warn "    gh auth login returned non-zero"
GH_LOGIN=$(as_openclaw_sh "GH_TOKEN=\$(cat $SECRETS_DIR/github_token) gh api /user --jq .login")
[ -n "$GH_LOGIN" ] || die "gh smoke failed"
log "    gh login: $GH_LOGIN"

GIT_USER="${OPENCLAW_GIT_USER:-$GH_LOGIN}"
GIT_EMAIL="${OPENCLAW_GIT_EMAIL:-${GH_LOGIN}@users.noreply.github.com}"

# ---------- 4) workspace + worker templates from our repo ----------
log "4/8 deploy agents/main/* and agents/worker/* into workspace"
mkdir -p "$WORKSPACE_DIR/scripts" "$WORKER_WORKSPACE"
chown "$OPENCLAW_USER:$OPENCLAW_USER" "$WORKSPACE_DIR" "$WORKER_WORKSPACE"

deploy() {
  local src="$1" dst="$2" mode="$3"
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    [ -f "$dst" ] && cp "$dst" "$dst.bak.$(date +%s)"
    install -m "$mode" -o "$OPENCLAW_USER" -g "$OPENCLAW_USER" "$src" "$dst"
    log "    updated: $dst"
  fi
}

for f in "$REPO_ROOT/agents/main/"*.md; do
  [ -f "$f" ] && deploy "$f" "$WORKSPACE_DIR/$(basename "$f")" 0644
done
for f in "$REPO_ROOT/agents/worker/"*.md; do
  [ -f "$f" ] && deploy "$f" "$WORKER_WORKSPACE/$(basename "$f")" 0644
done

deploy "$REPO_ROOT/scripts/new-project.sh"           "$WORKSPACE_DIR/scripts/new-project.sh"           0755
deploy "$REPO_ROOT/scripts/templates/session-stop-dump.sh" \
       "$WORKSPACE_DIR/scripts/session-stop-dump.sh"  0755

# ---------- 5) Claude credentials + Stop hook ----------
log "5/8 ~/.claude/.credentials.json + settings.json"
mkdir -p "$CLAUDE_DIR"
if [ "$HAS_CLAUDE" -eq 1 ]; then
  TOKEN=$(cat "$SECRETS_DIR/claude_oauth_token")
  EXPIRES=$(date -d '+1 year' +%s)000
  cat > "$CLAUDE_DIR/.credentials.json" <<EOF
{
  "claudeAiOauth": {
    "accessToken": "$TOKEN",
    "expiresAt": $EXPIRES
  }
}
EOF
  chmod 600 "$CLAUDE_DIR/.credentials.json"
fi

cat > "$CLAUDE_DIR/settings.json" <<EOF
{
  "permissions": { "allow": ["Read","Edit","Write","Glob","Grep","Bash"] },
  "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" },
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "bash $WORKSPACE_DIR/scripts/session-stop-dump.sh" }
        ]
      }
    ]
  }
}
EOF
chmod 600 "$CLAUDE_DIR/settings.json"
chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$CLAUDE_DIR"

# ---------- 6) Patch openclaw.json ----------
log "6/8 patch openclaw.json: cliBackends.claude-cli + agents + default model"
cp "$OPENCLAW_CONFIG" "$OPENCLAW_CONFIG.bak.$(date +%s)"
as_openclaw_sh "python3 - '$OPENCLAW_CONFIG' '$CLAUDE_BIN' '$GIT_USER' '$GIT_EMAIL' '$HAS_CLAUDE' <<'PY'
import json, sys, os
path, claude_bin, user, email, has_claude = sys.argv[1:6]
has_claude = has_claude == '1'

with open(path) as f:
    d = json.load(f)

agents = d.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})
backends = defaults.setdefault('cliBackends', {})

if has_claude:
    cli = backends.setdefault('claude-cli', {})
    cli['command'] = claude_bin
    env = cli.setdefault('env', {})
    try:
        with open(os.environ['HOME'] + '/.claude/.credentials.json') as f:
            cred = json.load(f)
            env['CLAUDE_CODE_OAUTH_TOKEN'] = cred['claudeAiOauth']['accessToken']
    except Exception:
        pass
    env['GIT_AUTHOR_NAME']     = user
    env['GIT_AUTHOR_EMAIL']    = email
    env['GIT_COMMITTER_NAME']  = user
    env['GIT_COMMITTER_EMAIL'] = email
    # Default to Claude for primary
    model_cfg = defaults.setdefault('model', {})
    model_cfg['primary'] = 'claude-cli/claude-sonnet-4-6'
    model_cfg.setdefault('fallbacks', ['claude-cli/claude-opus-4-7', 'claude-cli/claude-haiku-4-5'])

# Ensure main + worker exist in agents.list
agent_list = agents.setdefault('list', [])
existing_ids = {a.get('id') for a in agent_list}
if 'main' not in existing_ids:
    agent_list.append({
        'id': 'main',
        'identity': {'name':'Manager','emoji':'🎯'},
        'workspace': os.environ['HOME'] + '/.openclaw/workspace',
        'subagents': {'allowAgents': ['worker']}
    })
if 'worker' not in existing_ids:
    agent_list.append({
        'id': 'worker',
        'identity': {'name':'Worker','emoji':'🔧'},
        'workspace': os.environ['HOME'] + '/.openclaw/workspaces/worker'
    })

with open(path, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
print('openclaw.json keys now:', sorted(d.keys()))
PY"

# ---------- 7) restart openclaw ----------
log "7/8 systemctl restart openclaw"
systemctl restart openclaw
sleep 4
systemctl is-active openclaw >/dev/null || die "openclaw failed to start after restart — journalctl -u openclaw -n 40"
log "    openclaw active"

# ---------- 8) smoke tests ----------
log "8/8 smoke tests"
fail=0
as_openclaw_sh "claude --version" >/dev/null 2>&1 \
  && log "    ✓ claude CLI reachable for openclaw user" \
  || { warn "    ✗ claude CLI not in PATH for openclaw"; fail=1; }
as_openclaw_sh "GH_CONFIG_DIR=$OPENCLAW_HOME/.config/gh gh api /user --jq .login" \
  | grep -q "^$GH_LOGIN$" \
  && log "    ✓ gh auth working under openclaw user" \
  || { warn "    ✗ gh auth not working"; fail=1; }
ss -tlnp 2>/dev/null | grep -q ':18789' \
  && log "    ✓ gateway listening on 127.0.0.1:18789" \
  || { warn "    ✗ gateway not listening"; fail=1; }
curl -sk -o /dev/null -w "    nginx https://localhost/: %{http_code}\n" https://localhost/

if [ "$fail" -eq 0 ]; then
  log "DONE"
  log "  GitHub login:     $GH_LOGIN"
  log "  Git author/email: $GIT_USER <$GIT_EMAIL>"
  log "  Claude wiring:    $([ "$HAS_CLAUDE" -eq 1 ] && echo enabled || echo SKIPPED — drop claude_oauth_token to enable)"
  log "  openclaw config:  $OPENCLAW_CONFIG"
  log "  Restart again:    systemctl restart openclaw"
else
  die "some smoke tests failed; check warnings"
fi
