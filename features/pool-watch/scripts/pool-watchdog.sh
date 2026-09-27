#!/bin/sh
# Сторож шлюза (watchdog). Пути к шлюзу - в pool/env.sh (пишет tools/features.sh). Пустой вывод = тишина.
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/pool/env.sh"
exec sh "$D/pool/cliproxy-watchdog.sh"
