#!/usr/bin/env bash
# Добавить человека: отдельный помощник Hermes (свой профиль, память, Telegram-бот)
# + подключение к общей базе компании на этом сервере.
#
# Запуск на сервере компании (из папки установочного набора):
#   tools/add-person.sh --id anna --name "Анна" --company "Компания" \
#       --role "владелец, управляет компанией" [--server-keeper] [--features a,b | --all-default | --no-menu]
#
#   --id             латиница, имя профиля (hermes -p anna ...)
#   --name           как зовут человека (по-русски)
#   --company        название компании (для общей базы)
#   --role           роль в компании, одной строкой
#   --server-keeper  этот помощник обслуживает сервер: сторож нагрузки, утренняя сводка,
#                    ночной бэкап. Ставить ОДНОМУ помощнику на сервере.
#   --features       сразу поставить эти фичи без вопросов (список: tools/features.sh --id x --list)
#   --all-default    поставить всё, что предложено по умолчанию, без вопросов
#   --no-menu        фичи не ставить (потом: tools/features.sh --id <id>)
#                    без этих ключей в конце откроется меню фич - вопрос по каждой
#   --source         откуда ставить набор: адрес git-репозитория или папка
#                    (по умолчанию - папка, где лежит этот скрипт)
#
# Скрипт ничего не удаляет и не перезаписывает: существующий профиль, базу и AGENTS.md
# оставляет как есть. Повторный запуск безопасен.
set -euo pipefail

ID="" NAME="" COMPANY="" ROLE="" KEEPER=0 FEATURES="" FMODE=menu
KIT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$KIT"
while [ $# -gt 0 ]; do
  case "$1" in
    --id) ID="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --company) COMPANY="$2"; shift 2;;
    --role) ROLE="$2"; shift 2;;
    --server-keeper) KEEPER=1; shift;;
    --features) FEATURES="$2"; FMODE=list; shift 2;;
    --all-default) FMODE=defaults; shift;;
    --no-menu) FMODE=none; shift;;
    --source) SOURCE="$2"; shift 2;;
    -h|--help) sed -n 2,24p "$0"; exit 0;;
    *) echo "Непонятный параметр: $1 (см. --help)"; exit 2;;
  esac
done
[ -n "$ID" ] && [ -n "$NAME" ] && [ -n "$COMPANY" ] || { echo "Нужны --id, --name и --company (см. --help)"; exit 2; }
echo "$ID" | grep -Eq '^[a-z][a-z0-9_-]{1,30}$' || { echo "--id: латиница в нижнем регистре, цифры, - и _ (например anna)"; exit 2; }
command -v hermes >/dev/null || { echo "Не найден hermes. Сначала установите Hermes (docs/01-server.md)."; exit 1; }

ROOT="${HERMES_HOME:-$HOME/.hermes}"
PROFILE="$ROOT/profiles/$ID"
BRAIN="$ROOT/company/brain"
WS="$PROFILE/workspace"
TODAY="$(date +%F)"

fill() {  # подстановка {{…}} в файл
  python3 - "$1" "$NAME" "$COMPANY" "$ROLE" "$BRAIN" "$WS/me" "$TODAY" <<'PY'
import sys, pathlib
p, name, company, role, brain, me, today = sys.argv[1:]
s = pathlib.Path(p).read_text(encoding="utf-8")
for k, v in {"{{ИМЯ}}": name, "{{КОМПАНИЯ}}": company, "{{РОЛЬ}}": role or "(уточнить при знакомстве)",
             "{{ПУТЬ_БАЗЫ}}": brain, "{{ПУТЬ_ЛИЧНОЕ}}": me, "{{ДАТА}}": today}.items():
    s = s.replace(k, v)
pathlib.Path(p).write_text(s, encoding="utf-8")
PY
}

echo "== 1. Общая база компании: $BRAIN"
if [ -f "$BRAIN/INDEX.md" ]; then
  echo "   уже есть - не трогаю"
else
  mkdir -p "$BRAIN"
  cp -Rn "$KIT/templates/brain-company/." "$BRAIN/"
  find "$BRAIN" -name '*.md' -print0 | while IFS= read -r -d '' f; do fill "$f"; done
  echo "   создана из шаблона"
fi

echo "== 2. Помощник (профиль Hermes): $ID"
if [ -d "$PROFILE" ]; then
  echo "   профиль уже есть - не переустанавливаю (обновить набор: hermes profile update $ID)"
else
  hermes profile install "$SOURCE" --name "$ID" -y
fi

echo "== 3. Личная папка и правила работы: $NAME"
mkdir -p "$WS/me/daily-plans" "$PROFILE/local"
if [ -f "$WS/AGENTS.md" ]; then
  echo "   AGENTS.md уже есть - не трогаю"
else
  cp "$KIT/templates/person/AGENTS.md" "$WS/AGENTS.md"; fill "$WS/AGENTS.md"
  echo "   AGENTS.md создан"
fi
# пути для скриптов и крон-задач (папка local/ не затирается обновлениями набора)
printf '%s\n' "$BRAIN" > "$PROFILE/local/brain-dir"
printf '%s\n' "$WS/AGENTS.md" > "$PROFILE/local/agents-file"
# рабочая папка: отсюда помощник берёт AGENTS.md (и в приложении, и в Telegram)
hermes -p "$ID" config set terminal.cwd "$WS" >/dev/null
# строка о человеке в общей базе
if ! grep -q "| $NAME |" "$BRAIN/team/people.md" 2>/dev/null; then
  python3 - "$BRAIN/team/people.md" "$NAME" "${ROLE:-уточнить}" "$ID" <<'PY'
import sys, pathlib
p, name, role, pid = sys.argv[1:]
f = pathlib.Path(p); s = f.read_text(encoding="utf-8")
row = f"| {name} | {role} | (уточнить) | {pid} |\n"
marker = "|---|---|---|---|\n"
s = s.replace(marker, marker + row, 1) if marker in s else s + row
f.write_text(s, encoding="utf-8")
PY
  printf '\n## [%s] update | добавлен помощник для %s (%s) | установка\n' "$TODAY" "$NAME" "$ID" >> "$BRAIN/log.md"
fi

echo "== 4. Фичи (что поставить помощнику)"
[ "$KEEPER" = 1 ] && printf 'yes\n' > "$PROFILE/local/server-keeper"
case "$FMODE" in
  list) bash "$KIT/tools/features.sh" --id "$ID" --on "$FEATURES" ;;
  defaults) bash "$KIT/tools/features.sh" --id "$ID" --defaults ;;
  none) echo "   пропустил. Потом: tools/features.sh --id $ID" ;;
  menu) if [ -t 0 ]; then bash "$KIT/tools/features.sh" --id "$ID"
        else echo "   не терминал - меню не открыть. Потом: tools/features.sh --id $ID"; fi ;;
esac

cat <<EOF

Готово: помощник "$ID" ($NAME).

Что осталось сделать вместе с человеком - $NAME (docs/02-person.md):
  1. Вход в подписку ChatGPT:   hermes -p $ID auth add openai-codex
     (откроется ссылка и код - человек входит в свой аккаунт ChatGPT)
  2. Свой Telegram-бот:          hermes -p $ID gateway setup
     потом в боте написать /sethome - туда пойдут утренние планы и отчёты
  3. Приложение Hermes на компьютере человека -> Settings -> Gateways -> SSH (docs/03-app.md)
  4. Первый разговор: помощник сам начнёт знакомство.
EOF
