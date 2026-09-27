#!/usr/bin/env bash
# Обновить набор у всех помощников этого сервера.
#   cd ~/hermes-kit && git pull && tools/update-all.sh
# 1) основа (SOUL.md, настройки) - hermes profile update;
# 2) выбранные фичи каждого человека - заново из свежего набора (tools/features.sh --reapply).
# Память, переписки, ключи, workspace/, local/, общую базу и выбор фич не трогает.
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${HERMES_ROOT:-${HERMES_HOME:-$HOME/.hermes}}"
n=0
for p in "$ROOT"/profiles/*/; do
  id="$(basename "$p")"
  [ -f "$p/local/brain-dir" ] || continue   # только помощники, поставленные add-person.sh
  echo "== $id"
  hermes profile update "$id" -y | tail -1
  bash "$KIT/tools/features.sh" --id "$id" --reapply | grep -E '^\s+(==|\+|-|!)' || true
  n=$((n+1))
done
[ "$n" -gt 0 ] || { echo "Помощников из набора не найдено в $ROOT/profiles"; exit 1; }
echo
echo "Обновлено помощников: $n. Перезапуск, чтобы изменения подхватились:"
echo "  hermes gateway restart"
echo "Шлюз подписок обновляется отдельно (если в наборе новая одобренная версия): tools/pool-update.sh"
