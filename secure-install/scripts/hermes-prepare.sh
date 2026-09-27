#!/usr/bin/env bash
# Фаза 4: папки проекта и .env с секретами, сгенерированными на месте.
# Секреты на экран не выводятся. Запуск: ssh hermes-vps 'sudo bash -s' < scripts/hermes-prepare.sh
set -euo pipefail
D=/docker/hermes-agent
[ -e "$D" ] && { echo "СТОП: $D уже существует — ничего не меняю"; exit 1; }
install -d -m 755 "$D" "$D/egress"
install -d -m 700 "$D/logs"
install -d -m 700 -o 10000 -g 10000 "$D/data"
host=$(hostname -f)
case "$host" in *.*) ;; *) host="$host.hstgr.cloud" ;; esac
umask 077
{
  echo "ADMIN_USERNAME=hermes"
  echo "ADMIN_PASSWORD=$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-24)"
  echo "DASHBOARD_AUTH_SECRET=$(openssl rand -hex 32)"
  echo "TRAEFIK_HOST=$host"
  echo "HERMES_WEB_VIA_VPN=false"
  echo "VPN_SOURCE_RANGE=172.16.0.0/12"
} > "$D/.env"
chmod 600 "$D/.env"
echo "ключи в .env: $(cut -d= -f1 "$D/.env" | tr '\n' ' ')"
echo "TRAEFIK_HOST=$host  (веб будет https://hermes-agent.$host)"
echo "PREPARE_OK"
