#!/usr/bin/env bash
# Фаза 3: UFW. 22/tcp разрешается всегда, остальные порты — аргументами.
# Запуск: ssh hermes-vps 'sudo bash -s -- 80/tcp 443/tcp' < scripts/firewall.sh
# Если UFW уже включён — ничего не сбрасывает, только добавляет правила.
set -euo pipefail
command -v ufw >/dev/null || apt-get install -y ufw
active=no; ufw status | grep -q 'Status: active' && active=yes
ufw allow 22/tcp
for p in "$@"; do ufw allow "$p"; done
if [ "$active" = no ]; then
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
fi
ufw status verbose
echo "FIREWALL_OK"
