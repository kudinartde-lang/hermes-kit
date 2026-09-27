#!/usr/bin/env bash
# Фича pool: подключить помощника к шлюзу подписок (шлюз ставится один раз: tools/pool-install.sh).
# Вызывается из tools/features.sh (там заданы KIT ROOT PROFILE ID HPY).
# Модели по ролям можно задать явно: POOL_STRONG=... POOL_MAIN=... POOL_LIGHT=... tools/features.sh --id x --on pool
set -euo pipefail
GW="$ROOT/cliproxy"
PORT="${CLIPROXY_PORT:-8317}"
URL="http://127.0.0.1:$PORT/v1"
if [ ! -f "$GW/client.key" ]; then
  echo "     ! шлюз не установлен на сервере - сначала tools/pool-install.sh, потом снова --on pool"
  exit 0
fi
hp() { hermes -p "$ID" "$@"; }
set_() { hp config set "$1" "$2" >/dev/null; }

# ключ шлюза - в .env помощника (на экран не выводим), в config.yaml только ссылка на него
KEY="$(cat "$GW/client.key")"
ENVF="$PROFILE/.env"; touch "$ENVF"; chmod 600 "$ENVF"
if grep -q '^CLIPROXY_KEY=' "$ENVF"; then
  "$HPY" - "$ENVF" "$KEY" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); lines = p.read_text().splitlines()
p.write_text("\n".join(f"CLIPROXY_KEY={sys.argv[2]}" if l.startswith("CLIPROXY_KEY=") else l for l in lines) + "\n")
PY
else
  printf 'CLIPROXY_KEY=%s\n' "$KEY" >> "$ENVF"
fi
set_ providers.pool.name pool
set_ providers.pool.base_url "$URL"
set_ providers.pool.api_key '${CLIPROXY_KEY}'
set_ providers.pool.api_mode chat_completions

MODELS="$(curl -s -m 10 -H "Authorization: Bearer $KEY" "$URL/models" \
  | "$HPY" -c 'import sys,json
try: print("\n".join(m["id"] for m in json.load(sys.stdin).get("data",[])))
except Exception: pass' || true)"

# роли моделей: сильная (стратегии), основная (обычная работа), лёгкая (служебное)
pick() { for m in "$@"; do printf '%s\n' "$MODELS" | grep -qx "$m" && { echo "$m"; return 0; }; done; return 0; }
STRONG="${POOL_STRONG:-$(pick gpt-6-astra claude-fable-5 claude-opus-5-5 claude-opus-5 gpt-5.5)}"
MAIN="${POOL_MAIN:-$(pick gpt-6-sol claude-opus-5 claude-opus-5-5 gpt-5.5 claude-sonnet-5)}"
LIGHT="${POOL_LIGHT:-$(pick gpt-6-luna claude-sonnet-5 gpt-5.6-luna)}"

# порядок моделей в списке выбора: сначала Claude, потом GPT, потом остальные
ORDER="$(printf '%s\n' "$MODELS" | "$HPY" -c 'import sys
ms=[l.strip() for l in sys.stdin if l.strip()]
key=lambda m:(0 if m.startswith("claude") else 1 if m.startswith("gpt") else 2, m)
print(", ".join(repr(m) for m in sorted(ms,key=key)))')"
PD="$PROFILE/plugins/model-providers/pool"; mkdir -p "$PD"
cp "$KIT/features/pool/templates/pool-provider-plugin.yaml" "$PD/plugin.yaml"
sed "s|__POOL_MODELS__|${ORDER:-}|; s|__POOL_URL__|$URL|" "$KIT/features/pool/templates/pool-provider__init__.py.tmpl" > "$PD/__init__.py"

if [ -z "$MODELS" ]; then
  echo "     ! шлюз пока не видит ни одной модели: нет входа в подписки (tools/pool-login.sh)."
  echo "       Помощник подключён к шлюзу, но основная модель не переключена. После входа: --on pool ещё раз."
  exit 0
fi
for a in strong:$STRONG main:$MAIN light:$LIGHT; do
  r="${a%%:*}"; m="${a#*:}"; [ -n "$m" ] || continue
  set_ "model_aliases.$r.model" "$m"; set_ "model_aliases.$r.provider" pool
done
for m in $MODELS; do  # короткие имена pool-<модель> для /model
  set_ "model_aliases.pool-$m.model" "$m"; set_ "model_aliases.pool-$m.provider" pool
done
if [ "${POOL_MAKE_DEFAULT:-1}" = 1 ] && [ -n "$MAIN" ]; then
  set_ model.provider pool; set_ model.base_url "$URL"; set_ model.default "$MAIN"
  set_ providers.pool.default_model "$MAIN"
  if [ -n "$LIGHT" ]; then  # служебное и помощники-исполнители - на лёгкой модели через шлюз
    for k in compression title_generation approval curator skills_hub mcp vision background_review goal_judge memory_query_rewrite; do
      set_ "auxiliary.$k.provider" pool; set_ "auxiliary.$k.model" "$LIGHT"
    done
    set_ delegation.provider pool; set_ delegation.model "$LIGHT"
  fi
  echo "     + основная модель: $MAIN через шлюз (сильная: ${STRONG:-нет}, лёгкая: ${LIGHT:-нет})"
fi
echo "     + в списке моделей: $(printf '%s\n' "$MODELS" | wc -l) шт. Переключение: /model strong | main | light | pool-<модель>"
