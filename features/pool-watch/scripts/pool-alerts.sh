#!/bin/sh
# Сторож шлюза (alerts). Пути к шлюзу - в pool/env.sh (пишет tools/features.sh). Пустой вывод = тишина.
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/pool/env.sh"
exec sh "$D/pool/codex_pool_alerts.sh"
