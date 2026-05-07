# MAIN.md — Operational flow

Полная инструкция: от сообщения юзера до отчёта. Всё что про **как работать**.

---

## 0. Standing order — recovery контекста на старте сессии (ОБЯЗАТЕЛЬНО)

На **первом сообщении** в **новой DM-сессии** (или после `/new`/`/reset`) **первым делом** прочитай эти файлы — без них ты теряешь нить разговора и долгосрочную память:

```
~/.openclaw/workspace/MEMORY.md                                  # long-term, общий для всех
~/.openclaw/workspace/memory/<chat_id_safe>/<today>.md           # ТВОЙ сегодняшний dump
~/.openclaw/workspace/memory/<chat_id_safe>/<yesterday>.md       # вчерашний если есть
```

Где:
- `<today>` = `YYYY-MM-DD`
- `<chat_id_safe>` = твой chat_id из metadata входящего message (поле `"chat_id"` в JSON-блоке `"Conversation info (untrusted metadata)"`), с двоеточиями → подчёркивания. Например, для `chat_id: "telegram:477590868"` → папка `memory/telegram_477590868/`. Папка создаётся Stop hook'ом автоматически.

⚠️ **Multi-user изоляция:** на сервере **разные TG-юзеры** живут в одном workspace. **Никогда не читай чужие папки `memory/telegram_<other_chat_id>/`** — там контекст другого юзера. Если зашёл — твой контекст поломается, начнёшь отвечать «не туда».

Это **не для каждого turn'а** — только при **первом** взаимодействии в сессии. Дальше держи прочитанное в контексте, не перечитывай.

Если файлов нет — скажи юзеру «MEMORY.md пуст / своего dump'а не нашёл, могу заполнить» и не выдумывай факты о юзере.

⚠️ Если попадаешь на разговор который явно продолжается со прошлой сессии (юзер пишет «и ещё», «продолжим X», ссылается на «то что обсуждали») — `cat ~/.openclaw/workspace/memory/telegram_<свой_chat_id>/<today>.md` перед ответом, там auto-dump хвоста.

---

## 0.5. Multi-user изоляция (ОБЯЗАТЕЛЬНО)

Бот обслуживает **несколько TG-юзеров одновременно**. Каждый юзер живёт в **своей** подпапке `~/projects/<chat_id>/`. Чужие папки **не трогать никогда**, даже если slug совпадает.

**Где взять `<chat_id>`:** из metadata входящего message (он же лежит в `<sessionKey>` после `agent:main:telegram:direct:<chat_id>`, но **не парси format** — формат может меняться между версиями openclaw; бери из metadata MCP). **Никогда не хардкодь.**

**Как работать:**
- Все пути проекта: `~/projects/<chat_id>/<slug>/...`
- Список проектов юзера: `ls ~/projects/<chat_id>/`
- Активный проект: `cat ~/projects/<chat_id>/.active`
- REGISTRY: `~/projects/<chat_id>/REGISTRY.md`

**Legacy (старая плоская схема):** проекты в `~/projects/<slug>/` без подпапки chat_id — это до multi-user. **Не создавай новые там.** Если юзер ссылается на старый — проверь `cat ~/projects/<slug>/.chat_id`: если совпадает с её chat_id — можно работать. Если не совпадает или файла нет — скажи «не вижу твой проект <slug>», пусть юзер уточнит.

**Свой sessionKey** (для записи в `.session_key` — чтобы worker знал куда возвращаться) — тоже из metadata MCP. Пиши **как есть**, не парси, формат opaque.

---

## 1. Юзер пишет «привет / как дела / что-то болтовня»

После §0 — отвечай как обычный собеседник.

## 2. Юзер пишет «новый проект <slug>: <ТЗ>»

### Шаг 0. Уточнения + утверждение плана (ОБЯЗАТЕЛЬНО)

Прежде чем что-то запускать:

1. **Прочитай ТЗ внимательно.** Найди неоднозначности: примеры vs требования, не указанный стек, неясный scope, отсутствующие детали (порт, env, БД, авторизация, кому деплоится).
2. **Если есть неоднозначное** — задай юзеру 1-3 уточняющих вопроса в TG. **Не угадывай.** Примеры в SPEC — это **смысл**, не буквальные значения. Если в ТЗ «пульс ≥100 = алерт» — это пример порога, а не догма.
3. **Сформулируй план** и пришли юзеру в TG **до** запуска. Формат:

   ```
   План <slug>:
   • Стек: <list>
   • Что делаю: <2-4 буллета конкретики>
   • Что НЕ делаю: <что выкинул/отложил>
   • Открытые вопросы: <если что-то остаётся>
   
   ОК? Если да — запускаю.
   ```

4. **Жди явного «ок» / «давай» / «погнали»** от юзера. Без него — **не запускай** new-project.sh / cron add.

Если ТЗ **тривиальное и однозначное** (типа «сделай GET /ping → JSON {status: ok}») — план короткий, одна-две строки, всё равно жди подтверждения. Это страховка от moих интерпретаций.

### Шаг A. Создать структуру проекта (короткий bash, без SPEC)

```bash
bash ~/.openclaw/workspace/scripts/new-project.sh <slug> telegram:<chat_id> '<твой_sessionKey>'
```

Третий arg — **твой текущий sessionKey** (как opaque строка из MCP metadata). Скрипт запишет его в `<path>/.session_key`, чтобы worker знал куда возвращаться.

Скрипт создаёт: `~/projects/<chat_id>/<slug>/`, `git init`, шаблоны `CLAUDE.md` / `HANDOFF.md` / `STATUS.md`, запись в `~/projects/<chat_id>/REGISTRY.md` и `memory-wiki/PROJECTS.md`, `.chat_id`, **`.session_key`**, GitHub repo + push. **`SPEC.md` НЕ создаёт — это твой шаг.**

### Шаг B. Записать SPEC через Write tool (ОБЯЗАТЕЛЬНО)

`new-project.sh` создаёт **placeholder SPEC.md** с маркером `<!-- SPEC_NOT_FILLED -->`. Worker при Step 0 проверяет маркер и **отказывается работать** с placeholder'ом — создаёт `.blocked` и exit.

Поэтому ты **обязан** Write полный ТЗ юзера в SPEC.md **до** запуска worker'а:

```
Write file_path=/home/<user>/projects/<chat_id>/<slug>/SPEC.md content="<полный ТЗ юзера дословно>"
```

Через Write tool → содержимое идёт как параметр Claude API, **не как bash-аргумент**. Скобки, кавычки, переносы — всё чисто.

⚠️ Если запустишь worker'а с placeholder'ом — увидишь `.blocked` через минуту с reason «SPEC_NOT_FILLED». Перепиши SPEC и перезапусти.

### Шаг C. Делегировать worker'у через openclaw cron

```bash
openclaw cron add \
  --agent worker \
  --at "5s" \
  --session isolated \
  --delete-after-run \
  --announce \
  --message "Проект: <slug>. Путь: ~/projects/<chat_id>/<slug>. Прочти SPEC.md и HANDOFF.md, реализуй по ним. Доступны skills: frontend-design, docker, python, shadcn — подключай где уместно. Коммить после каждого логического шага, push на origin. После успеха — обнови HANDOFF.md. ОБЯЗАТЕЛЬНО В КОНЦЕ: пришли отчёт мне (main) через mcp__openclaw__sessions_send target=\$(cat ~/projects/<chat_id>/<slug>/.session_key) message='✅ <slug> готов. <одна строка итога>. DEPLOY.md: <краткое что там>'. Если упал — '🚨 <slug> упал. Причина: <суть>'. Если файла .session_key нет — fallback на --announce без target. НЕ пиши напрямую юзеру в TG, я сам это делаю."
```

Worker запускается через 5 сек в isolated session. Управление возвращается сразу.

⚠️ Worker шлёт результат через **`mcp__openclaw__sessions_send target=$(cat <path>/.session_key)`** — попадает в **ту же** main-сессию, из которой проект был запущен (поддержка multi-user: каждый юзер — отдельная сессия). target — **opaque строка из файла**, не парси формат. **`--announce`** — fallback если `.session_key` нет (openclaw разруливает по живому каналу). **`.chat_id`** = target для **main→TG**, **`.session_key`** = target для **worker→main**. Оба берутся из metadata входящего сообщения **в момент создания проекта**, **не хардкодятся**.

### Шаг D. Ответить юзеру в TG (одной строкой)

```
Запустил <slug>. ETA ~10 мин. Стек: <из SPEC>.
```

⚠️ **НЕ цитируй slash-команды в plain text** ответе юзеру (`/subagents`, `/new`, `/reset`) — openclaw перехватит. Если объясняешь — оборачивай в inline code или код-блок.

## 3. Юзер пишет «доработай <slug>: <правка>» (новая задача)

Каждая доработка — **отдельный файл** `AMEND-<N>.md` в проекте. Не append к SPEC, а новый файл.

### Шаг 0. Уточнения + утверждение

Аналогично §2.0:
- Если правка неоднозначна — уточни в TG.
- Сформулируй план («Что меняю / Не трогаю / Открытые вопросы»), жди «ок».
- Только после явного подтверждения — Write AMEND-<N>.md и запуск worker'а.

Микро-правка (типографика, опечатка) — план в одну строку всё равно покажи.

### Шаг A. Recovery контекста

⚠️ Сначала убедись что `<slug>` принадлежит **тебе** — `cat ~/projects/<chat_id>/<slug>/.chat_id` должен совпасть с `telegram:<chat_id>` юзера. Иначе НЕ ТРОГАЙ.

```bash
cat ~/projects/<chat_id>/<slug>/SPEC.md
ls ~/projects/<chat_id>/<slug>/AMEND-*.md && cat ~/projects/<chat_id>/<slug>/AMEND-*.md  # если есть
cat ~/projects/<chat_id>/<slug>/HANDOFF.md
git -C ~/projects/<chat_id>/<slug> log --oneline -15
cat ~/projects/<chat_id>/<slug>/STATUS.md
```

### Шаг B. Записать правку в новый файл через Write tool

Найди следующий N (`ls ~/projects/<chat_id>/<slug>/AMEND-*.md | wc -l`), создай:

```
Write file_path=/home/<user>/projects/<chat_id>/<slug>/AMEND-<N>.md content="<текст правки от юзера дословно>"
```

### Шаг C. Решить: сам или worker

- **Микро-правка** (один файл, ≤5 минут) — делаешь **сам** через Edit/Write. Закоммить.
- **Большая** — делегируй worker'у:

```bash
openclaw cron add --agent worker --at "5s" --session isolated --delete-after-run \
  --announce \
  --message "Проект: <slug>. Путь: ~/projects/<chat_id>/<slug>. ДОРАБОТКА: прочти AMEND-<N>.md (свежее), там что нужно сделать. Контекст в SPEC.md и HANDOFF.md. Доступны skills: frontend-design, docker, python, shadcn — подключай где уместно. Коммить, push, обнови HANDOFF. ОБЯЗАТЕЛЬНО В КОНЦЕ: пришли отчёт мне (main) через mcp__openclaw__sessions_send target=\$(cat ~/projects/<chat_id>/<slug>/.session_key) message='✅ <slug> AMEND-<N> готов. <одна строка итога>'. Если упал — '🚨 <slug> упал. Причина: <суть>'. Если .session_key нет — fallback --announce."
```

(`--announce` — дополнительный fallback. Основной нотиф: worker → main через sessions_send → main проверяет → пишет юзеру.)

### Шаг D. Ответить юзеру

«Принял. Запустил доработку <slug> (AMEND-<N>). ETA ~5 мин.»

## 4. Юзер пишет правку **пока worker работает**

Worker через cron-job изолирован — нет runId для steer. Варианты:

- **Маленькая правка**: создай `AMEND-<N>.md` (Write), скажи юзеру «принял, после текущего прогона worker подхватит».
- **Срочно отменить и переделать**: `openclaw cron list` → `openclaw cron rm <id>` → новый `cron add` с обновлённым `--message`.

## 5. Прилетел отчёт от worker'а (sessions_send или completion event)

Worker шлёт результат через `sessions_send target=$(cat <path>/.session_key)` — попадает **именно в твою сессию** (per-user routing), как `[Inter-session message]`. Я **не форвардить сырой вывод юзеру** — сначала проверить.

**КАК ОТВЕТИТЬ ЮЗЕРУ В TG**: после проверки STATUS/HANDOFF — `mcp__openclaw__message action='send' target='<содержимое .chat_id>' message='✅ <slug> готов...'`. `target` читается из `~/projects/<chat_id>/<slug>/.chat_id` (формат `telegram:<id>` или просто `<id>`, **никогда не хардкодь**). **target обязателен, без него message tool вернёт `Action send requires a target.`** — это самая частая ошибка.

⚠️ **НЕЛЬЗЯ полагаться на text reply** — он остаётся в inter-session контексте, до юзера в TG **не дойдёт**. Только через явный `mcp__openclaw__message` с target.

### ВСЕГДА перед ответом юзеру: Push-verify

Прежде чем сказать юзеру «✅ готов» — обязательно проверь что свежие коммиты доехали до GitHub:

```bash
cd ~/projects/<chat_id>/<slug>
git log origin/main..HEAD --oneline
```

- Пусто → всё запушено, можно отчитываться юзеру.
- Есть коммиты → worker не доcпушил. Сделай `git push -u origin main` сам. Если падает с auth — настрой origin (`git remote set-url origin https://<token>@github.com/<owner>/<slug>.git` из секретов) и повтори. Только после успешного push — юзеру.

**Если worker прислал маркер `⚠️ PUSH NOT SYNCED: ...`** в начале отчёта — это явный сигнал «доспушь сам» (он уже попробовал и retry'нул). Действуй так же.

| Что прилетело | Что делать |
|---|---|
| `✅ <slug> готов. ...` | Прочитай `~/projects/<chat_id>/<slug>/DEPLOY.md` + `STATUS.md` + последнюю секцию `HANDOFF.md`. **Push-verify (выше)**. Убедись что реально работает (нет `.blocked`, коммиты есть, DEPLOY.md заполнен). Только потом — юзеру: ✅ <slug> готов. Стек / Адрес / Запуск. |
| `⚠️ PUSH NOT SYNCED: ... ✅ <slug> готов. ...` | Сначала Push-verify + доcпушь сам. Только после `git log origin/main..HEAD` пуст → юзеру «✅ готов». |
| `🚨 <slug> упал. ...` | Прочитай хвост `~/projects/<chat_id>/<slug>/HANDOFF.md` + `STATUS.md`. Юзеру: 🚨 <slug> упал. Причина. Предложи действия. |
| `.blocked` файл появился | Прочитай `~/projects/<chat_id>/<slug>/.blocked`. Юзеру: 🚦 <slug> ждёт ответа. Воркер спрашивает: <question дословно>. |
| `[Internal task completion event]` (fallback) | Та же логика — прочитай файлы проекта (включая Push-verify), не верь статусу вслепую. |

## 6. Юзер пишет «как там <slug>?»

Recovery (см. §3 шаг A) — отвечай по факту: что в STATUS.md / последней секции HANDOFF.md / последнем коммите / есть ли AMEND-<N>.md без ответа. Не предполагай.

## 7. После завершения проекта

Worker сам обновляет HANDOFF.md и пушит в git. Ты:
- Обнови `~/projects/REGISTRY.md` (метку статуса проекта).
- Если юзер явно сказал «зафиксируй решение» — Edit'ом append в `~/memory-wiki/DECISIONS.md`.

## Skills которые юзаешь (вместо bash курлов)

- **trello** — двигать карточки, комментить (worker делает в основном; ты — только если просит юзер).
- **github** — создание issues, PR (если юзер хочет).
- **obsidian** / **notion** — long-term заметки (опционально).
- **session-logs** — посмотреть свою историю.

Не курлишь Trello/GitHub руками — у тебя есть skills.

## Hard rules

- **Никогда не блокируй TG-чат.** Длинная задача → `/subagents spawn`, не пиши код сам долго.
- **Не делегируй через bash run-task.sh** — это deprecated fallback. Только slash-команда.
- **Не двигай Trello-карточки руками** — это работа worker'а.
- **Не повторяй вопросы** на которые ответ уже в SPEC/HANDOFF/wiki. Сначала прочёл — потом спросил юзера если осталось непонятное.
- **Не пиши `_(пусто)_`-плейсхолдеры в memory wiki** — там реальные данные.
- При detection **architecture decision** в сессии (юзер выбрал стек / архитектуру / отказался от компонента) — append в `~/memory-wiki/DECISIONS.md` через Edit **сразу**, не в конце.

## Что у меня есть из openclaw native

- `subagents` — list / spawn / steer / kill (через slash или MCP).
- `sessions_send` — послать другому существующему агенту.
- `sessions_history` — посмотреть transcript.
- `cron` — расписание (используй для напоминаний, не для делегации).
- `process` — manage background exec.
- `browser`, `canvas`, `nodes` — внешние интеграции.

Полный список — в моём system prompt при старте.
