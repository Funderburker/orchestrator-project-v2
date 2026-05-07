# Mission Control + OpenClaw на Ubuntu — пошаговая инструкция

## Что ставим
- **Mission Control** (MC) — веб-панель для мониторинга и управления агентами
- **OpenClaw** — gateway для агентов
- **Kie.ai proxy** — прокси для API вызовов (если нет ANTHROPIC_API_KEY)

## 1. Установка зависимостей

```bash
# Node.js 22+
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs git python3 python3-pip build-essential

# pnpm
corepack enable
corepack prepare pnpm@latest --activate

# OpenClaw
npm install -g openclaw@latest
openclaw --version  # должно быть 2026.4.12+
```

## 2. Клонировать Mission Control

```bash
cd ~
git clone --depth 1 https://github.com/openclaw/mission-control.git mc
cd mc
pnpm install
pnpm build
```

### Если TS ошибка при build:
```bash
# Пофиксить formatter type errors:
sed -i "s/formatter={(v: number[^)]*)/formatter={(v: any, name?: any)/g" src/components/panels/system-monitor-panel.tsx
pnpm build
```

### Подготовить standalone:
```bash
cp -r .next/static .next/standalone/.next/
cp -r public .next/standalone/
cp src/lib/schema.sql .next/standalone/src/lib/
```

## 3. Настроить OpenClaw

```bash
# Onboard (без API ключа — skip auth)
openclaw onboard --non-interactive --accept-risk --auth-choice skip --skip-health

# Или с Kie.ai proxy:
openclaw onboard --non-interactive --accept-risk \
  --auth-choice custom-api-key \
  --custom-api-key "<YOUR_KIE_API_KEY>" \
  --custom-base-url "http://127.0.0.1:4100" \
  --custom-model-id "claude-sonnet-4-20250514" \
  --skip-health

# Создать агентов:
openclaw agents add backend --non-interactive --workspace ~/.openclaw/workspaces/backend --model anthropic/claude-sonnet-4-20250514
openclaw agents add frontend --non-interactive --workspace ~/.openclaw/workspaces/frontend --model anthropic/claude-sonnet-4-20250514
openclaw agents add tester --non-interactive --workspace ~/.openclaw/workspaces/tester --model anthropic/claude-sonnet-4-20250514
```

## 4. Запустить Kie.ai proxy (опционально)

Скопировать `proxy/server.py` на Ubuntu и:
```bash
pip3 install fastapi uvicorn httpx python-dotenv
KIE_API_KEY=<YOUR_KIE_API_KEY> KIE_BASE_URL=https://api.kie.ai/claude python3 proxy/server.py &
# Работает на http://localhost:4100
```

Важно: в `proxy/server.py` должен быть:
- Route `/chat/completions` (без /v1/) — OpenClaw шлёт туда
- Model name mapping: `claude-sonnet-4-20250514` → `claude-sonnet-4-6`
- tool_calls ID формат: `call_XXXX`
- content=null когда есть tool_calls

## 5. Запустить Gateway

```bash
# Узнать токен из конфига:
node -e "console.log(require('$HOME/.openclaw/openclaw.json').gateway.auth.token)"

# Запустить:
openclaw gateway run --allow-unconfigured --auth token &
# Работает на ws://127.0.0.1:18789
```

## 6. Запустить Mission Control

```bash
cd ~/mc/.next/standalone

# Токен должен совпадать с тем что в ~/.openclaw/openclaw.json → gateway.auth.token
GATEWAY_TOKEN=$(node -e "console.log(require('$HOME/.openclaw/openclaw.json').gateway?.auth?.token || '')")

MC_CLAUDE_HOME=~/.claude \
OPENCLAW_GATEWAY_HOST=127.0.0.1 \
OPENCLAW_GATEWAY_PORT=18789 \
OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN \
PORT=3100 \
node server.js &

# MC на http://localhost:3100
# Первый раз — /setup, пароль: <MC_ADMIN_PASSWORD>
```

## 7. Проверить

- http://localhost:3100 — MC dashboard
- GW статус наверху должен быть зелёный ("GW Подключено")
- Agents — видны агенты из openclaw.json
- Chat — видны Claude Code сессии (если ~/.claude смонтирован)
- Tasks — kanban доска

## Ключевые переменные

| Переменная | Значение | Где |
|---|---|---|
| `OPENCLAW_GATEWAY_HOST` | 127.0.0.1 | MC env |
| `OPENCLAW_GATEWAY_PORT` | 18789 | MC env |
| `OPENCLAW_GATEWAY_TOKEN` | из ~/.openclaw/openclaw.json | MC env |
| `MC_CLAUDE_HOME` | ~/.claude | MC env |
| `PORT` | 3100 | MC env |
| `KIE_API_KEY` | <YOUR_KIE_API_KEY> | Proxy env |

## ГЛАВНЫЙ ЗАВТЫК (потратили весь день)
**Токен gateway должен совпадать!** MC берёт токен из env `OPENCLAW_GATEWAY_TOKEN`, а gateway — из `~/.openclaw/openclaw.json → gateway.auth.token`. Если они разные — "gateway token mismatch", "too many failed auth attempts". После слишком многих неудачных попыток gateway блокирует MC — нужен рестарт gateway.

Правильный способ:
```bash
# Считать токен из конфига и передать MC:
TOKEN=$(node -e "console.log(require('$HOME/.openclaw/openclaw.json').gateway?.auth?.token || '')")
OPENCLAW_GATEWAY_TOKEN=$TOKEN node server.js
```

## Известные проблемы
1. **"No reply from agent"** — OpenClaw ACPX write tool не создаёт файлы, модель отвечает но агент считает что нет ответа
2. **Claude Code auth** — для чата (send prompt) нужен `claude login` на Ubuntu
3. **Agent Teams** — работают через Claude Code подписку (OAuth), не через OpenClaw
4. **Model name mapping** — Kie.ai не понимает `claude-sonnet-4-20250514`, нужен `claude-sonnet-4-6`
5. **Context window** — по умолчанию 16000, нужно поставить 200000 в openclaw.json → models.providers.*.models.*.contextWindow

## Пароли
- MC admin: `<MC_ADMIN_PASSWORD>`
- MC .env password: `<MC_ENV_PASSWORD>`
- Kie.ai API key: `<YOUR_KIE_API_KEY>`
