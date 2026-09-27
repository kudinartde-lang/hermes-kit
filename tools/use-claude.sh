#!/usr/bin/env bash
# Переключить помощника с подписки ChatGPT на подписку Claude (Anthropic).
# Запуск на сервере после add-person.sh:
#   tools/use-claude.sh --id anna
# Потом вход в подписку: hermes -p anna auth add anthropic --type oauth
set -euo pipefail
ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --id) ID="$2"; shift 2;;
    -h|--help) sed -n 2,6p "$0"; exit 0;;
    *) echo "Непонятный параметр: $1"; exit 2;;
  esac
done
[ -n "$ID" ] || { echo "Нужен --id (например --id anna)"; exit 2; }
command -v hermes >/dev/null || { echo "Не найден hermes"; exit 1; }

STRONG="claude-fable-5"      # стратегии и важные решения
MAIN="claude-opus-5"       # обычная работа
LIGHT="claude-sonnet-5"      # служебное и простое

set_() { hermes -p "$ID" config set "$1" "$2" >/dev/null; }

set_ model.provider anthropic
set_ model.default "$MAIN"
for a in strong:$STRONG main:$MAIN light:$LIGHT; do
  set_ "model_aliases.${a%%:*}.model" "${a#*:}"
  set_ "model_aliases.${a%%:*}.provider" anthropic
done
for k in compression title_generation approval curator skills_hub mcp vision background_review goal_judge memory_query_rewrite; do
  set_ "auxiliary.$k.provider" anthropic
  set_ "auxiliary.$k.model" "$LIGHT"
done
set_ delegation.provider anthropic
set_ delegation.model "$LIGHT"

echo "Готово: помощник $ID работает на Claude."
echo "  основная - $MAIN, /model strong - $STRONG, /model light - $LIGHT"
echo "Дальше вход в подписку: hermes -p $ID auth add anthropic --type oauth"
