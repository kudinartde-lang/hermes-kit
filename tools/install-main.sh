#!/usr/bin/env bash
# Поставить фичи набора в ОСНОВНОГО помощника Hermes (без отдельного профиля).
# Характер (SOUL.md), настройки (config.yaml) и существующий AGENTS.md НЕ трогает.
#
#   tools/install-main.sh --name "Мария" [--company "Компания"] [--server-keeper] [--on a,b | --list]
#
#   --list           только показать фичи и что уже стоит
#   --on a,b         поставить эти фичи (без вопросов)
#   без --on/--list  в терминале откроется меню, иначе - список
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="" COMPANY="" KEEPER=0 ON="" LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2;;
    --company) COMPANY="$2"; shift 2;;
    --server-keeper) KEEPER=1; shift;;
    --on) ON="$2"; shift 2;;
    --list) LIST=1; shift;;
    -h|--help) sed -n 2,10p "$0"; exit 0;;
    *) echo "Непонятный параметр: $1 (см. --help)"; exit 2;;
  esac
done
command -v hermes >/dev/null || { echo "Не найден hermes"; exit 1; }
ROOT="${HERMES_HOME:-$HOME/.hermes}"
[ -d "$ROOT" ] || { echo "Нет папки Hermes: $ROOT"; exit 1; }
BRAIN="$ROOT/company/brain"
TODAY="$(date +%F)"
mkdir -p "$ROOT/local"

if [ "$LIST" = 0 ]; then
  echo "== Подготовка основного помощника ($ROOT)"
  # AGENTS.md: берём существующий (рабочая папка или корень), иначе создаём из шаблона
  CWD="$(hermes config get terminal.cwd 2>/dev/null | tail -1 || true)"
  case "$CWD" in /*) ;; *) CWD="$ROOT";; esac
  AG=""
  for c in "$CWD/AGENTS.md" "$ROOT/AGENTS.md"; do [ -f "$c" ] && { AG="$c"; break; }; done
  if [ -z "$AG" ] && ! printf ',%s,' "$ON" | grep -q ',brain,'; then
    echo "   AGENTS.md нет - и не нужен (второй мозг не выбран)"
  elif [ -z "$AG" ]; then
    NAME="${NAME:-хозяин}"   # имя помощник уточнит при знакомстве и поправит в AGENTS.md
    AG="$CWD/AGENTS.md"; mkdir -p "$CWD/me/daily-plans"
    python3 - "$KIT/templates/person/AGENTS.md" "$AG" "$NAME" "${COMPANY:-(уточнить)}" "$BRAIN" "$CWD/me" "$TODAY" <<'PY'
import sys, pathlib
src, dst, name, company, brain, me, today = sys.argv[1:]
s = pathlib.Path(src).read_text(encoding="utf-8")
for k, v in {"{{ИМЯ}}": name, "{{КОМПАНИЯ}}": company, "{{РОЛЬ}}": "(уточнить при знакомстве)",
             "{{ПУТЬ_БАЗЫ}}": brain, "{{ПУТЬ_ЛИЧНОЕ}}": me, "{{ДАТА}}": today}.items():
    s = s.replace(k, v)
pathlib.Path(dst).write_text(s, encoding="utf-8")
PY
    echo "   AGENTS.md создан: $AG"
  else
    echo "   AGENTS.md уже есть - не трогаю: $AG"
  fi
  [ -n "$AG" ] && printf '%s\n' "$AG" > "$ROOT/local/agents-file"
  printf '%s\n' "$BRAIN" > "$ROOT/local/brain-dir"
  [ "$KEEPER" = 1 ] && printf 'yes\n' > "$ROOT/local/server-keeper"
fi

if [ "$LIST" = 1 ]; then exec bash "$KIT/tools/features.sh" --id main --list; fi
if [ -n "$ON" ]; then
  # второй мозг: база создаётся только если выбран brain
  if printf ',%s,' "$ON" | grep -q ',brain,' && [ ! -f "$BRAIN/INDEX.md" ]; then
    mkdir -p "$BRAIN"; cp -Rn "$KIT/templates/brain-company/." "$BRAIN/"
    find "$BRAIN" -name '*.md' -print0 | while IFS= read -r -d '' f; do
      python3 - "$f" "${NAME:-(уточнить)}" "${COMPANY:-(уточнить)}" "$TODAY" <<'PY'
import sys, pathlib
p, name, company, today = sys.argv[1:]
f = pathlib.Path(p); s = f.read_text(encoding="utf-8")
for k, v in {"{{ИМЯ}}": name, "{{КОМПАНИЯ}}": company, "{{ДАТА}}": today, "{{РОЛЬ}}": "владелец"}.items():
    s = s.replace(k, v)
f.write_text(s, encoding="utf-8")
PY
    done
    echo "   база второго мозга создана: $BRAIN"
  fi
  exec bash "$KIT/tools/features.sh" --id main --on "$ON"
fi
if [ -t 0 ]; then exec bash "$KIT/tools/features.sh" --id main; fi
exec bash "$KIT/tools/features.sh" --id main --list
