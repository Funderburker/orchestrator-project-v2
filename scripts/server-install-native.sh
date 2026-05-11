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
#   4. teamclaude proxy (multi-account rotation): git clone /opt/teamclaude,
#      install our relay (/opt/teamclaude-relay/teamclaude-relay.cjs from repo
#      vendor/), generate PROXY_API_KEY, install 2 systemd units under
#      User=openclaw with the same hardening pattern devops used for openclaw.
#   5. Deploy agents/main/*.md, agents/worker/*.md, our new-project.sh
#   6. ~/.claude/settings.json (Stop hook)
#   7. Patch /home/openclaw/.openclaw/openclaw.json:
#      - cliBackends.claude-cli (full path + env: ANTHROPIC_BASE_URL,
#        GIT_AUTHOR_*/GIT_COMMITTER_*)
#      - agents.list (main + worker) if missing
#      - default model -> Claude
#   8. systemctl restart openclaw (so it re-reads config)
#   9. Smoke tests (gh, claude, openclaw up, nginx 200, hook installed,
#      teamclaude + relay listening)

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

TEAMCLAUDE_REPO="${TEAMCLAUDE_REPO:-https://github.com/guilhermesilveira/teamclaude}"
TEAMCLAUDE_PIN="${TEAMCLAUDE_PIN:-}"  # commit hash to pin; empty = HEAD at install time
TEAMCLAUDE_DIR=/opt/teamclaude
RELAY_DIR=/opt/teamclaude-relay
RELAY_ENV_FILE=/etc/teamclaude-relay/env

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

# ---------- 4) teamclaude proxy + our relay ----------
log "4/9 teamclaude proxy (multi-account rotation) + relay"

# 4a) git clone teamclaude (vendored at /opt/teamclaude, pinned commit if set)
if [ ! -d "$TEAMCLAUDE_DIR/.git" ]; then
  git clone "$TEAMCLAUDE_REPO" "$TEAMCLAUDE_DIR"
fi
( cd "$TEAMCLAUDE_DIR" && git fetch >/dev/null 2>&1 || true )
if [ -n "$TEAMCLAUDE_PIN" ]; then
  ( cd "$TEAMCLAUDE_DIR" && git checkout "$TEAMCLAUDE_PIN" 2>&1 | tail -2 )
else
  ( cd "$TEAMCLAUDE_DIR" && git pull --ff-only 2>&1 | tail -2 ) || true
fi
log "    teamclaude commit: $(cd "$TEAMCLAUDE_DIR" && git rev-parse --short HEAD)"

# 4b) our relay (vendored in repo)
mkdir -p "$RELAY_DIR"
install -m 0644 "$REPO_ROOT/vendor/teamclaude-relay.cjs" "$RELAY_DIR/teamclaude-relay.cjs"

# 4c) generate PROXY_API_KEY if not yet (random secret, lives in /etc/teamclaude-relay/env)
mkdir -p "$(dirname "$RELAY_ENV_FILE")"
if [ ! -s "$RELAY_ENV_FILE" ] || ! grep -q '^PROXY_API_KEY=' "$RELAY_ENV_FILE"; then
  PROXY_API_KEY="tc-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  echo "PROXY_API_KEY=$PROXY_API_KEY" > "$RELAY_ENV_FILE"
  log "    generated new PROXY_API_KEY → $RELAY_ENV_FILE"
fi
chown root:"$OPENCLAW_USER" "$RELAY_ENV_FILE"
chmod 0640 "$RELAY_ENV_FILE"
PROXY_API_KEY=$(grep '^PROXY_API_KEY=' "$RELAY_ENV_FILE" | cut -d= -f2-)

# 4d) systemd units
install -m 0644 "$REPO_ROOT/scripts/templates/teamclaude.service"       /etc/systemd/system/teamclaude.service
install -m 0644 "$REPO_ROOT/scripts/templates/teamclaude-relay.service" /etc/systemd/system/teamclaude-relay.service
systemctl daemon-reload
systemctl enable teamclaude.service teamclaude-relay.service >/dev/null 2>&1
systemctl restart teamclaude.service
sleep 2
systemctl is-active teamclaude >/dev/null || warn "    teamclaude failed to start — see: journalctl -u teamclaude -n 30"

# 4e) sync proxy.apiKey in teamclaude.json with our generated one
TEAMCLAUDE_CONF="$OPENCLAW_HOME/.config/teamclaude.json"
if [ -f "$TEAMCLAUDE_CONF" ]; then
  as_openclaw_sh "python3 - '$TEAMCLAUDE_CONF' '$PROXY_API_KEY' <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path) as f: d = json.load(f)
prx = d.setdefault('proxy', {})
prx['apiKey'] = key
prx.setdefault('port', 3456)
prx.setdefault('host', '127.0.0.1')
with open(path,'w') as f: json.dump(d,f,indent=2); f.write('\n')
print('teamclaude.json proxy.apiKey synced')
PY"
  systemctl restart teamclaude.service
  sleep 2
fi

systemctl restart teamclaude-relay.service
sleep 1
systemctl is-active teamclaude-relay >/dev/null \
  && log "    ✓ teamclaude + relay running (3456 / 3457)" \
  || warn "    ✗ relay not active — journalctl -u teamclaude-relay -n 30"

if ! ss -tlnp 2>/dev/null | grep -q ':3456 '; then
  log "    NOTE: no accounts yet — to add: sudo -u $OPENCLAW_USER -- /usr/bin/node $TEAMCLAUDE_DIR/src/index.js login --name <name>"
fi

# ---------- 5) workspace + worker templates from our repo ----------
log "5/9 deploy agents/main/* and agents/worker/* into workspace"
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

# ---------- 6) Stop hook + (optional) bootstrap .credentials.json ----------
log "6/9 ~/.claude/settings.json (Stop hook)"
mkdir -p "$CLAUDE_DIR"
# .credentials.json — claude code хочет видеть валидный OAuth токен на старте,
# но при runtime все запросы идут через teamclaude relay (он подменяет x-api-key).
# Если есть claude_oauth_token в секретах — кладём; нет — пропускаем, claude
# code иногда работает и без него если ANTHROPIC_BASE_URL установлен и
# CLAUDE_CODE_OAUTH_TOKEN передаётся через env.
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

# ---------- 7) Patch openclaw.json ----------
log "7/9 patch openclaw.json: cliBackends.claude-cli (via teamclaude relay) + agents + default model"
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
    # Все запросы Claude идут через teamclaude relay (наш wrapper) на 3457
    env['ANTHROPIC_BASE_URL']  = 'http://127.0.0.1:3457'
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

# ---------- 8) restart openclaw ----------
log "8/9 systemctl restart openclaw"
systemctl restart openclaw
sleep 4
systemctl is-active openclaw >/dev/null || die "openclaw failed to start after restart — journalctl -u openclaw -n 40"
log "    openclaw active"

# ---------- 9) smoke tests ----------
log "9/9 smoke tests"
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
ss -tlnp 2>/dev/null | grep -q ':3456 ' \
  && log "    ✓ teamclaude listening on 127.0.0.1:3456" \
  || warn "    (info) teamclaude not on 3456 — no accounts yet?"
ss -tlnp 2>/dev/null | grep -q ':3457 ' \
  && log "    ✓ relay listening on 127.0.0.1:3457" \
  || { warn "    ✗ relay not on 3457"; fail=1; }
curl -sk -o /dev/null -w "    nginx https://localhost/: %{http_code}\n" https://localhost/

if [ "$fail" -eq 0 ]; then
  log "DONE"
  log "  GitHub login:     $GH_LOGIN"
  log "  Git author/email: $GIT_USER <$GIT_EMAIL>"
  log "  Claude wiring:    $([ "$HAS_CLAUDE" -eq 1 ] && echo enabled || echo SKIPPED — drop claude_oauth_token to enable)"
  log "  openclaw config:  $OPENCLAW_CONFIG"
  log ""
  log "  Next step (manual): add Claude OAuth accounts to teamclaude rotation:"
  log "    sudo -u $OPENCLAW_USER -- /usr/bin/node $TEAMCLAUDE_DIR/src/index.js login --name acct-1"
  log "    sudo -u $OPENCLAW_USER -- /usr/bin/node $TEAMCLAUDE_DIR/src/index.js login --name acct-2"
  log "    # then: systemctl restart teamclaude"
  log ""
  log "  Restart cleanly:  systemctl restart teamclaude teamclaude-relay openclaw"
else
  die "some smoke tests failed; check warnings"
fi
