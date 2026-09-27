#!/usr/bin/env bash
# Обновить шлюз подписок до версии, одобренной в наборе (features/pool/gateway/cliproxy-approved.txt).
#   cd ~/hermes-kit && git pull && tools/pool-update.sh
# Собирает рядом, подменяет только если сборка прошла; старый файл остаётся как cli-proxy-api.old-<версия>.
# Не заработало - вернуть: mv cli-proxy-api.old-<версия> cli-proxy-api и перезапустить (см. ниже).
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
F="$KIT/features/pool/gateway"
ROOT="${HERMES_ROOT:-${HERMES_HOME:-$HOME/.hermes}}"
GW="$ROOT/cliproxy"; SRC="$GW/src"; PORT="${CLIPROXY_PORT:-8317}"
TAG=$(sed -n 's/^tag=//p' "$F/cliproxy-approved.txt"); COMMIT=$(sed -n 's/^commit=//p' "$F/cliproxy-approved.txt")
OLD="$(cat "$GW/VERSION" 2>/dev/null || echo unknown)"
[ "$OLD" = "$TAG" ] && { echo "Шлюз уже версии $TAG"; exit 0; }
echo "Обновление шлюза: $OLD -> $TAG"
export GOPATH="${GOPATH:-$HOME/gopath}"; export PATH="$HOME/go/bin:$GOPATH/bin:$PATH"
sh "$F/install_go.sh"
if [ -d "$SRC/.git" ]; then (cd "$SRC" && git fetch -q --depth 1 origin tag "$TAG" && git -c advice.detachedHead=false checkout -q "$TAG")
else git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" https://github.com/router-for-me/CLIProxyAPI "$SRC"; fi
[ "$(cd "$SRC" && git rev-parse HEAD)" = "$COMMIT" ] || { echo "СТОП: тег $TAG не на одобренном коммите"; exit 3; }
sh "$F/cliproxy_audit_hosts.sh" "$SRC" "$F/cliproxy-known-hosts.txt" || { echo "СТОП: незнакомые адреса в исходнике"; exit 3; }
(cd "$SRC" && go build -trimpath -ldflags "-s -w" -o "$GW/cli-proxy-api.new" ./cmd/server/)
cd "$GW"
mv cli-proxy-api "cli-proxy-api.old-$OLD" && mv cli-proxy-api.new cli-proxy-api
PID="$(pgrep -x cli-proxy-api | head -1 || true)"
if [ -n "$PID" ]; then kill "$PID"; fi   # служба (s6/systemd) или сторож шлюза поднимет новую версию
sleep 6
if ! curl -sf -m 5 "http://127.0.0.1:$PORT/healthz" >/dev/null; then
  command -v systemctl >/dev/null && systemctl --user restart cliproxy 2>/dev/null || true
  sleep 3
fi
if curl -sf -m 5 "http://127.0.0.1:$PORT/healthz" >/dev/null; then
  echo "$TAG" > VERSION; echo "Готово: шлюз $TAG работает. Проверка моделей: tools/pool-install.sh --check"
else
  echo "Шлюз не поднялся. Вернуть старую версию: cd $GW && mv cli-proxy-api.old-$OLD cli-proxy-api, затем перезапуск"
  exit 1
fi
