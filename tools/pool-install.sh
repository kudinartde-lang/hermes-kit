#!/usr/bin/env bash
# Шлюз подписок (CLIProxyAPI) - ставится ОДИН раз на сервер, общий для всех помощников.
# Claude, ChatGPT, Kimi (одна или несколько подписок) -> один шлюз -> все модели в одном списке Hermes.
#
#   tools/pool-install.sh                 собрать и запустить шлюз (10-15 минут, root не нужен)
#   tools/pool-install.sh --check         только проверить, что шлюз жив и какие модели видит
#
# Потом вход в подписки (человек рядом, по одной): tools/pool-login.sh claude | chatgpt
# И подключить помощника: tools/features.sh --id <id> --on pool
#
# Что важно знать (сказать владельцу честно):
# - Подписки через сторонний шлюз могут нарушать правила OpenAI и Anthropic. Риск ограничения
#   аккаунта небольшой, но есть. Лимиты общие с обычным ChatGPT и Claude этого аккаунта.
# - Шлюз собирается из исходника ОДОБРЕННОЙ версии (features/pool/scripts/cliproxy-approved.txt:
#   тег + точный коммит). Не совпал коммит или в коде появились незнакомые адреса - установка
#   останавливается и ничего не собирает.
# Ничего не удаляет: если шлюз уже стоит, конфиг и входы в подписки не трогает.
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
F="$KIT/features/pool"
ROOT="${HERMES_ROOT:-${HERMES_HOME:-$HOME/.hermes}}"
GW="$ROOT/cliproxy"
PORT="${CLIPROXY_PORT:-8317}"
MODE=install BINARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift;;
    --binary) BINARY="$2"; shift 2;;   # уже собранный шлюз той же версии (для проверок набора)
    -h|--help) sed -n 2,16p "$0"; exit 0;;
    *) echo "Непонятный параметр: $1"; exit 2;;
  esac
done

health() { curl -sf -m 5 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; }
models() { curl -s -m 10 -H "Authorization: Bearer $(cat "$GW/client.key")" "http://127.0.0.1:$PORT/v1/models" \
  | python3 -c 'import sys,json; print("\n".join(sorted(m["id"] for m in json.load(sys.stdin).get("data",[]))))'; }

if [ "$MODE" = check ]; then
  if health; then echo "Шлюз жив (порт $PORT), версия $(cat "$GW/VERSION" 2>/dev/null)"; else echo "Шлюз НЕ отвечает"; exit 1; fi
  n=$(ls "$GW/auths" 2>/dev/null | grep -cE '^(codex|claude)-.*\.json$' || true)
  echo "Вошедших подписок: $n"
  echo "Модели:"; models | sed 's/^/  /'
  exit 0
fi

echo "== 1. Папки: $GW"
mkdir -p "$GW/auths" "$GW/logs"; chmod 700 "$GW/auths"
TAG=$(sed -n 's/^tag=//p' "$F/gateway/cliproxy-approved.txt"); COMMIT=$(sed -n 's/^commit=//p' "$F/gateway/cliproxy-approved.txt")

if [ -x "$GW/cli-proxy-api" ] && [ "$(cat "$GW/VERSION" 2>/dev/null)" = "$TAG" ]; then
  echo "== 2. Шлюз $TAG уже собран - пропускаю сборку"
elif [ -n "$BINARY" ]; then
  echo "== 2. Беру готовый шлюз: $BINARY"
  cp "$BINARY" "$GW/cli-proxy-api"; chmod 755 "$GW/cli-proxy-api"; echo "$TAG" > "$GW/VERSION"
else
  echo "== 2. Сборка шлюза $TAG из исходника (10-15 минут)"
  sh "$F/gateway/install_go.sh"
  export GOPATH="${GOPATH:-$HOME/gopath}"; export PATH="$HOME/go/bin:$GOPATH/bin:$PATH"
  SRC="$GW/src"
  if [ ! -d "$SRC/.git" ]; then
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" https://github.com/router-for-me/CLIProxyAPI "$SRC"
  else
    (cd "$SRC" && git fetch -q --depth 1 origin tag "$TAG" && git -c advice.detachedHead=false checkout -q "$TAG")
  fi
  got=$(cd "$SRC" && git rev-parse HEAD)
  [ "$got" = "$COMMIT" ] || { echo "СТОП: тег $TAG указывает не на одобренный коммит ($got). Не собираю."; exit 3; }
  if ! sh "$F/gateway/cliproxy_audit_hosts.sh" "$SRC" "$F/gateway/cliproxy-known-hosts.txt"; then
    echo "СТОП: в исходнике незнакомые сетевые адреса (список выше). Собирать только после проверки."; exit 3
  fi
  (cd "$SRC" && go build -trimpath -ldflags "-s -w" -o "$GW/cli-proxy-api" ./cmd/server/)
  echo "$TAG" > "$GW/VERSION"
fi

echo "== 3. Настройки шлюза"
if [ -f "$GW/config.yaml" ]; then
  echo "   config.yaml уже есть - не трогаю"
else
  CK=$(python3 -c 'import secrets;print(secrets.token_hex(32))'); MK=$(python3 -c 'import secrets;print(secrets.token_hex(32))')
  sed "s|__CLIENT_KEY__|$CK|; s|__MGMT_KEY__|$MK|; s|__AUTH_DIR__|$GW/auths|; s|^port: 8317|port: $PORT|" \
    "$F/templates/cliproxy-config.yaml" > "$GW/config.yaml"
  # Сервер без прямого интернета (защищённая установка: всё через фильтр) - шлюзу нужен адрес фильтра явно,
  # иначе вход в Claude падает на последнем шаге с ошибкой DNS.
  PX="${https_proxy:-${HTTPS_PROXY:-}}"
  if [ -n "$PX" ]; then
    python3 - "$GW/config.yaml" "$PX" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace('port: ', f'proxy-url: "{sys.argv[2]}"\nport: ', 1)
p.write_text(s)
PY
    echo "   выход в интернет через фильтр: $PX"
  fi
  printf '%s' "$CK" > "$GW/client.key"; chmod 600 "$GW/config.yaml" "$GW/client.key"
  echo "   создан (ключи сгенерированы на сервере, на экран не выводятся)"
fi

echo "== 4. Автозапуск"
SUP="${CLIPROXY_SUPERVISOR:-auto}"   # auto | s6 | systemd | nohup
if [ "$SUP" = auto ]; then
  if [ -d /run/service ] && [ -x /command/s6-svscanctl ]; then SUP=s6
  elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then SUP=systemd
  else SUP=nohup; fi
fi
if health; then
  echo "   шлюз уже работает"
elif [ "$SUP" = s6 ]; then
  mkdir -p "$ROOT/s6-services/cliproxy"
  sed "s|__HERMES_HOME__|$ROOT|g; s|__USER__|$(id -un)|g" "$F/templates/s6-run" > "$ROOT/s6-services/cliproxy/run"
  chmod +x "$ROOT/s6-services/cliproxy/run"
  [ -d /run/service/cliproxy ] || cp -r "$ROOT/s6-services/cliproxy" /run/service/cliproxy
  /command/s6-svscanctl -a /run/service
  echo "   служба s6"
elif [ "$SUP" = systemd ]; then
  mkdir -p ~/.config/systemd/user
  sed "s|%h/.hermes|$ROOT|g" "$F/templates/cliproxy.service" > ~/.config/systemd/user/cliproxy.service
  systemctl --user daemon-reload && systemctl --user enable --now cliproxy
  loginctl enable-linger "$(id -un)" 2>/dev/null || true
  echo "   служба systemd"
else
  (cd "$GW" && exec setsid nohup ./cli-proxy-api --config config.yaml --local-model </dev/null >> logs/nohup.log 2>&1) </dev/null >/dev/null 2>&1 &
  echo "   фоновый процесс (после перезагрузки поднимет сторож шлюза - фича pool-watch)"
fi
for _ in 1 2 3 4 5 6 7 8 9 10; do health && break; sleep 2; done
health || { echo "Шлюз не отвечает. Журнал: $GW/logs/"; exit 1; }

echo
echo "Готово: шлюз $TAG работает на 127.0.0.1:$PORT (только внутри сервера)."
echo "Дальше:"
echo "  1. Вход в подписки (человек рядом): tools/pool-login.sh claude   и/или   tools/pool-login.sh chatgpt"
echo "  2. Подключить помощника:            tools/features.sh --id <id> --on pool"
echo "  3. Сторож шлюза хранителю сервера:  tools/features.sh --id <хранитель> --on pool-watch"
