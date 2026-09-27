#!/usr/bin/env bash
# Меню фич: человек сам выбирает, что поставить его помощнику.
#
#   tools/features.sh --id anna                 меню: по каждой фиче вопрос "ставить?" (Enter = как предложено)
#   tools/features.sh --id anna --list          что есть и что уже стоит
#   tools/features.sh --id anna --on pool,calendar      поставить эти фичи (без вопросов)
#   tools/features.sh --id anna --off calendar          выключить фичу
#   tools/features.sh --id anna --defaults      поставить всё, что предложено по умолчанию (без вопросов)
#   tools/features.sh --id anna --reapply       переставить уже выбранные фичи из свежего набора
#                                               (после git pull; делает tools/update-all.sh)
#
# Каталог фич - features/catalog.tsv, у каждой фичи своя папка features/<id>/ и README.md.
# Выбор человека хранится в <профиль>/local/features (обновления набора его не трогают).
# Выключение ничего не удаляет: задачи расписания ставятся на паузу, плагин и навыки выключаются,
# файлы остаются на месте. Повторный запуск безопасен.
set -euo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)"
CAT="$KIT/features/catalog.tsv"
ID="" MODE="menu" LIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --id) ID="$2"; shift 2;;
    --list) MODE="list"; shift;;
    --on) MODE="on"; LIST="$2"; shift 2;;
    --off) MODE="off"; LIST="$2"; shift 2;;
    --defaults) MODE="defaults"; shift;;
    --reapply) MODE="reapply"; shift;;
    -h|--help) sed -n 2,17p "$0"; exit 0;;
    *) echo "Непонятный параметр: $1 (см. --help)"; exit 2;;
  esac
done
[ -n "$ID" ] || { echo "Нужен --id (например --id anna)"; exit 2; }
command -v hermes >/dev/null || { echo "Не найден hermes"; exit 1; }

ROOT="${HERMES_ROOT:-${HERMES_HOME:-$HOME/.hermes}}"
# --id main (или default) - основной помощник Hermes, без отдельного профиля (подготовка: tools/install-main.sh)
if [ "$ID" = main ] || [ "$ID" = default ]; then ID=default; PROFILE="$ROOT"
else PROFILE="$ROOT/profiles/$ID"; fi
[ -d "$PROFILE" ] || { echo "Нет помощника $ID ($PROFILE). Сначала tools/add-person.sh"; exit 1; }
STATE="$PROFILE/local/features"
mkdir -p "$PROFILE/local" "$PROFILE/scripts" "$PROFILE/skills" "$PROFILE/plugins"
touch "$STATE"
KEEPER=0; [ -f "$PROFILE/local/server-keeper" ] && KEEPER=1
export KIT ROOT PROFILE ID KEEPER

# Питон самого Hermes (в нём есть yaml) - для правки настроек и поиска встроенных навыков
HPY=""
for c in "$(dirname "$(readlink -f "$(command -v hermes)")")/python3" /opt/hermes/.venv/bin/python3 "$ROOT/.venv/bin/python3"; do
  [ -x "$c" ] && "$c" -c 'import hermes_cli, yaml' 2>/dev/null && { HPY="$c"; break; }
done
[ -n "$HPY" ] || HPY=python3
export HPY

field() { awk -F'\t' -v id="$1" -v n="$2" '$1==id {print $n}' "$CAT"; }
ids() { grep -v '^#' "$CAT" | grep -v '^$' | cut -f1; }
is_on() { grep -qx "$1" "$STATE"; }
mark_on() { is_on "$1" || printf '%s\n' "$1" >> "$STATE"; }
mark_off() { grep -vx "$1" "$STATE" > "$STATE.tmp" || true; mv "$STATE.tmp" "$STATE"; }
hp() { hermes -p "$ID" "$@"; }

job_id() {  # id задачи расписания по имени
  "$HPY" - "$PROFILE/cron/jobs.json" "$1" <<'PY'
import sys, json, os
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}
print(next((j["id"] for j in d.get("jobs", []) if j.get("name") == sys.argv[2]), ""))
PY
}

skills_disabled() {  # $1 add|remove, $2.. имена навыков -> skills.disabled в config.yaml профиля
  local act="$1"; shift
  "$HPY" - "$PROFILE/config.yaml" "$act" "$@" <<'PY'
import sys, yaml, pathlib
p, act, names = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
c = yaml.safe_load(p.read_text(encoding="utf-8")) if p.exists() else {}
c = c or {}
s = c.setdefault("skills", {}) or {}
c["skills"] = s
cur = set(s.get("disabled") or [])
new = (cur | set(names)) if act == "add" else (cur - set(names))
if new != cur:
    s["disabled"] = sorted(new)
    p.write_text(yaml.safe_dump(c, allow_unicode=True, sort_keys=False), encoding="utf-8")
PY
}

hermes_skills_dir() {
  "$HPY" -c 'import hermes_cli, pathlib; print(pathlib.Path(hermes_cli.__file__).resolve().parents[1] / "skills")' 2>/dev/null || echo /opt/hermes/skills
}

deliver_target() {  # куда слать сводки: Telegram, если он подключён, иначе в приложение (local)
  if [ -n "${KIT_DELIVER:-}" ]; then echo "$KIT_DELIVER"; return 0; fi
  if grep -qs '^TELEGRAM_HOME_CHANNEL=.' "$PROFILE/.env" "$ROOT/.env" \
     || grep -qs 'TELEGRAM_HOME_CHANNEL\|home_channel' "$PROFILE/config.yaml"; then echo telegram
  else echo local; fi
  return 0
}

ensure_job() {  # $1 - файл .job
  local jf="$1" name prompt jid SCHEDULE="" SCRIPT="" NO_AGENT=0 SKILLS="" PAUSE_UNLESS=""
  name="$(basename "$jf" .job)"
  # shellcheck disable=SC1090
  . "$jf"
  prompt="$(cat "${jf%.job}.prompt")"
  jid="$(job_id "$name")"
  local args=(--name "$name" --deliver "$(deliver_target)")
  [ -n "$SCRIPT" ] && args+=(--script "$SCRIPT")
  [ "$NO_AGENT" = 1 ] && args+=(--no-agent)
  for s in $SKILLS; do args+=(--skill "$s"); done
  local wait_reason=""
  if [ -n "$PAUSE_UNLESS" ] && ! eval "$PAUSE_UNLESS" >/dev/null 2>&1; then wait_reason="${PAUSE_REASON:-ждёт настройки}"; fi
  if [ -z "$jid" ]; then
    if [ -n "$wait_reason" ]; then args+=(--paused --paused-reason "$wait_reason"); fi
    hp cron create "$SCHEDULE" "$prompt" "${args[@]}" >/dev/null
    jid="$(job_id "$name")"
  else
    local eargs=(--schedule "$SCHEDULE" --prompt "$prompt")
    [ -n "$SCRIPT" ] && eargs+=(--script "$SCRIPT")
    [ -n "$SKILLS" ] && { eargs+=(--clear-skills); for s in $SKILLS; do eargs+=(--add-skill "$s"); done; }
    hp cron edit "$jid" "${eargs[@]}" >/dev/null
    [ -z "$wait_reason" ] && hp cron resume "$jid" >/dev/null 2>&1 || true
  fi
  if [ -n "$wait_reason" ]; then echo "     - расписание $name: пока на паузе ($wait_reason)"
  else echo "     + расписание $name"; fi
}

install_feature() {
  local f="$1" dir="$KIT/features/$1"
  local who; who="$(field "$f" 2)"
  if [ "$who" = keeper ] && [ "$KEEPER" != 1 ]; then
    echo "  ! $f - только для хранителя сервера (add-person.sh --server-keeper), пропускаю"; return 0
  fi
  local need; need="$(field "$f" 4)"
  if [ -n "$need" ] && [ "$need" != "-" ] && ! is_on "$need"; then
    echo "  ! $f - сначала нужна фича $need, пропускаю"; return 0
  fi
  echo "  == $f - $(field "$f" 5)"
  if [ -d "$dir/skills" ]; then
    for s in "$dir"/skills/*/; do
      [ -d "$s" ] || continue
      rm -rf "$PROFILE/skills/$(basename "$s")"; cp -R "$s" "$PROFILE/skills/"
      skills_disabled remove "$(basename "$s")"
    done
  fi
  if [ -f "$dir/bundled-skills.txt" ]; then   # навыки, которые идут с самим Hermes
    local hs; hs="$(hermes_skills_dir)"
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue; case "$rel" in \#*) continue;; esac
      if [ -d "$hs/$rel" ]; then
        rm -rf "$PROFILE/skills/$(basename "$rel")"; cp -R "$hs/$rel" "$PROFILE/skills/"
        skills_disabled remove "$(basename "$rel")"
      else
        echo "     ! в этой версии Hermes нет навыка $rel"
      fi
    done < "$dir/bundled-skills.txt"
  fi
  if [ -d "$dir/scripts" ]; then
    cp -R "$dir"/scripts/. "$PROFILE/scripts/"
    find "$PROFILE/scripts" -maxdepth 1 \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
  fi
  if [ -d "$dir/plugins" ]; then
    for p in "$dir"/plugins/*/; do
      [ -d "$p" ] || continue
      local pn; pn="$(basename "$p")"
      mkdir -p "$PROFILE/plugins/$pn"; cp -R "$p". "$PROFILE/plugins/$pn/"
      if [ -f "$p/plugin.yaml" ]; then hp plugins enable "$pn" --no-allow-tool-override >/dev/null 2>&1 || true; fi
      echo "     + плагин $pn"
    done
  fi
  if [ -f "$dir/setup.sh" ]; then
    if ! bash "$dir/setup.sh"; then echo "  !! $f: ошибка при настройке (см. выше) - фича НЕ отмечена"; return 0; fi
  fi
  if [ -d "$dir/jobs" ]; then
    for jf in "$dir"/jobs/*.job; do [ -f "$jf" ] && ensure_job "$jf"; done
  fi
  mark_on "$f"
}

remove_feature() {
  local f="$1" dir="$KIT/features/$1"
  echo "  == выключаю $f - $(field "$f" 5) (файлы остаются, ничего не удаляю)"
  if [ -d "$dir/jobs" ]; then
    for jf in "$dir"/jobs/*.job; do
      [ -f "$jf" ] || continue
      local jid; jid="$(job_id "$(basename "$jf" .job)")"
      [ -n "$jid" ] && hp cron pause "$jid" >/dev/null && echo "     - расписание $(basename "$jf" .job) на паузе"
    done
  fi
  if [ -d "$dir/plugins" ]; then
    for p in "$dir"/plugins/*/; do [ -d "$p" ] && hp plugins disable "$(basename "$p")" >/dev/null 2>&1 || true; done
  fi
  local names=()
  [ -d "$dir/skills" ] && for s in "$dir"/skills/*/; do [ -d "$s" ] && names+=("$(basename "$s")"); done
  [ -f "$dir/bundled-skills.txt" ] && while IFS= read -r rel; do [ -n "$rel" ] && names+=("$(basename "$rel")"); done < <(grep -v '^#' "$dir/bundled-skills.txt")
  [ ${#names[@]} -gt 0 ] && skills_disabled add "${names[@]}"
  [ -f "$dir/off.sh" ] && bash "$dir/off.sh"
  mark_off "$f"
}

check_ids() {
  for f in $(echo "$1" | tr ',' ' '); do
    ids | grep -qx "$f" || { echo "Нет такой фичи: $f. Список: tools/features.sh --id $ID --list"; exit 2; }
  done
}

show_list() {
  echo "Фичи помощника $ID (+ стоит, . не стоит):"
  local n=0
  for f in $(ids); do
    n=$((n+1)); local mark="."; is_on "$f" && mark="+"
    local who=""; [ "$(field "$f" 2)" = keeper ] && who=" [хранитель сервера]"
    printf ' %s %2d. %-15s %s%s\n     %s\n' "$mark" "$n" "$f" "$(field "$f" 5)" "$who" "$(field "$f" 6)"
  done
}

case "$MODE" in
  list) show_list ;;
  on) check_ids "$LIST"; for f in $(echo "$LIST" | tr ',' ' '); do install_feature "$f"; done ;;
  off) check_ids "$LIST"; for f in $(echo "$LIST" | tr ',' ' '); do remove_feature "$f"; done ;;
  defaults)
    for f in $(ids); do
      [ "$(field "$f" 3)" = on ] || continue
      [ "$(field "$f" 2)" = keeper ] && [ "$KEEPER" != 1 ] && continue
      install_feature "$f"
    done ;;
  reapply)
    for f in $(ids); do is_on "$f" && install_feature "$f"; done ;;
  menu)
    [ -t 0 ] || { echo "Меню работает только в терминале. Без вопросов: --defaults или --on a,b"; exit 2; }
    echo "Выберите фичи для помощника $ID. Enter - как предложено в скобках."
    echo
    for f in $(ids); do
      who="$(field "$f" 2)"
      [ "$who" = keeper ] && [ "$KEEPER" != 1 ] && continue
      def="$(field "$f" 3)"; is_on "$f" && def=on
      hint="да/нет"; [ "$def" = on ] && hint="ДА/нет" || hint="да/НЕТ"
      printf '%s - %s\n  %s\n' "$(field "$f" 5)" "$f" "$(field "$f" 6)"
      read -r -p "  Ставить? [$hint] " a
      a="${a:-}"
      case "$a" in
        д|Д|да|Да|ДА|y|Y|yes|Yes|l|L|lf|Lf) want=on;; н|Н|нет|Нет|НЕТ|n|N|no|No|ytn) want=off;; *) want="$def";;
      esac
      if [ "$want" = on ]; then install_feature "$f"
      elif is_on "$f"; then remove_feature "$f"; fi
      echo
    done ;;
esac

if [ "$MODE" != list ]; then
  echo
  show_list
  echo
  echo "Что сделать руками по каждой фиче - features/<id>/README.md. Перезапуск: hermes gateway restart"
fi
