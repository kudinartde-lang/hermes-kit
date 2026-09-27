#!/usr/bin/env bash
# Вход в подписку для шлюза. Человек, чья подписка, - рядом (пароль вводит сам в своём браузере).
#
#   tools/pool-login.sh chatgpt     ChatGPT Plus/Pro: ссылка + код, код живёт 15 минут
#   tools/pool-login.sh claude      Claude Pro/Max: ссылка живёт 3-4 минуты, запускать, когда человек готов
#
# Несколько аккаунтов - запустить несколько раз (в браузере между входами выйти из аккаунта
# или открыть окно инкогнито). Шлюз подхватывает новый вход сам, перезапуск не нужен.
#
# Подписка по ключу (Kimi и подобные) - не здесь: features/pool/README.md, раздел "Подписка по ключу".
set -euo pipefail
ROOT="${HERMES_ROOT:-${HERMES_HOME:-$HOME/.hermes}}"
GW="$ROOT/cliproxy"
[ -x "$GW/cli-proxy-api" ] || { echo "Шлюз не установлен. Сначала tools/pool-install.sh"; exit 1; }
cd "$GW"
case "${1:-}" in
  chatgpt)
    cat <<'EOF'
ChatGPT. Перед входом - человеку в браузере (Safari/Chrome, НЕ в приложении Hermes):
  https://chatgpt.com -> Settings -> Security and login -> включить
  "Enable device code authorization for Codex" (не видно - поиск "device code" в настройках).
  Без этого на экране подтверждения будет красная надпись и кнопка Continue не нажмётся.
Сейчас появятся ссылка и код: открыть ссылку, войти в НУЖНЫЙ аккаунт ChatGPT, ввести код.
EOF
    ./cli-proxy-api --config config.yaml --codex-device-login ;;
  claude)
    cat <<'EOF'
Claude. Сейчас появится длинная ссылка https://claude.ai/oauth/authorize?...
  1. Человек открывает её в браузере, входит в НУЖНЫЙ аккаунт Claude, жмёт Authorize.
  2. Браузер покажет ошибку "не удаётся открыть страницу" с адресом localhost:54545/callback?code=...
     Это УСПЕХ. Скопировать ВЕСЬ адрес из адресной строки и вставить сюда.
  Подсказку шлюза про "ssh -L" игнорировать - туннель не нужен. Ссылка живёт 3-4 минуты.
EOF
    ./cli-proxy-api --config config.yaml --claude-login --no-browser ;;
  *) sed -n 2,11p "$0"; exit 2 ;;
esac
echo
echo "Вошедшие подписки:"; ls auths | grep -E '^(codex|claude)-.*\.json$' | sed 's/^/  /' || echo "  (пока нет)"
echo "Проверка моделей: tools/pool-install.sh --check"
