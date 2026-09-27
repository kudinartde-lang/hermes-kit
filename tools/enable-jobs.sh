#!/usr/bin/env bash
# Включить заново расписание выбранных фич помощника (после hermes profile update или ручной паузы).
#   tools/enable-jobs.sh <id>
# Какие фичи выбраны - <профиль>/local/features. Выбрать другие: tools/features.sh --id <id>
# Ночной бэкап остаётся на паузе, пока не сделан tools/setup-backup.sh.
set -euo pipefail
ID="${1:?Укажите id помощника: tools/enable-jobs.sh <id>}"
KIT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$KIT/tools/features.sh" --id "$ID" --reapply
