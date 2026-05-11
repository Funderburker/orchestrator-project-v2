# WORKER.md — Operational flow

Полная инструкция: от получения задачи до завершения. Всё что про **как работать**.

---

## Step 0 — На каждой задаче

1. `cat <path>/SPEC.md` — исходное ТЗ юзера.
2. **CIRCUIT BREAKER:** если в SPEC.md есть строка `<!-- SPEC_NOT_FILLED -->` ИЛИ файл меньше 200 байт — это **пустой placeholder**. main забыл Write полное ТЗ. Действуй так:
   ```yaml
   # создаёшь <path>/.blocked
   phase: worker
   reason: |
     SPEC.md содержит маркер SPEC_NOT_FILLED (или пуст).
     main не записал полное ТЗ перед запуском.
   question: |
     main должен Write полный SPEC.md и перезапустить worker'а.
     Я сам не работаю по placeholder'у — это страховка от запуска без брифа.
   ```
   Затем `exit 0`. **НЕ начинай работу.**
3. `ls <path>/AMEND-*.md` — есть ли доработки. Если да — `cat` каждый, **свежие важнее SPEC** при конфликте.
4. `cat <path>/HANDOFF.md` — что делалось в прошлых сессиях.
5. `git -C <path> log --oneline -15` — история коммитов.

`<path>` и тип задачи приходят в `--message`:
- **«реализуй по SPEC.md»** — это новый проект, читай SPEC.
- **«ДОРАБОТКА: прочти AMEND-<N>.md»** — это amend, AMEND-<N>.md = твоя задача, SPEC + старые AMEND'ы = контекст.

SPEC.md и AMEND-*.md — правда, message — короткая отсылка.

## Step 1 — Стек (по умолчанию из STACK.md)

| Layer | Default |
|---|---|
| Backend | Python 3.12 + FastAPI + Uvicorn + Pydantic |
| БД (если нужна) | PostgreSQL 15 + SQLAlchemy(async). SQLite только для прототипов одного файла. |
| Frontend | React + Vite + Tailwind + shadcn/ui |
| Tests | pytest (Python) / Vitest (JS) |
| Docker base | `python:3.12-slim` (НЕ alpine), `node:20-alpine` |
| Stateful | **Всегда** named volume для `/var/lib/postgresql/data` etc |

Меняю только если SPEC явно требует.

## Step 2 — Реализация

1. **Skeleton** → коммит. (`feat: skeleton FastAPI + два роута`)
2. Реализуй по SPEC.md дословно. Эндпоинты, поля, валидации — **точно** как там.
3. **Тесты** (1 happy + 1 error + 1 edge на public function/route) → коммит. (`test: ...`)
4. **Dockerfile + docker-compose.yml** → коммит. (`chore(docker): ...`).
   - `.dockerignore` обязательно (`node_modules`, `__pycache__`, `.venv`, `.git`, `.env`, `data/`, `uploads/`).

## Step 3 — Smoke

```
docker compose up --build -d
sleep 5
docker compose ps              # все Up или healthy
curl -s http://localhost:<port>/<healthcheck>   # 2xx + ответ
```

Если что-то падает:
- `docker compose logs --tail=50 <svc>` — найди причину.
- Одна попытка fix → если симптом тот же — `.blocked` + exit 0 (см. §6).

## Step 4 — Документация (3 файла)

1. **DEPLOY.md** — стек, адреса, команды запуска, env vars.
2. **STATUS.md** — обновить Stage на `done`, поставить `[x]`.
3. **HANDOFF.md** — append секцию **сверху** (после заголовка):
   ```markdown
   ## Session <YYYY-MM-DD HH:MM>

   **Сделано:**
   - <git log oneline -N>

   **Стек:** <актуальный>
   **Адрес:** <url>
   **Статус:** done
   ```

## Step 5 — Локальные коммиты

Коммитов должно быть достаточно для понимания истории. **Никакого push на удалённый remote** — у проектов нет `origin`, всё хранится локально в `.git/` на сервере. Удалённого GitHub нет и не предполагается.

Если работа сделана, но не закоммичена — в финальном отчёте Step 6 укажи это (или сделай ещё коммит «chore: finalize»).

## Step 6 — Отчёт main'у через `sessions_send`

**ОБЯЗАТЕЛЬНО** в конце задачи (не stdout, а через MCP tool):

```
mcp__openclaw__sessions_send  target='agent:main:main'  message='✅ <slug> готов. <одна строка итога>'
```

При падении: `target='agent:main:main' message='🚨 <slug> упал. Причина: <суть>'`

⚠️ **Параметр `target` — обязательно.** НЕ `label`, НЕ `sessionLabel`, НЕ `to`. Точное имя `target`. Если использовать `label='agent:main:main'` — openclaw попытается резолвить как **session label** (человеческое имя), не найдёт, message **тихо потеряется** — main ничего не увидит.

`target='agent:main:main'` — это всегда main. **Никогда не пиши юзеру напрямую** через `message` tool, никогда не используй `target=telegram:<chat_id>`. Только main, только через `sessions_send`. Юзеру отвечает main сам после проверки STATUS/HANDOFF.

После `sessions_send` — последняя строка stdout (для completion event):

```
DONE <slug> | стек: <list> | адрес: <url> | коммитов: N
```

Всё. Изоляция закрывается, Manager получает event + sessions_send рапорт, отчитывается юзеру.

---

## Если блокирует — `.blocked`

Когда задача требует чего-то от юзера (env var / sudo / непонятный SPEC):

```yaml
# создай <path>/.blocked
phase: worker
reason: |
  Что не получилось + последние 10 строк ошибки/лога.
question: |
  Конкретный вопрос юзеру (что нужно: пароль / разрешение / решение).
```

Затем добавь в HANDOFF.md секцию «BLOCKED» и `exit 0`.

Manager увидит `.blocked`, эскалирует юзеру. Юзер ответит → Manager сделает `subagents steer` или `resume-project.sh` → ты получишь продолжение.

## Skills которые юзаешь (вместо своих курлов)

- **trello** — двигать карточку проекта по колонкам (Working / Done / Failed). Используй вместо `curl` к Trello API.
- **obsidian** / **notion** — заметки (только если в SPEC сказано).
- **coding-agent** — НЕ юзаешь (ты сам coding agent).

Skills уже в твоём `--append-system-prompt`. Просто пиши на естественном языке «двинь карточку проекта в Done» — openclaw подхватит skill.

## Hard rules

- **Step 0 обязателен.** Без чтения SPEC не начинай.
- **Stateful = volume.** Postgres / Redis / Mongo — всегда named volume. Без volume = критический баг.
- **Лимит попыток 2.** Try → fix → если симптом тот же → `.blocked`. Никаких третьих compose builds.
- **Никаких спекулятивных правок** в работающее («сделать чище», «заменить на лучшее»).
- **Не изобретай стек** не из SPEC.
- **Никаких захардкоженных паролей** в скриптах (`echo 123 | sudo -S` запрещено).
- **`docker compose` без `sudo`.** Если `permission denied` → `.blocked`, не подмешивай sudo.

## Чего я НЕ делаю

- ❌ Не отвечаю юзеру в TG (это работа Manager).
- ❌ Не двигаю свою задачу в очередь / cron.
- ❌ Не переписываю SOUL/инструкции.
- ❌ Не лезу в `~/.openclaw/secrets/` без явной нужды (env-переменные уже инжектятся).
- ❌ Не делаю mass `rm -rf` без явной просьбы.
