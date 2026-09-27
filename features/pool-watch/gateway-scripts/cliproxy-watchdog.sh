#!/bin/sh
# Сторож шлюза подписок (CLIProxyAPI). Для задачи расписания без ИИ: пустой вывод = тишина.
# Env: CLIPROXY_URL (по умолчанию http://127.0.0.1:8317), HERMES_HOME (корень Hermes, где лежит cliproxy/)
# Поднимает тем же способом, каким шлюз был установлен (tools/pool-install.sh): s6, systemd или фоном.
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
URL="${CLIPROXY_URL:-http://127.0.0.1:8317}/healthz"

if curl -sf -m 5 "$URL" >/dev/null 2>&1; then
  exit 0
fi

GW="$HERMES_HOME/cliproxy"
if [ -d /run/service ] && [ -d "$HERMES_HOME/s6-services/cliproxy" ]; then
  # s6: после пересоздания контейнера /run пустой - вернуть службу
  [ -d /run/service/cliproxy ] || cp -r "$HERMES_HOME/s6-services/cliproxy" /run/service/cliproxy 2>/dev/null
  /command/s6-svscanctl -a /run/service >/dev/null 2>&1
elif command -v systemctl >/dev/null 2>&1 && systemctl --user cat cliproxy >/dev/null 2>&1; then
  systemctl --user restart cliproxy >/dev/null 2>&1
elif [ -x "$GW/cli-proxy-api" ]; then
  mkdir -p "$GW/logs"
  (cd "$GW" && exec setsid nohup ./cli-proxy-api --config config.yaml --local-model </dev/null >> logs/nohup.log 2>&1) </dev/null >/dev/null 2>&1 &
fi
sleep 5

if curl -sf -m 5 "$URL" >/dev/null 2>&1; then
  printf '⚠️ Шлюз подписок падал и был автоматически перезапущен.\n'
else
  printf '🚨 Шлюз подписок не отвечает, автозапуск не помог. Скажи помощнику «проверь шлюз подписок».\n'
fi
exit 0
