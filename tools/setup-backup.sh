#!/usr/bin/env bash
# Один раз на сервер: подготовить ночной бэкап всех помощников и общей базы
# в ПРИВАТНЫЙ репозиторий GitHub компании (не в репозиторий установщика!).
#
#   tools/setup-backup.sh --repo git@github.com:<аккаунт-компании>/<имя>-backup.git --keeper <id>
#
#   --repo    ssh-адрес пустого приватного репозитория (создаёт владелец компании на github.com)
#   --keeper  профиль, который обслуживает сервер (тот, кому ставили --server-keeper)
#
# Что делает (ничего не удаляет и не перезаписывает):
#   1. .gitignore в корне Hermes - создаёт, если нет; если есть - только дописывает недостающие строки;
#   2. git-репозиторий в корне Hermes - создаёт, если нет;
#   3. ключ доступа (deploy key) - создаёт, если нет, и печатает его ОТКРЫТУЮ часть;
#   4. адрес репозитория - прописывает, если ещё не прописан.
# Отправку в GitHub сам НЕ делает. Первый бэкап - после того, как ключ добавлен на GitHub:
#   hermes -p <keeper> cron run <id задачи nightly-backup>   (или дождаться 3:00)
set -euo pipefail

REPO="" KEEPER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --keeper) KEEPER="$2"; shift 2;;
    -h|--help) sed -n 2,17p "$0"; exit 0;;
    *) echo "Непонятный параметр: $1 (см. --help)"; exit 2;;
  esac
done
[ -n "$REPO" ] || { echo "Нужен --repo (см. --help)"; exit 2; }
case "$REPO" in git@*:*.git) ;; *) echo "--repo: нужен ssh-адрес вида git@github.com:аккаунт/имя.git"; exit 2;; esac

ROOT="${HERMES_HOME:-$HOME/.hermes}"
KEY="${BACKUP_SSH_KEY:-$HOME/.ssh/id_ed25519_hermes_backup}"
cd "$ROOT"

echo "== 1. Что НЕ попадает в бэкап (.gitignore): $ROOT/.gitignore"
touch .gitignore
added=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! grep -qxF -- "$line" .gitignore; then printf '%s\n' "$line" >> .gitignore; added=$((added+1)); fi
done <<'EOF'
# --- секреты: никогда в бэкап ---
.env
*.env
.env.*
!.env.EXAMPLE
auth.json
**/auth.json
*.key
*.pem
id_*
pairing/
**/pairing/
.ssh/
# --- переписки и служебное: большие и с личными данными ---
*.db
*.db-wal
*.db-shm
*.sqlite
sessions/
**/sessions/
logs/
**/logs/
cache/
**/cache/
audio_cache/
**/audio_cache/
image_cache/
**/image_cache/
runtime/
**/runtime/
monitor/
**/monitor/
home/
**/home/
node_modules/
__pycache__/
hermes-agent/
bin/
# копии config.yaml, которые Hermes делает сам (в старых мог оказаться ключ)
backups/
**/backups/
# --- шлюз подписок: входы в подписки и ключи - никогда в бэкап (своя копия - фича pool-watch) ---
cliproxy/auths/
cliproxy/config.yaml
cliproxy/src/
cliproxy/cli-proxy-api*
cliproxy/.dl/
# --- программы (ставятся заново) ---
.venv*/
go/
gopath/
EOF
echo "   дописано строк: $added"

echo "== 2. Репозиторий бэкапа"
if [ -d .git ]; then echo "   уже есть"; else git init -q -b main . && echo "   создан"; fi
git config user.name  >/dev/null 2>&1 || git config user.name "Hermes backup"
git config user.email >/dev/null 2>&1 || git config user.email "backup@localhost"

echo "== 3. Ключ доступа к GitHub: $KEY"
mkdir -p "$(dirname "$KEY")"; chmod 700 "$(dirname "$KEY")"
if [ -f "$KEY" ]; then echo "   уже есть"; else ssh-keygen -q -t ed25519 -N "" -C "hermes-backup@$(hostname)" -f "$KEY" && echo "   создан"; fi

echo "== 4. Адрес репозитория"
if git remote get-url origin >/dev/null 2>&1; then
  echo "   уже прописан: $(git remote get-url origin)"
  [ "$(git remote get-url origin)" = "$REPO" ] || echo "   ! отличается от --repo - оставил как было, поменяйте вручную, если нужно"
else
  git remote add origin "$REPO" && echo "   прописан: $REPO"
fi

cat <<EOF

Осталось на GitHub (делает владелец компании, 2 минуты):
  1. Репозиторий -> Settings -> Deploy keys -> Add deploy key
  2. Title: Hermes backup.  Key: строка ниже.  Галочка "Allow write access" - ВКЛЮЧИТЬ.
  3. Add key.

----- открытая часть ключа (её можно показывать) -----
$(cat "$KEY.pub")
------------------------------------------------------

Потом первый бэкап и проверка:
  BACKUP_SSH_KEY=$KEY python3 "$ROOT/profiles/${KEEPER:-<keeper>}/scripts/git-backup.py"
И включить ночной бэкап (3:00):
  tools/enable-jobs.sh ${KEEPER:-<keeper>}
EOF
