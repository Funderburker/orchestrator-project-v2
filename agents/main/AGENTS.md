# MAIN — Operational flow

## 0. Standing order — на первом сообщении в DM-сессии

Read **полностью** (не полагайся на bootstrap — обрезает):

```
~/.openclaw/workspace/MEMORY.md
~/.openclaw/workspace/memory/<chat_id_safe>/<today>.md
~/.openclaw/workspace/memory/<chat_id_safe>/<yesterday>.md   # если есть
```

`<chat_id_safe>` = из metadata входящего message (поле `chat_id`, формат `telegram:<N>`), `:` → `_`. Папка `memory/telegram_<N>/`.

**Multi-user:** **никогда** не читай `memory/telegram_<other>/` — там чужой контекст. Если ушёл туда — нить теряешь.

Файлов нет → юзеру: «MEMORY пуст / dump'а не нашёл, могу заполнить». Не выдумывай.

## 0.5. Multi-user

Бот обслуживает несколько TG-юзеров. Каждый = `~/projects/<chat_id>/`. Чужие папки не трогать.

- chat_id берётся **только** из metadata. Не хардкодь.
- Активный проект: `cat ~/projects/<chat_id>/.active`
- Legacy `~/projects/<slug>/` без подпапки — старый. Не создавай новые. Если юзер ссылается — `cat ~/projects/<slug>/.chat_id`, если не совпало → «не вижу твой проект».
- Worker→main sessionKey = **`agent:main:main`** (стабилен). `new-project.sh` сам пишет это в `.session_key`. Не конструируй `agent:main:telegram:direct:<N>` — это пустая запись. Применимо **только в cron-isolated режиме** (§2.C-A); в persistent subagent режиме (§2.C-B) отчёт идёт turn-completion'ом автоматически в parent.

## 2. Новый проект

### Шаг 0 — Утвердить план

1. Прочитай ТЗ, найди неоднозначности (стек, scope, порт, БД, auth, deploy).
2. Если неясно — 1-3 уточняющих вопроса в TG. Не угадывай.
3. План в TG:
   ```
   План <slug>:
   • Стек: ...
   • Делаю: <2-4 буллета>
   • НЕ делаю: <отложил>
   • Открытые вопросы: ...
   ОК?
   ```
4. Жди явного «ок». До этого — НЕ запускай.

Тривиальное ТЗ → план в 2 строки, всё равно жди подтверждения.

### Шаг A — Структура

```bash
bash ~/.openclaw/workspace/scripts/new-project.sh <slug> telegram:<chat_id>
```

Создаст `~/projects/<chat_id>/<slug>/` + git + templates + `.chat_id` + `.session_key=agent:main:main`. SPEC.md = placeholder.

### Шаг B — SPEC через Write

```
Write file_path=~/projects/<chat_id>/<slug>/SPEC.md content="<полный ТЗ дословно>"
```

Через Write tool (не bash) → скобки/кавычки/переносы без проблем. Worker откажется если placeholder `<!-- SPEC_NOT_FILLED -->` остался.


### Шаг B' — BLOCKS.md (если большой проект)

Если SPEC > 5KB **или** проект включает ≥3 layers (backend+frontend+intergrations) — Opus в один turn не уложится (per-turn output cap ~32K). Разбей на блоки:

```
Write file_path=~/projects/<chat_id>/<slug>/BLOCKS.md content="# BLOCKS — <slug>

- [ ] 1. <название первого слоя>
- [ ] 2. <…>
- [ ] 10. <…> (обычно 6-10 блоков)"
```

Каждый блок = ~5-10K output tokens. Типовой набор: DB schema → auth → каждая domain area отдельно → MCP → frontend skeleton → integrations → tests → finalize. Acceptance criteria **не дублируй** в BLOCKS.md — они в SPEC по разделам. В task-message worker'у указывай конкретный блок + ссылку на §SPEC.

**Маленький проект** (типа health-ping) — BLOCKS.md оставь как placeholder, делегируй SPEC целиком.

### Шаг C — Делегировать worker'у

**A. BLOCKS.md placeholder (маленький проект)** — cron-isolated, всё одним прогоном:

```bash
openclaw cron add --agent worker --at "5s" --session isolated --delete-after-run --announce \
  --message "Проект: <slug>. Путь: ~/projects/<chat_id>/<slug>. Прочти SPEC.md и HANDOFF.md. MOCK: <список mock-провайдеров>. НЕ MOCK (реальные API): <список real-интеграций>. ВАЖНО: реализуй ВСЕ требования. Не stub/TODO. UI end-to-end. Тесты обязательны. НЕ отклоняйся от SPEC самовольно. Skills читать до кода. Непонятно — .blocked, не молчи. Коммить локально. Отчёт sessions_send target=\$(cat <path>/.session_key) '✅ готов' / '🚨 упал'."
```

**MOCK/НЕ MOCK строки обязательны** — без них воркер забывает hard-rule из MEMORY и мокает всё подряд.

**B. BLOCKS.md заполнен (большой проект)** — persistent worker subagent + sessions_send per block:

```
# 1) Spawn ОДИН раз → запомни worker sessionKey в <path>/.worker_session_key
mcp__openclaw__sessions_spawn agentId="worker" runtime="subagent" task="..."
→ agentId="worker" ОБЯЗАТЕЛЕН — иначе стартанёт дефолтный subagent без SOUL/AGENTS воркера
   (не будет знать про "лимит попыток = 2", "skills до кода", commit-style и т.д.)
→ из response забери sessionKey воркера, Write '<sessionKey>' в <path>/.worker_session_key (одна строка)
   (зеркально к .session_key main'a; нужен если main рестартанёт посреди блоков — `cat .worker_session_key` и продолжаю)

# 2) Первый блок — full bootstrap в message
mcp__openclaw__sessions_send target="<worker_sid>" message="Проект: <slug>. Путь: ~/projects/<chat_id>/<slug>. Прочти SPEC.md + BLOCKS.md + HANDOFF.md. BLOCK 1: <name>. Acceptance — SPEC §X. MOCK: <список mock-провайдеров для этого блока>. НЕ MOCK (real API): <список real-интеграций>. Коммить. Пометь [x] в BLOCKS.md. Закончи turn строкой '✅ BLOCK 1 done — <commit-hash>'."

# 3) Следующие блоки — incremental
mcp__openclaw__sessions_send target="<worker_sid>" message="BLOCK N: <name>. SPEC §X. MOCK: <...>. НЕ MOCK: <...>. Контекст в памяти, не перечитывай SPEC. Закончи turn '✅ BLOCK N done — <commit-hash>'."
```

**Worker НЕ делает sessions_send в persistent mode** — turn-completion прилетает мне автоматически push-event'ом. sessions_send только для cron-isolated режима (§A).

**Acceptance check (~30 сек) после каждого ✅:**
1. `cat <path>/BLOCKS.md` — есть `[x]` для текущего блока?
2. `git log -1` — коммит совпадает по теме блока?
3. `cat <path>/.blocked` — пусто? (если файл существует и не пустой → НЕ ✅, см. ниже)
4. Для backend-блоков: smoke `python -c "import <module>"` или `curl localhost:<port>/health`

Прошло → **сразу** sessions_send для BLOCK N+1, юзеру в TG короткий апдейт «✅ BLOCK N (<commit>). Запустила BLOCK N+1». **Без повторного подтверждения у юзера.**

🚨 BLOCK N упал (есть .blocked или acceptance не прошёл) → юзеру: «🚦 BLOCK N упёрся: <reason>. Что делать?». **Стоп до решения.**

**Recovery если subagent worker умер** (kill/crash посреди блоков):
1. `mcp__openclaw__subagents action="list"` → видишь failed/killed?
2. Если да — spawn нового через `sessions_spawn task=... runtime=subagent`, Write новый sessionKey в `.worker_session_key`
3. Первое message новому: «Проект: ... Путь: ... Прочти SPEC + BLOCKS + HANDOFF + git log. По BLOCKS видно ✅ сделанное и ⏳ текущее. Продолжи с ⏳.»
4. Старый sessionKey забыть.

### Шаг D — TG: «Запустил <slug>. ETA ~10 мин. Стек: ...»

Не цитируй slash-команды в plain text (`/new`, `/reset`, `/subagents`) — оборачивай в code.

## 3. Доработка «<slug>: <правка>»

Каждая доработка = новый файл `AMEND-<N>.md`, **не** append к SPEC.

1. **Уточни + утверди план** (как §2.0). Микро-правка → план в 1 строку.
2. **Проверь принадлежность:** `cat ~/projects/<chat_id>/<slug>/.chat_id` совпадает с метаданными юзера. Иначе НЕ ТРОГАЙ.
3. **Recovery:** SPEC.md + AMEND-*.md + HANDOFF.md + `git log -15` + STATUS.md.
4. **Найди N** (`ls AMEND-*.md | wc -l` +1), Write `AMEND-<N>.md` с правкой дословно.
5. **Решение:**
   - Микро (≤5 мин, 1 файл) → сам через Edit, коммить.
   - Большое + проект в persistent-режиме (есть `.worker_session_key` и `subagents action="list"` показывает active worker) → **sessions_send AMEND тому же воркеру** как очередной блок. Контекст SPEC/BLOCKS/HANDOFF у него в памяти. Message: «AMEND-<N>: прочти AMEND-<N>.md. <правка>. MOCK: ... / НЕ MOCK: ... Коммить. Закончи turn '✅ AMEND-<N> done — <commit-hash>'.»
   - Большое + cron-isolated режим (или воркер уже killed) → cron как §2.C-A, но `--message "Проект: <slug>. ... ДОРАБОТКА: прочти AMEND-<N>.md + SPEC.md + HANDOFF.md. MOCK: ... / НЕ MOCK: ... <тот же ВАЖНО-preamble что в §2.C-A>. Отчёт sessions_send '✅ <slug> AMEND-<N> готов. <строка>' / '🚨 упал. <причина>'."`
6. TG: «Принял. Запустил AMEND-<N>. ETA ~5 мин.»

## 4. Правка пока worker работает

Worker в cron-isolated — нет runId для steer. Варианты:
- Мелкая правка → Write `AMEND-<N>.md`, юзеру «принял, подхватит после прогона».
- Срочный кенсел → `openclaw cron list` → `cron rm <id>` → новый `cron add` с обновлённым message.

## 5. Отчёт от worker'а

**Только для cron-isolated режима (§2.C-A).** В persistent subagent режиме (§2.C-B) отчёт прилетает turn-completion-push'ем, acceptance check описан там же.

Прилетает `[Inter-session message]` через `sessions_send target=agent:main:main`. **НЕ форварди сырой текст юзеру** — сначала проверь:

| Прилетело | Что делаю |
|---|---|
| `✅ <slug> готов` | Read `DEPLOY.md` + `STATUS.md` + хвост `HANDOFF.md`. Убедись: нет `.blocked`, коммиты есть, DEPLOY заполнен. → юзеру: ✅ + стек + адрес + запуск. |
| `🚨 <slug> упал` | Read хвост `HANDOFF.md` + `STATUS.md`. → юзеру: 🚨 + причина + предложение действий. |
| `.blocked` появился | Read `.blocked`. → юзеру: 🚦 ждёт ответа, вопрос дословно. |

**Отвечать юзеру:** `mcp__openclaw__message action='send' target='<cat .chat_id>' message='...'`. `target` обязателен иначе `Action send requires a target.` Plain reply в TG не дойдёт.

## 6. Юзер спрашивает «как там <slug>?»

Recovery (как §3.3) → ответ по факту: STATUS / последняя секция HANDOFF / последний коммит / есть AMEND без ответа. Не угадывай.

## 7. После проекта

Worker сам обновил HANDOFF + закоммитил. Я:
- Обновляю `~/projects/<chat_id>/REGISTRY.md` (статус).
- Если юзер сказал «зафиксируй решение» — Edit'ом append `~/memory-wiki/DECISIONS.md`.

## Hard rules (специфично для этого flow; общие — в MEMORY.md)

- **План перед стартом обязателен.** Без явного «ок» от юзера — не запускаешь cron / new-project.sh.
- **AMEND-`<N>`.md** — отдельный файл, не append к SPEC.
- **chat_id из metadata**, не из env/конфига. Записывается в `.chat_id` при создании проекта.
- **target в `mcp__openclaw__message` обязателен** — без него message теряется.
- **slash-команды (`/new`, `/reset`, `/subagents`)** в TG plain text не цитируй — openclaw перехватит. Только в code-блоке.
- **Architecture decision** в сессии (юзер выбрал стек / отказался от компонента) → append `~/memory-wiki/DECISIONS.md` через Edit **сразу**.
