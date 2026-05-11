#!/usr/bin/env bash
# new-project.sh — подготовка структуры нового проекта (multi-user layout).
#
# Usage: bash new-project.sh <slug> <chat_id_or_telegram_target> <session_key>
#   <slug>                       — короткое имя проекта (kebab-case)
#   <chat_id_or_telegram_target> — либо чистый chat_id (123456), либо
#                                  «telegram:123456» (формат target'а из metadata).
#                                  Для папки берётся числовая часть; полный target
#                                  записывается в .chat_id.
#   <session_key>                — sessionKey main'а (opaque, формат не парсится).
#                                  Записывается в .session_key для worker→main.
#
# Структура: ~/projects/<chat_id>/<slug>/  (per-user изоляция)
#
# Что делает:
#   1. Папка ~/projects/<chat_id>/<slug>/ + git init
#   2. CLAUDE.md, HANDOFF.md, STATUS.md, SPEC.md placeholder
#   3. .chat_id (full target), .session_key (как есть)
#   4. Запись в ~/projects/<chat_id>/REGISTRY.md и ~/memory-wiki/PROJECTS.md (Active)
#   (GitHub remote убран — только локальный git)
#   6. ~/projects/<chat_id>/.active = <slug>
#   7. SUMMARY → main потом сам пишет SPEC.md (Write tool) и запускает worker'а
#
# Что НЕ делает:
#   - НЕ создаёт SPEC.md (только placeholder). main делает это сам через Write.
#   - НЕ запускает worker'а. main делегирует через `openclaw cron add --agent worker`.

set -euo pipefail

SLUG="${1:?usage: new-project.sh <slug> <chat_id|telegram:<id>> <session_key>}"
CHAT_ID_ARG="${2:?chat_id required (telegram:<id> or just <id>)}"
SESSION_KEY="${3:?session_key required (opaque main sessionKey)}"

# Распарсить chat_id: «telegram:123456» -> «123456». Чистый ID -> как есть.
case "$CHAT_ID_ARG" in
  *:*) CHAT_ID_NUM="${CHAT_ID_ARG##*:}" ;;
  *)   CHAT_ID_NUM="$CHAT_ID_ARG" ;;
esac
[ -n "$CHAT_ID_NUM" ] || { echo "ERROR: chat_id пустой после парсинга" >&2; exit 2; }

USER_DIR="$HOME/projects/$CHAT_ID_NUM"
PROJECT_PATH="$USER_DIR/$SLUG"
SECRETS="$HOME/.openclaw/secrets"

mkdir -p "$USER_DIR"

if [ -d "$PROJECT_PATH" ]; then
  echo "ERROR: $PROJECT_PATH уже существует. Это amend, не new — Write новый AMEND-N.md в проект." >&2
  exit 1
fi

# 1. Папка + git
mkdir -p "$PROJECT_PATH"
cd "$PROJECT_PATH"
git init -b main -q
echo "# $SLUG" > README.md

# 2. CLAUDE.md (per-project context, auto-loaded Claude Code)
cat > "$PROJECT_PATH/CLAUDE.md" <<TPLEOF
# $SLUG — per-project context

## Источники правды
- **SPEC.md** — исходное ТЗ юзера.
- **AMEND-<N>.md** — доработки (по одному файлу на правку, append-only история).
- **HANDOFF.md** — журнал сессий worker'а.
- **STATUS.md** — живой статус.
- **DEPLOY.md** — стек, адреса, команды (после деплоя).
- \`git log --oneline -15\` — фактическая история коммитов.

## Recovery контекста (в начале сессии)
1. cat SPEC.md
2. ls AMEND-*.md && cat AMEND-*.md  (по очереди, свежие важнее)
3. cat HANDOFF.md
4. git log --oneline -15
5. cat STATUS.md

## Стиль коммитов
Conventional Commits на русском: \`feat:\`, \`fix:\`, \`test:\`, \`chore:\`, \`docs:\`.
TPLEOF

# 2b. SPEC.md placeholder с маркером (worker проверяет и не работает с placeholder'ом)
cat > "$PROJECT_PATH/SPEC.md" <<'SPECPLACEHOLDER'
# ТЗ — НЕ ЗАПОЛНЕНО

> ⚠️ Этот файл — placeholder. main должен **Write tool**'ом перезаписать его полным ТЗ юзера до запуска worker'а.
> Worker при Step 0 проверяет маркер ниже и откажется работать с placeholder'ом.

<!-- SPEC_NOT_FILLED -->
SPECPLACEHOLDER

# 3. HANDOFF.md initial
cat > "$PROJECT_PATH/HANDOFF.md" <<EOF
# HANDOFF — $SLUG

Append-only журнал сессий worker'а. Свежее сверху.

## Session $(date '+%Y-%m-%d %H:%M:%S') — Init

**Создан:** $(date -Iseconds)
**Статус:** ждёт SPEC.md от main.

---

EOF

# 4. STATUS.md initial
cat > "$PROJECT_PATH/STATUS.md" <<STATUSEOF
# $SLUG — Status

**Stage:** init
**Updated:** $(date -Iseconds)

## Прогресс
- [x] init (папка/git/templates)
- [ ] SPEC.md от main
- [ ] worker задача
- [ ] деплой
STATUSEOF

# 5. REGISTRY append — per-user, в ~/projects/<chat_id>/REGISTRY.md
REG="$USER_DIR/REGISTRY.md"
[ -f "$REG" ] || { echo "# Projects Registry — chat_id $CHAT_ID_NUM" > "$REG"; echo "" >> "$REG"; }
echo "- **$SLUG** ($(date '+%Y-%m-%d')) — _(SPEC pending)_" >> "$REG"

# 6. Memory wiki PROJECTS.md (общий, с пометкой owner)
WIKI_PROJECTS="$HOME/memory-wiki/PROJECTS.md"
if [ -f "$WIKI_PROJECTS" ] && [ -w "$WIKI_PROJECTS" ]; then
  PROJ_LINE="- **$SLUG** ($(date '+%Y-%m-%d')) — _(SPEC pending)_ → ~/projects/$CHAT_ID_NUM/$SLUG (owner: $CHAT_ID_NUM)"
  sed -i '/^## Active$/,/^## / { /^_(пусто)_$/d }' "$WIKI_PROJECTS"
  sed -i "/^## Active$/a $PROJ_LINE" "$WIKI_PROJECTS"
  git -C "$HOME/memory-wiki" add PROJECTS.md 2>/dev/null || true
  git -C "$HOME/memory-wiki" -c user.name="new-project.sh" -c user.email="auto@local" \
    commit -qm "wiki: + $SLUG в Active (owner: $CHAT_ID_NUM)" 2>/dev/null || true
fi

# 7. .chat_id (full target — для main→TG) и .session_key (для worker→main)
echo "$CHAT_ID_ARG" > "$PROJECT_PATH/.chat_id"
echo "$SESSION_KEY" > "$PROJECT_PATH/.session_key"
chmod 600 "$PROJECT_PATH/.session_key"

# 8. Initial commit
git add . && git commit -qm "chore: init $SLUG"

# 9. .active — per-user
echo "$SLUG" > "$USER_DIR/.active"

# 10. SUMMARY — main теперь сам пишет SPEC.md, потом запускает worker'а
echo
echo "=== SUMMARY ==="
echo "project:    $SLUG"
echo "path:       $PROJECT_PATH"
echo "owner:      $CHAT_ID_NUM"
echo "user dir:   $USER_DIR"
echo
echo "ДАЛЬШЕ (твои действия):"
echo "  1. Write tool → $PROJECT_PATH/SPEC.md (полное ТЗ юзера, без bash-quoting)"
echo "  2. (опционально) обнови $USER_DIR/REGISTRY.md и memory-wiki/PROJECTS.md заменив '_(SPEC pending)_' на превью"
echo "  3. openclaw cron add --agent worker --at \"5s\" --session isolated --delete-after-run \\"
echo "        --announce \\"
echo "        --message \"Проект: $SLUG. Путь: $PROJECT_PATH. Прочти SPEC.md и HANDOFF.md, реализуй. Доступны skills: frontend-design, docker, python, shadcn — подключай где уместно. В конце: sessions_send target=\\\$(cat $PROJECT_PATH/.session_key) message='✅ $SLUG готов. ...'\""
