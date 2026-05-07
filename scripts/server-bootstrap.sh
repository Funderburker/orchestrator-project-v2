#!/usr/bin/env bash
# server-bootstrap.sh — one-shot, idempotent setup of an OpenClaw host.
#
# Run on a fresh server (Ubuntu/Debian) AS ROOT, after:
#   - cloning this repo to anywhere
#   - cloning & building openclaw at /opt/openclaw (own flow, not ours)
#   - placing per-host secrets in ~/.openclaw/secrets/:
#       * github_token        (ghp_… classic PAT)
#       * trello_*, telegram.env, claude_oauth_token_2 — if used
#   - having docker, docker compose, nginx already installed
#
# What it does (each step is idempotent — safe to rerun):
#   1. Install gh CLI + apache2-utils on the host
#   2. Log gh in via the host's github_token, normalize hosts.yml
#   3. Stable copy of hosts.yml at /etc/openclaw/gh-hosts.yml (mounted into containers)
#   4. nginx basic auth on https://<host>/  (gateway reverse proxy)
#   5. chmod 700 secrets dirs, 600 secret files
#   6. Install/refresh main's Stop hook with anti-injection filter
#   7. Patch openclaw.json: GIT_AUTHOR_*/GIT_COMMITTER_* in cliBackends.claude-cli.env
#   8. Generate /opt/openclaw/docker-compose.override.yml from our template
#   9. docker compose up -d (only if anything changed)
#  10. Smoke tests: gh, nginx auth, container health
#
# Tunables (env vars, all optional):
#   OPENCLAW_DIR                 default /opt/openclaw
#   OPENCLAW_CONFIG_DIR          default /root/.openclaw
#   OPENCLAW_EXTRAS_DIR          default /etc/openclaw
#   OPENCLAW_NGINX_AUTH_USER     default = gh login
#   OPENCLAW_NGINX_SITE_CONF     default /etc/nginx/sites-enabled/openclaw-ssl.conf
#   OPENCLAW_GIT_USER            default = gh login
#   OPENCLAW_GIT_EMAIL           default = <login>@users.noreply.github.com

set -euo pipefail

# ---------- helpers ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES="$SCRIPT_DIR/templates"

OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
OPENCLAW_EXTRAS_DIR="${OPENCLAW_EXTRAS_DIR:-/etc/openclaw}"
NGINX_SITE_CONF="${OPENCLAW_NGINX_SITE_CONF:-/etc/nginx/sites-enabled/openclaw-ssl.conf}"
NGINX_AUTH_DIR="/etc/nginx/auth"
NGINX_AUTH_FILE="$NGINX_AUTH_DIR/openclaw_ui"
SECRETS_DIR="$OPENCLAW_CONFIG_DIR/secrets"
TOKEN_FILE="$SECRETS_DIR/github_token"
PASSWORD_FILE="$SECRETS_DIR/openclaw_ui_password"
HOSTS_YML_SRC="$HOME/.config/gh/hosts.yml"
GH_CFG_DIR="$OPENCLAW_EXTRAS_DIR/gh"
HOSTS_YML_DST="$GH_CFG_DIR/hosts.yml"
OVERRIDE_DST="$OPENCLAW_DIR/docker-compose.override.yml"
HOOK_DST="$OPENCLAW_CONFIG_DIR/workspace/scripts/session-stop-dump.sh"
OPENCLAW_JSON="$OPENCLAW_CONFIG_DIR/openclaw.json"

# Container uid for the openclaw image (always 1000:1000 in upstream)
NODE_UID=1000
NODE_GID=1000

CHANGED=0  # set to 1 when something on disk changed → triggers compose up

log()  { echo "[bootstrap] $*"; }
warn() { echo "[bootstrap][WARN] $*" >&2; }
die()  { echo "[bootstrap][FATAL] $*" >&2; exit 1; }

# ---------- 0) preflight ----------
[ "$(id -u)" -eq 0 ] || die "must run as root (sudo)"
for bin in docker docker-compose nginx jq python3 curl; do
  command -v "$bin" >/dev/null 2>&1 || \
    if [ "$bin" = "docker-compose" ]; then docker compose version >/dev/null 2>&1 || die "$bin missing"; \
    else die "$bin missing"; fi
done
[ -d "$OPENCLAW_DIR" ] || die "$OPENCLAW_DIR not found — clone openclaw upstream first"
[ -f "$OPENCLAW_DIR/docker-compose.yml" ] || die "$OPENCLAW_DIR/docker-compose.yml missing"
[ -d "$OPENCLAW_CONFIG_DIR" ] || die "$OPENCLAW_CONFIG_DIR missing — run \`openclaw onboard\` first"
[ -s "$TOKEN_FILE" ] || die "$TOKEN_FILE missing or empty"
[ -d "$TEMPLATES" ] || die "$TEMPLATES missing — run from cloned repo"
[ -f "$TEMPLATES/session-stop-dump.sh" ] || die "$TEMPLATES/session-stop-dump.sh missing"
[ -f "$TEMPLATES/openclaw-compose.override.yml" ] || die "$TEMPLATES/openclaw-compose.override.yml missing"
[ -f "$REPO_ROOT/agents/main-AGENTS.md" ] || die "$REPO_ROOT/agents/main-AGENTS.md missing"
[ -f "$REPO_ROOT/scripts/new-project.sh" ] || die "$REPO_ROOT/scripts/new-project.sh missing"

# ---------- 1) host packages ----------
log "1/12 installing gh + apache2-utils on host"
need_install=()
command -v gh >/dev/null 2>&1 || need_install+=(gh)
command -v htpasswd >/dev/null 2>&1 || need_install+=(apache2-utils)
if [ "${#need_install[@]}" -gt 0 ]; then
  if ! command -v gh >/dev/null 2>&1; then
    install -m0755 -d /etc/apt/keyrings || true
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list
  fi
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need_install[@]}"
else
  log "    already installed"
fi

# ---------- 2) gh auth on host ----------
log "2/12 gh auth login (idempotent)"
GH_TOKEN_VAL="$(cat "$TOKEN_FILE")"
if ! GH_TOKEN="$GH_TOKEN_VAL" gh auth status -h github.com >/dev/null 2>&1; then
  gh auth login --with-token < "$TOKEN_FILE"
fi
# Force format-upgrade of hosts.yml on host (so we can mount :ro into containers)
GH_LOGIN="$(GH_TOKEN="$GH_TOKEN_VAL" gh api /user --jq .login)"
[ -n "$GH_LOGIN" ] || die "gh api /user returned empty login — bad token?"
log "    logged in as: $GH_LOGIN"

NGINX_AUTH_USER="${OPENCLAW_NGINX_AUTH_USER:-$GH_LOGIN}"
GIT_USER="${OPENCLAW_GIT_USER:-$GH_LOGIN}"
GIT_EMAIL="${OPENCLAW_GIT_EMAIL:-${GH_LOGIN}@users.noreply.github.com}"

# ---------- 3) gh config dir for container mount ----------
# We mount the whole dir (not single file) so gh can write its companion
# config.yml next to hosts.yml on first call inside the container.
log "3/12 gh config dir → $GH_CFG_DIR"
mkdir -p "$GH_CFG_DIR"
chown "$NODE_UID:$NODE_GID" "$GH_CFG_DIR"
chmod 0700 "$GH_CFG_DIR"
[ -f "$HOSTS_YML_SRC" ] || die "$HOSTS_YML_SRC missing — gh login flow broke"
if ! cmp -s "$HOSTS_YML_SRC" "$HOSTS_YML_DST" 2>/dev/null; then
  install -m 0600 "$HOSTS_YML_SRC" "$HOSTS_YML_DST"
  CHANGED=1
fi
chown "$NODE_UID:$NODE_GID" "$HOSTS_YML_DST"
chmod 0600 "$HOSTS_YML_DST"
# Clean up legacy single-file path if it exists (older bootstrap version)
[ -f "$OPENCLAW_EXTRAS_DIR/gh-hosts.yml" ] && rm -f "$OPENCLAW_EXTRAS_DIR/gh-hosts.yml"

# ---------- 4) nginx basic auth ----------
if [ -f "$NGINX_SITE_CONF" ]; then
  log "4/12 nginx basic auth on $NGINX_SITE_CONF"
  mkdir -p "$NGINX_AUTH_DIR"
  if [ ! -s "$PASSWORD_FILE" ]; then
    PW="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    umask 077; printf '%s\n' "$PW" > "$PASSWORD_FILE"
    log "    generated new password → $PASSWORD_FILE"
  fi
  PW="$(cat "$PASSWORD_FILE")"
  if [ ! -f "$NGINX_AUTH_FILE" ] || ! htpasswd -vbB "$NGINX_AUTH_FILE" "$NGINX_AUTH_USER" "$PW" >/dev/null 2>&1; then
    htpasswd -bcB "$NGINX_AUTH_FILE" "$NGINX_AUTH_USER" "$PW" >/dev/null
    log "    wrote htpasswd for user: $NGINX_AUTH_USER"
  fi
  chown root:www-data "$NGINX_AUTH_FILE"; chmod 0640 "$NGINX_AUTH_FILE"

  if ! grep -q "auth_basic_user_file $NGINX_AUTH_FILE" "$NGINX_SITE_CONF"; then
    cp "$NGINX_SITE_CONF" "$NGINX_SITE_CONF.bak.$(date +%s)"
    sed -i "/location \/ {/a\\        auth_basic \"openclaw\";\\n        auth_basic_user_file $NGINX_AUTH_FILE;" "$NGINX_SITE_CONF"
    nginx -t >/dev/null
    systemctl reload nginx
    log "    auth_basic injected, nginx reloaded"
  else
    log "    auth_basic already configured"
  fi
else
  warn "4/12 $NGINX_SITE_CONF not found — skipping nginx auth (set OPENCLAW_NGINX_SITE_CONF if your path differs)"
fi

# ---------- 5) tighten secret perms ----------
log "5/12 chmod secrets"
chmod 0700 "$OPENCLAW_CONFIG_DIR" "$SECRETS_DIR"
find "$SECRETS_DIR" -mindepth 1 -maxdepth 1 -type f -exec chmod 0600 {} \;
find "$SECRETS_DIR" -mindepth 1 -maxdepth 1 -type d -exec chmod 0700 {} \;

# ---------- 6) Stop hook with anti-injection filter ----------
log "6/12 main Stop hook → $HOOK_DST"
mkdir -p "$(dirname "$HOOK_DST")"
if ! cmp -s "$TEMPLATES/session-stop-dump.sh" "$HOOK_DST" 2>/dev/null; then
  install -m 0755 "$TEMPLATES/session-stop-dump.sh" "$HOOK_DST"
  log "    updated"
else
  log "    up-to-date"
fi

# ---------- 7) workspace files: agents/main/* + agents/worker/* + new-project.sh ----------
log "7/12 deploy workspace files (main + worker templates, new-project.sh)"
WORKSPACE_DIR="$OPENCLAW_CONFIG_DIR/workspace"
WORKER_WORKSPACE="$OPENCLAW_CONFIG_DIR/workspaces/worker"
mkdir -p "$WORKSPACE_DIR/scripts" "$WORKER_WORKSPACE"

deploy_workspace_file() {
  local src="$1" dst="$2" mode="$3"
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    [ -f "$dst" ] && cp "$dst" "$dst.bak.$(date +%s)"
    install -m "$mode" "$src" "$dst"
    chown "$NODE_UID:$NODE_GID" "$dst"
    log "    updated: $dst"
  else
    log "    up-to-date: $dst"
  fi
}

# main (~/.openclaw/workspace/*.md)
if [ -d "$REPO_ROOT/agents/main" ]; then
  for src in "$REPO_ROOT/agents/main/"*.md; do
    [ -f "$src" ] || continue
    deploy_workspace_file "$src" "$WORKSPACE_DIR/$(basename "$src")" 0644
  done
else
  warn "    $REPO_ROOT/agents/main missing — main templates not deployed"
fi

# worker (~/.openclaw/workspaces/worker/*.md)
if [ -d "$REPO_ROOT/agents/worker" ]; then
  for src in "$REPO_ROOT/agents/worker/"*.md; do
    [ -f "$src" ] || continue
    deploy_workspace_file "$src" "$WORKER_WORKSPACE/$(basename "$src")" 0644
  done
else
  warn "    $REPO_ROOT/agents/worker missing — worker templates not deployed"
fi

# script
deploy_workspace_file "$REPO_ROOT/scripts/new-project.sh" "$WORKSPACE_DIR/scripts/new-project.sh" 0755

# ---------- 8) openclaw.json: GIT_* env + claude full path ----------
log "8/12 openclaw.json: cliBackends.claude-cli.command (full path) + GIT_AUTHOR_*/GIT_COMMITTER_*"
[ -f "$OPENCLAW_JSON" ] || die "$OPENCLAW_JSON missing"
python3 - "$OPENCLAW_JSON" "$GIT_USER" "$GIT_EMAIL" <<'PY'
import json, sys
path, user, email = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    d = json.load(f)
backend = d.setdefault("agents", {}).setdefault("defaults", {}) \
           .setdefault("cliBackends", {}).setdefault("claude-cli", {})
# openclaw image v5.6+ no longer creates /usr/local/bin/claude symlink at build
# time — point at the cli.js entry directly to avoid PATH lookup failure.
desired_command = "/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
if backend.get("command") != desired_command:
    backend["command"] = desired_command
env = backend.setdefault("env", {})
desired = {
    "GIT_AUTHOR_NAME": user,
    "GIT_AUTHOR_EMAIL": email,
    "GIT_COMMITTER_NAME": user,
    "GIT_COMMITTER_EMAIL": email,
}
# strip non-working keys (openclaw filters them before reaching the agent)
for k in ("GH_TOKEN", "GITHUB_TOKEN"):
    env.pop(k, None)
changed = False
for k, v in desired.items():
    if env.get(k) != v:
        env[k] = v
        changed = True
if changed:
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
print("changed" if changed else "noop")
PY
# ↑ python prints 'changed' or 'noop' on stdout; we just rely on it for visibility.

# ---------- 9) docker-compose.override.yml ----------
log "9/12 override → $OVERRIDE_DST"
if ! cmp -s "$TEMPLATES/openclaw-compose.override.yml" "$OVERRIDE_DST" 2>/dev/null; then
  install -m 0644 "$TEMPLATES/openclaw-compose.override.yml" "$OVERRIDE_DST"
  CHANGED=1
  log "    updated"
else
  log "    up-to-date"
fi

# ---------- 10) compose up -d ----------
if [ "$CHANGED" -eq 1 ]; then
  log "10/12 docker compose up -d (recreating where needed)"
  ( cd "$OPENCLAW_DIR" && docker compose up -d ) | sed 's/^/    /'
else
  log "10/12 nothing changed → skip recreate; running compose up -d to ensure all services up"
  ( cd "$OPENCLAW_DIR" && docker compose up -d ) | sed 's/^/    /'
fi

# wait for gateway healthy (max 60s)
for i in $(seq 1 30); do
  s="$(docker inspect -f '{{.State.Health.Status}}' openclaw-openclaw-gateway-1 2>/dev/null || echo none)"
  [ "$s" = "healthy" ] && break
  sleep 2
done

# ---------- 11) workspace files smoke ----------
log "11/12 workspace deploy verify"
if grep -q "Multi-user изоляция" "$WORKSPACE_DIR/AGENTS.md" 2>/dev/null; then
  log "    ✓ AGENTS.md contains multi-user section"
else
  warn "    ✗ AGENTS.md missing multi-user section"
fi
if bash -n "$WORKSPACE_DIR/scripts/new-project.sh" 2>/dev/null; then
  log "    ✓ new-project.sh syntax OK"
else
  warn "    ✗ new-project.sh syntax FAILED"
fi

# ---------- 12) smoke tests ----------
log "12/12 smoke tests"
fail=0

# gh inside both containers
for c in openclaw-openclaw-cli-1 openclaw-openclaw-gateway-1; do
  if docker exec "$c" sh -c 'gh api /user --jq .login' 2>/dev/null | grep -q "^$GH_LOGIN$"; then
    log "    ✓ $c → gh api /user = $GH_LOGIN"
  else
    warn "    ✗ $c → gh smoke FAILED"
    fail=1
  fi
done

# nginx 401/200
if [ -f "$NGINX_SITE_CONF" ]; then
  PW="$(cat "$PASSWORD_FILE")"
  c1="$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/)"
  c2="$(curl -sk -o /dev/null -w '%{http_code}' -u "$NGINX_AUTH_USER:$PW" https://127.0.0.1/)"
  if [ "$c1" = "401" ] && [ "$c2" = "200" ]; then
    log "    ✓ nginx auth: no-auth=401 with-auth=200"
  else
    warn "    ✗ nginx auth: no-auth=$c1 with-auth=$c2"
    fail=1
  fi
fi

# session-stop-dump.sh syntax
if bash -n "$HOOK_DST" 2>/dev/null; then
  log "    ✓ Stop hook syntax OK"
else
  warn "    ✗ Stop hook syntax FAILED"; fail=1
fi

if [ "$fail" -eq 0 ]; then
  log "DONE — all smoke tests passed"
  log ""
  log "  GitHub login:        $GH_LOGIN"
  log "  Git author/email:    $GIT_USER <$GIT_EMAIL>"
  log "  nginx UI URL:        https://<host>/   (login: $NGINX_AUTH_USER)"
  log "  nginx UI password:   stored in $PASSWORD_FILE"
  log ""
else
  die "some smoke tests failed — see warnings above"
fi
