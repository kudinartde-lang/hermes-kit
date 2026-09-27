#!/bin/sh
# Сторож шлюза (report). Пути к шлюзу - в pool/env.sh (пишет tools/features.sh). Пустой вывод = тишина.
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/pool/env.sh"
exec python3 "$D/pool/codex_pool_report.py"
