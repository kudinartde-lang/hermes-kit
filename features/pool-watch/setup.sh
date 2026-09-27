#!/usr/bin/env bash
# Фича pool-watch: сторож шлюза подписок. Кладёт скрипты в <профиль>/scripts/pool/ и пишет env.sh
# с путями (у задачи расписания HERMES_HOME = папка профиля, а шлюз лежит в корне Hermes).
set -euo pipefail
D="$PROFILE/scripts/pool"
mkdir -p "$D"
cp "$KIT/features/pool-watch/gateway-scripts/"* "$D/"
chmod +x "$D"/*.sh "$D"/*.py
cat > "$D/env.sh" <<EOF
# пишет tools/features.sh (фича pool-watch); правки пропадут при обновлении набора
export HERMES_HOME="$ROOT"
export CLIPROXY_URL="http://127.0.0.1:${CLIPROXY_PORT:-8317}"
export CLIPROXY_APPROVED_URL="file://$KIT/features/pool/gateway/cliproxy-approved.txt"
export POOL_MODELS_KNOWN="$PROFILE/local/pool-models-known.txt"
EOF
[ -f "$ROOT/cliproxy/client.key" ] || echo "     ! шлюз ещё не установлен (tools/pool-install.sh) - сторож будет сообщать, что шлюз не отвечает"
