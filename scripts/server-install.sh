#!/usr/bin/env bash
# server-install.sh — full setup of a fresh Ubuntu server to a working
# openclaw multi-agent gateway. AS ROOT.
#
# Pre-conditions (ровно одно ручное действие):
#   1. Ubuntu/Debian, root SSH-доступ.
#   2. Per-host secrets in ~/.openclaw/secrets/:
#      - github_token        — classic PAT (repo, workflow scopes)
#      - telegram.env        — TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=...  (optional)
#      - trello_*            — если используешь
#
# Что делает (idempotent — можно гонять заново):
#   1. apt install docker.io, docker-compose, nginx, jq, python3, curl
#   2. clone openclaw в /opt/openclaw (если нет) + checkout pinned tag
#   3. docker build -t openclaw:local (если image нет или старый)
#   4. openclaw onboard (если ~/.openclaw/openclaw.json нет)
#   5. подложить наш custom docker-compose.yml в /opt/openclaw (если ещё его не там)
#   6. nginx site-config (минимальный TLS+proxy если нет)
#   7. вызывает scripts/server-bootstrap.sh (gh, hooks, AGENTS.md, override, etc.)
#
# Время: ~10-20 мин (build openclaw image — самая долгая фаза).
#
# После: main отвечает в TG, worker рапортует, multi-user изоляция работает.

set -euo pipefail

# ---------- helpers ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
OPENCLAW_TAG="${OPENCLAW_TAG:-v2026.5.6}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-openclaw:local}"
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
NGINX_SITE_CONF="${OPENCLAW_NGINX_SITE_CONF:-/etc/nginx/sites-enabled/openclaw-ssl.conf}"

log()  { echo "[install] $*"; }
warn() { echo "[install][WARN] $*" >&2; }
die()  { echo "[install][FATAL] $*" >&2; exit 1; }

# ---------- 0) preflight ----------
[ "$(id -u)" -eq 0 ] || die "must run as root (sudo)"
[ -d "$REPO_ROOT/scripts/templates" ] || die "$REPO_ROOT/scripts/templates missing — run from cloned repo"
[ -s "$OPENCLAW_CONFIG_DIR/secrets/github_token" ] || die "$OPENCLAW_CONFIG_DIR/secrets/github_token missing"

# ---------- 1) apt deps ----------
log "1/7 apt install deps"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  docker.io docker-compose-v2 nginx jq python3 python3-yaml curl ca-certificates git

# docker.sock group GID we'll need later (for compose group_add)
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 999)
log "    docker.sock GID=$DOCKER_GID (used in compose group_add)"

# ---------- 2) openclaw repo ----------
log "2/7 openclaw repo at $OPENCLAW_DIR (target: $OPENCLAW_TAG)"
if [ ! -d "$OPENCLAW_DIR/.git" ]; then
  log "    cloning…"
  git clone https://github.com/openclaw/openclaw "$OPENCLAW_DIR"
fi
( cd "$OPENCLAW_DIR" && git fetch --tags --prune --force >/dev/null 2>&1 || true )
CURRENT_TAG=$( cd "$OPENCLAW_DIR" && git describe --tags 2>/dev/null || echo "unknown" )
if [ "$CURRENT_TAG" != "$OPENCLAW_TAG" ]; then
  log "    checking out $OPENCLAW_TAG (was $CURRENT_TAG)"
  # save any local mod to compose
  ( cd "$OPENCLAW_DIR" && [ -f docker-compose.yml ] && cp docker-compose.yml /tmp/openclaw-compose.before-checkout.yml ) || true
  ( cd "$OPENCLAW_DIR" && git stash push -u -m "before-checkout-$(date +%s)" || true )
  ( cd "$OPENCLAW_DIR" && git checkout "$OPENCLAW_TAG" )
fi

# ---------- 3) custom docker-compose.yml ----------
log "3/7 custom docker-compose.yml"
COMPOSE_TEMPLATE="$REPO_ROOT/scripts/templates/openclaw-docker-compose.yml"
if [ -f "$COMPOSE_TEMPLATE" ]; then
  if ! cmp -s "$COMPOSE_TEMPLATE" "$OPENCLAW_DIR/docker-compose.yml"; then
    cp "$OPENCLAW_DIR/docker-compose.yml" "$OPENCLAW_DIR/docker-compose.yml.upstream-$(date +%s)" 2>/dev/null || true
    install -m 0644 "$COMPOSE_TEMPLATE" "$OPENCLAW_DIR/docker-compose.yml"
    log "    custom compose installed"
  else
    log "    compose up-to-date"
  fi
else
  warn "    $COMPOSE_TEMPLATE missing — using upstream compose (you may need TRELLO/GH env etc; see DEPLOY_TODO.md)"
fi

# ---------- 4) build image ----------
log "4/7 docker image $OPENCLAW_IMAGE"
NEED_BUILD=0
if ! docker image inspect "$OPENCLAW_IMAGE" >/dev/null 2>&1; then
  NEED_BUILD=1
  log "    image not found → building"
fi
if [ "$NEED_BUILD" -eq 1 ]; then
  ( cd "$OPENCLAW_DIR" && docker build -t "$OPENCLAW_IMAGE" . ) | tail -5
else
  log "    image already exists — skip build (set NEED_BUILD=1 env to force)"
fi

# ---------- 5) openclaw onboard ----------
log "5/7 openclaw onboard"
if [ ! -f "$OPENCLAW_CONFIG_DIR/openclaw.json" ]; then
  # one-shot inside container
  docker run --rm -v "$OPENCLAW_CONFIG_DIR:/home/node/.openclaw" \
    "$OPENCLAW_IMAGE" node dist/index.js onboard --non-interactive --accept-risk --auth-choice skip \
    | tail -5 || warn "    onboard failed — may need manual step"
else
  log "    openclaw.json already exists"
fi

# ---------- 6) nginx site config (minimal if absent) ----------
log "6/7 nginx site config"
if [ ! -f "$NGINX_SITE_CONF" ]; then
  log "    no nginx site → creating minimal HTTP→HTTPS proxy to gateway"
  IP=$(hostname -I | awk '{print $1}')
  cat > "$NGINX_SITE_CONF" <<EOF
server {
    listen 80;
    server_name $IP;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $IP;
    # Self-signed certs as placeholder. Replace with real ones (Let's Encrypt etc).
    ssl_certificate     /etc/nginx/ssl/openclaw.crt;
    ssl_certificate_key /etc/nginx/ssl/openclaw.key;
    location / {
        proxy_pass http://127.0.0.1:18789;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
EOF
  # self-signed certs if missing
  mkdir -p /etc/nginx/ssl
  if [ ! -f /etc/nginx/ssl/openclaw.crt ]; then
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/openclaw.key -out /etc/nginx/ssl/openclaw.crt \
      -days 365 -subj "/CN=$IP" 2>/dev/null
  fi
  nginx -t && systemctl reload nginx
fi

# ---------- 7) hand off to server-bootstrap.sh ----------
log "7/7 running scripts/server-bootstrap.sh (gh, hooks, AGENTS, override, etc.)"
bash "$SCRIPT_DIR/server-bootstrap.sh"

log ""
log "ALL DONE. UI: https://<host>/  (basic auth: см. ~/.openclaw/secrets/openclaw_ui_password)"
log "Ловушки и TODO — DEPLOY_TODO.md и memory project_architecture_server.md"
