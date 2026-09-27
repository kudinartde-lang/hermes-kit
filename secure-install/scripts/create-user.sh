#!/usr/bin/env bash
# Фаза 2: пользователь с sudo без пароля и ключами root.
# Запуск (пока вход под root): ssh hermes-vps 'bash -s -- NAME' < scripts/create-user.sh
set -euo pipefail
U="${1:?укажи имя пользователя}"
[ "$(id -u)" = 0 ] || { echo "запускать от root"; exit 1; }
id "$U" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$U"
usermod -aG sudo "$U"
install -d -m 700 -o "$U" -g "$U" "/home/$U/.ssh"
if [ -e "/home/$U/.ssh/authorized_keys" ]; then
  cp -a "/home/$U/.ssh/authorized_keys" "/home/$U/.ssh/authorized_keys.pre-copy-$(date +%Y%m%d)"
fi
install -m 600 -o "$U" -g "$U" /root/.ssh/authorized_keys "/home/$U/.ssh/authorized_keys"
tmp=$(mktemp)
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$U" > "$tmp"
visudo -c -f "$tmp" >/dev/null
install -o root -g root -m 0440 "$tmp" "/etc/sudoers.d/90-$U-nopasswd"
rm -f "$tmp"
visudo -c >/dev/null && echo "sudo: конфигурация в порядке"
echo "ключи у $U: $(awk '{print $NF}' "/home/$U/.ssh/authorized_keys" | tr '\n' ' ')"
echo "CREATE_USER_OK"
