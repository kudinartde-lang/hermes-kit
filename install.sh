#!/usr/bin/env bash
# Поставить ОДНУ фичу в своего помощника Hermes - одной командой, без вопросов и настроек.
#
#   bash install.sh <фича>          например: bash install.sh limits
#   bash install.sh --list          какие фичи есть
#
# Ставит в основного помощника (тот, с кем человек уже общается). Характер (SOUL.md), модель,
# настройки и существующий AGENTS.md не трогает. Повторный запуск безопасен.
# Если нужна другая фича (например, для плана дня - второй мозг), она ставится сама.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
CAT="$KIT/features/catalog.tsv"

list() {
  echo "Фичи (bash install.sh <фича>):"
  grep -v '^#' "$CAT" | grep -v '^$' | while IFS=$'\t' read -r id who def need name desc; do
    [ -d "$KIT/features/$id" ] || continue
    printf '  %-15s %s - %s\n' "$id" "$name" "$desc"
  done
}

F="${1:-}"
case "$F" in
  ""|-h|--help|--list) list; exit 0;;
esac
[ -d "$KIT/features/$F" ] && grep -q "^$F	" "$CAT" || { echo "Нет такой фичи: $F"; list; exit 2; }
command -v hermes >/dev/null || { echo "Не найден hermes: эту команду надо запускать там, где стоит помощник Hermes"; exit 1; }

# что нужно поставить сначала (по каталогу)
need() { awk -F'\t' -v id="$1" '$1==id {print $4}' "$CAT"; }
CHAIN="$F"; n="$(need "$F")"
while [ -n "$n" ] && [ "$n" != "-" ]; do CHAIN="$n,$CHAIN"; n="$(need "$n")"; done

# шлюз подписок ставится один раз на сервер, до подключения помощника к нему
ROOT="${HERMES_HOME:-$HOME/.hermes}"
if printf ',%s,' "$CHAIN" | grep -q ',pool,' && [ ! -f "$ROOT/cliproxy/client.key" ]; then
  echo "== Шлюз подписок ещё не стоит - ставлю (5-15 минут)"
  bash "$KIT/tools/pool-install.sh"
fi

echo "== Ставлю: $CHAIN"
# основной помощник - единственный на своём сервере, поэтому он и "хранитель сервера"
bash "$KIT/tools/install-main.sh" --server-keeper --on "$CHAIN"

echo
echo "== Готово. Что дальше - $KIT/features/$F/README.md"
echo "   Чтобы помощник увидел новое: начать новый чат (/new). Если не видно - перезапустить приложение Hermes"
echo "   (или на сервере: hermes gateway restart)."
