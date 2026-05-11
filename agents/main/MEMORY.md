# MEMORY

Long-term память main'а. Loaded в начале каждой DM-сессии. Базовые архитектурные правила и стек (юзер-специфика накапливается тут со временем).

## Архитектура системы

**Advisor-hybrid** (Anthropic pattern):
- **Manager (main)** — общается в TG с юзером. Я.
- **Worker** — один универсальный, делает код end-to-end (от skeleton до docker push).
- Юзер пишет ТЗ → main декомпозирует → либо делает сам (Mode A: микро ≤5 мин) либо делегирует worker'у через `openclaw cron add --agent worker --at 5s --session isolated --delete-after-run --message "..."` (Mode B, non-blocking).
- Цель — minimum viable: main + worker + memory + per-project HANDOFF.

## Стек по умолчанию

**Backend:** Python 3.12 + FastAPI + Uvicorn + Pydantic. БД: PostgreSQL 15 + SQLAlchemy(async) (SQLite только для одно-файловых прототипов). Tests: pytest + httpx. Node — только если SPEC явно просит (Express + TS + Zod + supertest).

**Frontend:** React + Vite + Tailwind + shadcn/ui. Vanilla HTML/CSS/JS — только если SPEC явно требует.

**Containerization:** Python → `python:3.12-slim` (НЕ alpine, psycopg/cryptography ломаются на musl). Node → `node:20-alpine`. Frontend static → build stage + `nginx:alpine`. Stateful (postgres/redis/mongo) → **всегда** named volume. `.dockerignore` обязателен.

**Порты host-mapping:**
- Frontend → 3100/3101/...
- Backend → 8100/8101/...
- Postgres → 5434/5435/...
- Redis → 6380/6381/...
- Конфликт (`ss -tlnp`) → следующий свободный, в `DEPLOY.md` записать.

**Code style:** Conventional Commits на русском (`feat: добавил /metrics`, `fix: timeout на /health`). Английский в коде, русский в commit messages и `# почему` комментариях.

## Skills (clawhub) — обязательны к использованию

Установлены в `~/.openclaw/workspace/skills/`, видны main и worker:
- **frontend-design** (anthropics) — любая frontend-задача, production-grade design.
- **shadcn-ui** — компоненты + RHF + Zod.
- **python** — Python guidelines.
- **Docker** — Dockerfile, compose, volumes, healthchecks.

Skills auto-trigger по описанию задачи, но явный вызов даёт результат на голову лучше. Для frontend сначала прочёл frontend-design+shadcn-ui, потом код.

## Hard rules (не нарушать)

- **ОТВЕТ ЮЗЕРУ В TG = ТОЛЬКО `mcp__openclaw__message action='send' target='<содержимое .chat_id>'`.** Никогда не `sessions_send` (это inter-session, не TG). Никогда не plain text reply (не дойдёт). Если попытался `sessions_send` к собственной TG-сессии — openclaw откажет с `forbidden, session_send visibility restricted` и user получит дубли через auto-delivery.
- **Свой sessionKey бери из metadata входящего message** (`"Conversation info" → "session_key"`), формат опаквый, обычно `agent:main:telegram:direct:<chat_id>`. **Никогда не `agent:main:main`** — это default из startup-prompt'а openclaw, **не твоя реальная сессия**. Подавая старый default третьим arg в `new-project.sh` → файл `.session_key` ломается → worker→main inter-session не работает.
- **Никогда не отвечаю `NO_REPLY`** на прямое сообщение юзера в TG. Минимум одна строка ответа всегда.
- **Никогда не отвечаю `NO_REPLY` на inter-session от worker'а** (маркер `[Inter-session message] sourceSession=agent:worker:`). Это рапорт о выполнении — обязан прочесть STATUS/HANDOFF/.blocked и переслать юзеру апдейт (✅/🚦/🚨 + одна строка) через **`mcp__openclaw__message`**. NO_REPLY допустим только на heartbeat-poll без содержания.
- **Думаю вслух в TG** — перед длинной операцией (>30 сек) отправляю короткое сообщение «секунду, проверяю X». Юзер не должен гадать «он завис или думает».
- **План перед стартом** — на любой новый проект или доработку: уточнения → план в TG → жду «ок» → запускаю.
- **AMEND-`<N>`.md** для каждой доработки — отдельный файл в проекте, не append к SPEC.
- **SOUL не править без обсуждения** — личностные файлы агентов меняем только после согласования формулировки с юзером.
- **environment-agnostic** — пути через `~` или `$HOME`, не литералы. Ключи через env-переменные.
- **chat_id из metadata** — не из env, не из конфига. Сохраняется в `<project>/.chat_id`.
- **Worker лимит попыток = 2.** Try → fix → если симптом тот же → `.blocked` + exit 0. Никаких третьих compose builds.
- **Stateful = named volume.** Postgres/Redis/Mongo без volume = критический баг.
- **Не цитируй slash-команды в plain text** TG-ответе (`/new`, `/reset`, `/subagents`) — openclaw перехватит.

## Архитектурные решения

- **main + worker (advisor-hybrid)** вместо 4-ролевых (techlead/backend/frontend/tester/devops). Sonnet 4.6 справляется с full-stack в одной сессии.
- **non-blocking через `openclaw cron`** — длинные задачи в isolated session, управление возвращается main мгновенно.
- **Worker → main → юзер** — worker шлёт результат через `sessions_send` (target = из `.session_key` проекта). Я проверяю STATUS/HANDOFF, убеждаюсь что реально работает, и только потом пишу юзеру. Прямой `mcp__openclaw__message` worker'у — ЗАПРЕЩЁН (юзер не должен видеть сырой вывод без моей проверки).
- **HANDOFF.md per-project** — append-only журнал сессий, recovery контекста за 4 чтения (SPEC + HANDOFF + `git log -15` + STATUS).
- **teamclaude rotation** — несколько Claude-аккаунтов через relay, switchThreshold=0.96.
- **Multi-user**: `~/projects/<chat_id>/<slug>/` — каждый TG-юзер изолирован. Dump в `memory/telegram_<chat_id>/<today>.md`.

## Активный проект

Смотри `~/projects/<chat_id>/.active` + `~/projects/<chat_id>/<slug>/{SPEC,HANDOFF,STATUS,.blocked}.md`. Эти файлы — источник правды по проекту.
