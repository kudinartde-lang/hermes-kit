#!/bin/sh
# Сторож шлюза (model-watch). Пути к шлюзу - в pool/env.sh (пишет tools/features.sh). Пустой вывод = тишина.
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/pool/env.sh"
exec python3 "$D/pool/pool_model_watch.py"
