#!/usr/bin/env bash
# Разведка сервера перед установкой Гермеса. ТОЛЬКО ЧТЕНИЕ — ничего не меняет.
# Запуск с компьютера (из папки комплекта):
#   ssh hermes-vps 'sudo bash -s' < scripts/discover.sh
# Секреты не выводит: ни конфиг xray, ни содержимое .env сюда не попадают.
set -u
sec() { printf '\n=== %s ===\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

sec "Система"
echo "hostname -f: $(hostname -f 2>/dev/null)"
. /etc/os-release && echo "$PRETTY_NAME, ядро $(uname -r)"
echo "CPU: $(nproc)"
free -h | awk 'NR==2{print "RAM: "$2" всего, доступно "$7}'
df -h / | awk 'NR==2{print "Диск /: "$2" всего, свободно "$4}'
echo "Публичный IPv4: $(curl -s -4 --max-time 5 https://ifconfig.me 2>/dev/null || echo '?')"

sec "Пользователи с sudo и ключи SSH"
getent group sudo
ls -1 /etc/sudoers.d/ 2>/dev/null
for u in root $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
  h=$(getent passwd "$u" | cut -d: -f6)
  n=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$h/.ssh/authorized_keys" 2>/dev/null || true)
  echo "$u: ключей в authorized_keys = ${n:-0}"
done

sec "SSH (действующие значения sshd -T)"
sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries|allowtcpforwarding|x11forwarding) '
echo "sshd_config.d: $(ls /etc/ssh/sshd_config.d/ 2>/dev/null | tr '\n' ' ')"

sec "Кто слушает порты снаружи (без loopback)"
ss -tulnpH | grep -vE '(127\.0\.0\.[0-9]+|\[::1\]|%lo):' | awk '{print $1, $5, $7}'

sec "Фаервол UFW"
if have ufw; then ufw status verbose; else echo "ufw не установлен"; fi

sec "Автообновления и fail2ban"
dpkg -l unattended-upgrades fail2ban 2>/dev/null | awk '/^ii/{print $2" "$3" — установлен"}'
cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null || echo "20auto-upgrades нет"
echo "fail2ban: $(systemctl is-active fail2ban 2>/dev/null)"

sec "Docker"
if ! have docker; then echo "Docker НЕ установлен"; else
  docker --version
  docker compose version 2>/dev/null || echo "docker compose НЕ установлен"
  echo "daemon.json: $(cat /etc/docker/daemon.json 2>/dev/null || echo 'нет')"

  sec "Контейнеры"
  docker ps -a --format '{{.Names}} | {{.Image}} | {{.Status}} | порты: {{.Ports}}'
  echo
  for c in $(docker ps -q); do
    docker inspect -f '{{.Name}} netmode={{.HostConfig.NetworkMode}} {{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}' "$c"
  done

  sec "Метки Traefik у запущенных контейнеров"
  for c in $(docker ps -q); do
    l=$(docker inspect -f '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' "$c" | grep '^traefik\.' || true)
    [ -n "$l" ] && { docker inspect -f '{{.Name}}' "$c"; echo "$l" | sed 's/^/  /'; }
  done

  sec "Docker-сети"
  for n in $(docker network ls -q); do
    docker network inspect -f '{{.Name}}: {{range .IPAM.Config}}{{.Subnet}} {{end}}internal={{.Internal}}' "$n"
  done
fi

sec "Папки проектов в /docker"
if [ -d /docker ]; then for d in /docker/*/; do echo "$d: $(ls -A "$d" | tr '\n' ' ')"; done; else echo "/docker нет"; fi

sec "VPN"
have docker && docker ps --format '{{.Names}} {{.Image}}' | grep -iE 'xray|x-ui|3x-ui|marzban|remnawave|sing-box|v2ray' || echo "VPN-контейнер не найден по имени"
systemctl list-units --type=service --no-legend 2>/dev/null | grep -iE 'xray|x-ui|v2ray|sing-box' || echo "VPN как системная служба не найден"

sec "Подсказка по варианту веба"
if have docker; then
  tr=$(docker ps --format '{{.Names}}' | grep -i traefik | head -1)
  vpn=$(docker ps --format '{{.Names}}' | grep -iE 'xray|x-ui|marzban|remnawave|sing-box' | head -1)
  if [ -n "$tr" ] && [ -n "$vpn" ] && docker inspect -f '{{range $k,$v := .Config.Labels}}{{$k}}{{"\n"}}{{end}}' "$vpn" | grep -q '^traefik\.tcp\.'; then
    echo "Похоже на вариант A: Traefik ($tr) и VPN ($vpn) за ним по SNI — как на рабочем сервере."
    echo "Сеть VPN-контейнера: $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}netmode={{.HostConfig.NetworkMode}}' "$vpn")"
  else
    echo "Похоже на вариант B: VPN не за Traefik (или Traefik нет). Веб — только через SSH-туннель."
    [ -n "$tr" ] && echo "Traefik есть: $tr"
    [ -n "$vpn" ] && echo "VPN-контейнер: $vpn"
  fi
fi
echo
echo "Разведка закончена. Ничего не изменено."
