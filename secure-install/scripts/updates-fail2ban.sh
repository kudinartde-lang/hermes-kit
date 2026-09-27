#!/usr/bin/env bash
# Фаза 3: автообновления безопасности и fail2ban для SSH.
# Запуск: ssh hermes-vps 'sudo bash -s' < scripts/updates-fail2ban.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q unattended-upgrades fail2ban
f=/etc/apt/apt.conf.d/20auto-upgrades
[ -e "$f" ] && cp -a "$f" "$f.pre-kit-$(date +%Y%m%d)"
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > "$f"
if [ ! -e /var/log/auth.log ]; then
  # Без rsyslog журнала auth.log нет — fail2ban читает journald.
  apt-get install -y -q python3-systemd
  printf '[sshd]\nbackend = systemd\n' > /etc/fail2ban/jail.d/sshd-systemd.local
fi
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 3
fail2ban-client status sshd
echo "UPDATES_FAIL2BAN_OK"
