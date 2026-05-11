# Deploy — quick start + what to check

Этот файл — short practical cheat sheet. Подробный обзор флоу — в `README.md`.

## Server (Docker openclaw) — one-shot install

На **новом** сервере (Ubuntu, root) — один скрипт от чистой машины до работающего main:
**`scripts/server-install.sh`**. Время: 10-20 минут (большая часть — `docker build` openclaw image).

### Что нужно ДО запуска (только секреты, ~30 сек):

```bash
# 1. SSH key-only доступ root (Hetzner cloud-init обычно делает сам)
# 2. Положи секреты (опционально, если используешь):
mkdir -p ~/.openclaw/secrets
cat > ~/.openclaw/secrets/telegram.env <<EOF
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...
EOF
chmod -R go-rwx ~/.openclaw/secrets
```

> ℹ️ GitHub-токены **не нужны** — проекты живут в локальном git на сервере, без remote.

### Запуск:

```bash
git clone https://github.com/Funderburker/orchestrator-project-v2 /root/orchestrator-project
bash /root/orchestrator-project/scripts/server-install.sh
```

### Что делает (idempotent):

| # | Шаг |
|---|---|
| 1 | apt install docker, docker-compose, nginx, jq, python3, openssl, git |
| 2 | git clone openclaw в /opt/openclaw + checkout pinned tag (`v2026.5.6`) |
| 3 | подкладывает наш custom docker-compose.yml поверх upstream |
| 4 | `docker build -t openclaw:local /opt/openclaw` (~10-15 мин) |
| 5 | `openclaw onboard` (создаёт ~/.openclaw/openclaw.json) |
| 6 | nginx site-config с TLS (self-signed → замени на Let's Encrypt) |
| 7 | вызывает `server-bootstrap.sh` (gh, hooks, AGENTS, override, claude full-path в openclaw.json, и т.д.) |

После — UI на `https://<host>/`, main отвечает в TG, worker→main→TG нотифы работают, multi-user изоляция (`~/projects/<chat_id>/<slug>/` + `memory/telegram_<chat_id>/`).

### server-bootstrap.sh отдельно

Если openclaw уже стоит и собран, и нужно только **донастроить** (gh, hooks, AGENTS, override) —
тот же `scripts/server-bootstrap.sh` без `install.sh` тоже работает.

### Pre-conditions (руками, один раз)

1. Ubuntu / Debian, root SSH-доступ.
2. `apt install -y docker.io docker-compose-v2 nginx jq python3 curl`.
3. Upstream openclaw склонирован в `/opt/openclaw`, образ `openclaw:local` собран
   (через openclaw'овский `Makefile` / `docker-setup.sh` — это их flow, не наш).
4. `openclaw onboard` проведён — создаёт `~/.openclaw/openclaw.json`.
5. `nginx` конфиг для openclaw создан в `/etc/nginx/sites-enabled/openclaw-ssl.conf`
   с `location / { proxy_pass http://127.0.0.1:18789; ... }` (TLS не обязателен,
   но без него — небезопасно).
6. (опционально) `~/.openclaw/secrets/openclaw_ui_password` — если хочешь
   фиксированный пароль для basic auth; иначе скрипт сам сгенерит.

### Запуск

```bash
git clone <repo-url> /root/orchestrator-project
bash /root/orchestrator-project/scripts/server-bootstrap.sh
```

Скрипт сам, идемпотентно:

| # | Что |
|---|---|
| 1 | Ставит `apache2-utils` (если не стоит) |
| 2 | nginx basic auth на `https://<host>/` (пароль в `~/.openclaw/secrets/openclaw_ui_password`) |
| 3 | `chmod 700` секреты директории, `600` файлы |
| 4 | Ставит main Stop hook с anti-injection фильтром |
| 5 | Патчит `openclaw.json` — добавляет `GIT_AUTHOR_*/GIT_COMMITTER_*` в env claude-cli (для локальных коммитов) |
| 6 | Генерирует `/opt/openclaw/docker-compose.override.yml` (cli=unless-stopped) |
| 7 | `docker compose up -d` (recreates если что-то поменялось) |
| 8 | Smoke: nginx 401/200, hook syntax |

### Перерасклад

Скрипт — pure idempotent: **прогоняй смело**, если ничего не изменилось — он
просто проверит и завершится. Если поменял что-то в шаблонах
(`scripts/templates/*`) — `git pull` + перезапуск скрипта подхватит изменения.

### Тюнинг (env vars)

```bash
OPENCLAW_DIR=/opt/openclaw                    # где клон openclaw
OPENCLAW_CONFIG_DIR=/root/.openclaw           # где openclaw.json
OPENCLAW_EXTRAS_DIR=/etc/openclaw             # стабильные mount-источники
OPENCLAW_NGINX_AUTH_USER=admin                # имя для basic auth
OPENCLAW_NGINX_SITE_CONF=/etc/nginx/...       # default openclaw-ssl.conf
OPENCLAW_GIT_USER=openclaw                    # author для git commit
OPENCLAW_GIT_EMAIL=openclaw@localhost         # email для git commit
```

### Что не входит и делается отдельно

- **UFW / firewall** — отдаём devops-агенту (нюансы с docker FORWARD chain).
- **`apt upgrade` / kernel** — делаешь руками с готовностью к reboot.
- **SSH key-only** — обычно дефолт от Hetzner cloud-init; проверь `sshd_config`.
- **clawhub skills audit** — `clawhub inspect <slug>` руками перед каждой установкой.
- **Сборка openclaw image** (`openclaw:local`) — по их flow в `/opt/openclaw`.

---

## Перенос на новый сервер (Ubuntu или Windows Git Bash)

### 1. Prerequisites (руками, один раз)
```bash
# Node 20+ (nvm на Ubuntu, или apt):
node --version   # проверка

# Global CLI:
npm i -g @anthropic-ai/claude-code openclaw

# OAuth: откроет браузер, сохранит токен в keychain + даст кусок для .credentials.json
claude setup-token
```

### 2. Clone + конфиг
```bash
git clone https://github.com/<owner>/orchestrator-project ~/orchestrator-project
cd ~/orchestrator-project

cp .env.example .env                                # заполни свои токены
cp scripts/config.env.example scripts/config.env    # пути — обычно можно оставить по умолчанию
```

### 3. Секреты (руками, в `~/.openclaw/secrets/`)

```bash
mkdir -p ~/.openclaw/secrets

# (GitHub-токены НЕ нужны — проекты живут в локальном git без remote.)

# Trello (получи ключ/токен на https://trello.com/power-ups/admin)
echo "trello-key"   > ~/.openclaw/secrets/trello_key
echo "trello-token" > ~/.openclaw/secrets/trello_token
echo "board-id"     > ~/.openclaw/secrets/trello_board_id

# Trello списки — IDs колонок твоей доски
cat > ~/.openclaw/secrets/trello_lists.env <<EOF
TRELLO_KEY=$(cat ~/.openclaw/secrets/trello_key)
TRELLO_TOKEN=$(cat ~/.openclaw/secrets/trello_token)
TRELLO_BOARD_ID=$(cat ~/.openclaw/secrets/trello_board_id)
TRELLO_LIST_BACKLOG=xxxxxxxxxxxxxxxxxxxxxxxx
TRELLO_LIST_BACKEND=xxxxxxxxxxxxxxxxxxxxxxxx
TRELLO_LIST_FRONTEND=xxxxxxxxxxxxxxxxxxxxxxxx
TRELLO_LIST_TESTING=xxxxxxxxxxxxxxxxxxxxxxxx
TRELLO_LIST_DEVOPS=xxxxxxxxxxxxxxxxxxxxxxxx
TRELLO_LIST_DONE=xxxxxxxxxxxxxxxxxxxxxxxx
EOF
```

**Как узнать list_id:**
```bash
source ~/.openclaw/secrets/trello_lists.env
curl -sS "https://api.trello.com/1/boards/$TRELLO_BOARD_ID/lists?key=$TRELLO_KEY&token=$TRELLO_TOKEN" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>JSON.parse(d).forEach(l=>console.log(l.id, l.name)))"
```

### 4. Bootstrap
```bash
bash scripts/install.sh
```
Скрипт сам:
- Сделает `openclaw onboard` если нужно
- Скопирует subagent defs → `~/.claude/agents/`
- Скопирует main workspace (AGENTS/IDENTITY/USER/TOOLS/SOUL) → `~/.openclaw/workspace/`
- Создаст `~/.claude/.credentials.json` (попросит токен если не нашёл)
- Создаст `~/.claude/settings.json`
- Mirror subagent defs в `~/.openclaw/workspaces/` через `sync-agents.sh`

### 5. One-time auth для openclaw (TTY required)
```bash
openclaw models auth login --provider anthropic --method cli --set-default
```
Создаст профиль `anthropic:claude-cli` в `~/.openclaw/agents/main/agent/auth-profiles.json`.

### 6. Start
```bash
bash scripts/start-gateway.sh
# gateway на ws://127.0.0.1:18789
# UI на http://127.0.0.1:18789/
```

### 7. Верификация
- `openclaw doctor` — всё зелёное?
- `openclaw agents list` — только `main`?
- В UI URL: `http://<host>:18789/chat?session=agent:main:work`
- Написать: `кто ты?` — должен ответить как Manager 🎯
- Написать: `новый проект test1. задача: минимальный /health endpoint` — pipeline должен пройти

## Персонализация после install

- `~/.openclaw/workspace/USER.md` — заполни под конкретного человека (Name, Timezone, OS, стиль общения)
- `~/.openclaw/workspace/IDENTITY.md` — default Manager 🎯, можешь поменять
- `~/.openclaw/workspace/TOOLS.md` — местные особенности: пути, helpers, специфика машины

## Что НЕ переносится

Runtime state (пересоздаётся сам):
- `~/.claude/teams/<project>/`
- `~/.claude/tasks/<project>/`
- `~/.openclaw/agents/main/sessions/`
- `~/.openclaw/gateway.log`

Per-machine secrets — копируй отдельно (они в gitignore):
- `~/.openclaw/secrets/*`
- `~/.claude/.credentials.json` (или получай новый через `claude setup-token`)

## Известные проблемы на сервере

- **`rate_limit_error`** на параллельном спавне 5 teammate'ов — Anthropic throttle даже на Max plan. Fix (roadmap): spawn sequential в AGENTS.md.
- **Bonjour спам** — отключается через `OPENCLAW_DISABLE_BONJOUR=1` (уже в `start-gateway.sh`).
- **OpenClaw UI session routing** — URL `?session=agent:<agentId>:<name>` — первое должно быть **agentId из openclaw.json**, не roleчем. Для main это `main`.
- **Windows DPAPI и child-процессы** — на Linux-сервере этой проблемы нет, работает через `.credentials.json` напрямую.

## Ссылки

- `README.md` — обзор архитектуры
- `agents/main-AGENTS.md` — workflow менеджера (что он делает на каждом шаге)
- `agents/tl.md` — роль техлида
- `agents/workspace-defaults/*.md` — seed-шаблоны soul-файлов
