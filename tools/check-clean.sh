#!/usr/bin/env bash
# Проверка набора перед выпуском: нет ли в нём ключей, почт, чужих путей и личных данных.
#
#   tools/check-clean.sh [файл-со-словами]
#
# Файл со словами (по одному на строке, целые слова, можно регулярки grep -E:
# имена с падежами, ники, суммы, домены установщика и его клиентов) держать ВНЕ набора, например ~/.hermes-kit-private-words.txt,
# иначе сам список личных данных окажется в наборе. Пустая строка вывода = чисто.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
WORDS="${1:-$HOME/.hermes-kit-private-words.txt}"
cd "$KIT"
FILES=$(git ls-files 2>/dev/null || find . -type f -not -path './.git/*')
found=0
hit() { echo "!! $1"; found=1; }

check() {  # $1 - описание, $2 - регулярка (grep -E)
  local out
  out=$(printf '%s\n' $FILES | xargs grep -nIE -- "$2" 2>/dev/null | grep -v "tools/check-clean.sh" \
        | grep -vE "$ALLOW" | head -20)
  [ -n "$out" ] && { hit "$1"; echo "$out"; }
}

# Заведомо безопасные совпадения: примеры адресов, общий путь пользователя hermes,
# стандартная папка официального Docker-образа Hermes, шаблоны поиска ключей в git-backup.py,
# внутренние (частные) сети и тестовый 1.1.1.1 в скриптах защиты.
ALLOW='git@github\.com:(аккаунт|<аккаунт)|user@example\.com|/home/hermes/|official Docker|const HOMES|hermes_homes = list|github_pat_\[|gh\[pousr\]|\b(10|127|0)\.[0-9.]+(/[0-9]+)?\b|\b172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+|\b192\.168\.[0-9.]+|\b169\.254\.|1\.1\.1\.1|\./data:/opt/data|github\.com/(repos/)?router-for-me/CLIProxyAPI|raw\.githubusercontent\.com/kudinartde-lang/hermes-kit/main|github\.com/kudinartde-lang/hermes-kit/tree/main'

check "почты"            '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(com|ru|org|net|io|me)\b'
check "ключи и токены"   '(sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[bp]-|AKIA[0-9A-Z]{16}|[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}|BEGIN [A-Z ]*PRIVATE KEY)'
check "пути сервера установщика" '/opt/data|/home/[a-z]+/|/Users/[A-Za-z]+/'
check "ссылки на чужие репозитории" 'github\.com/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+'
check "телефоны"         '(\+7|8)[ -]?\(?[0-9]{3}\)?[ -]?[0-9]{3}[ -]?[0-9]{2}[ -]?[0-9]{2}'
check "IP-адреса"        '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'

if [ -f "$WORDS" ]; then
  while IFS= read -r w; do
    [ -z "$w" ] && continue; case "$w" in \#*) continue;; esac
    out=$(printf '%s\n' $FILES | xargs grep -nIiwE -- "$w" 2>/dev/null | grep -v "tools/check-clean.sh" | grep -vE "$ALLOW" | head -10)
    [ -n "$out" ] && { hit "личное слово из списка"; echo "$out"; }
  done < "$WORDS"
else
  echo "(списка личных слов нет: $WORDS - проверены только общие шаблоны)"
fi

for f in .env auth.json; do
  printf '%s\n' $FILES | grep -qx "$f" && hit "в наборе лежит $f"
done
[ $found = 0 ] && echo "Чисто." || { echo; echo "Нашлось - разобрать перед выпуском."; exit 1; }
