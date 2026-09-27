#!/usr/bin/env bash
# Ежедневная ротация журнала egress-прокси Гермеса.
# Журнал живёт в tmpfs контейнера (16 МБ) и без ротации переполнится примерно
# за три недели. Скрипт копирует журнал на диск хоста и обнуляет tmpfs-файл.
# Ставится в /usr/local/sbin/, запускается из cron root раз в сутки.
set -Eeuo pipefail

project_dir=/docker/hermes-agent
archive_dir="$project_dir/logs"
keep_days=14

cd "$project_dir"
pid_container="$(docker compose ps -q egress-proxy)" || exit 0
[ -n "$pid_container" ] || exit 0
pid="$(docker inspect -f '{{.State.Pid}}' "$pid_container")"
log="/proc/$pid/root/var/log/squid/access.log"
[ -f "$log" ] || exit 0

install -d -o root -g root -m 0700 "$archive_dir"
stamp="$(date -u +%Y%m%d)"
dest="$archive_dir/access-$stamp.log"

# Дописываем, а не перезаписываем: за сутки скрипт может сработать повторно.
cat "$log" >> "$dest"
chmod 0600 "$dest"
: > "$log"

find "$archive_dir" -name 'access-*.log' -type f -mtime +$keep_days -delete

echo "$(date -Is) rotated -> $dest ($(wc -l < "$dest") строк всего)"
