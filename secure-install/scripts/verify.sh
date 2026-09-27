#!/usr/bin/env bash
# Итоговая проверка защиты. ТОЛЬКО ЧТЕНИЕ.
# Запуск с компьютера (из папки комплекта):
#   ssh hermes-vps 'sudo bash -s' < scripts/verify.sh
set -u
P=/docker/hermes-agent
C=hermes-agent-hermes-agent-1
fails=0
ok()  { printf '  OK     %s\n' "$1"; }
bad() { printf '  ПЛОХО  %s\n' "$1"; fails=$((fails+1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
envval() { grep -m1 "^$1=" "$P/.env" 2>/dev/null | cut -d= -f2-; }

echo "SSH"
check "вход под root запрещён"            "sshd -T | grep -qx 'permitrootlogin no'"
check "вход по паролю запрещён"           "sshd -T | grep -qx 'passwordauthentication no'"
check "keyboard-interactive запрещён"     "sshd -T | grep -qx 'kbdinteractiveauthentication no'"

echo "Фаервол и обновления"
check "UFW включён"                        "ufw status | grep -q 'Status: active'"
check "UFW: входящие по умолчанию запрещены" "ufw status verbose | grep -q 'deny (incoming)'"
check "автообновления безопасности включены" "grep -q 'Unattended-Upgrade \"1\"' /etc/apt/apt.conf.d/20auto-upgrades"
check "fail2ban работает"                  "systemctl is-active --quiet fail2ban"

echo "Контейнер Гермеса"
check "Гермес запущен"                     "[ \"\$(docker inspect -f '{{.State.Running}}' $C)\" = true ]"
check "egress-прокси здоров"               "[ \"\$(docker inspect -f '{{.State.Health.Status}}' hermes-agent-egress-proxy-1)\" = healthy ]"
check "у Гермеса нет опубликованных портов" "[ -z \"\$(docker port $C)\" ]"
check "Гермес только во внутренней сети"   "[ \"\$(docker inspect -f '{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' $C)\" = 'hermes-agent_agent_internal ' ]"
check "внутренняя сеть без выхода наружу"  "[ \"\$(docker network inspect -f '{{.Internal}}' hermes-agent_agent_internal)\" = true ]"
check "no-new-privileges включён"          "docker inspect -f '{{.HostConfig.SecurityOpt}}' $C | grep -q no-new-privileges"
check "docker.sock НЕ смонтирован в Гермеса" "! docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' $C | grep -q docker.sock"

echo "Файлы и секреты"
check ".env проекта: права 600"            "[ \"\$(stat -c %a $P/.env)\" = 600 ]"
check "data/: права 700"                   "[ \"\$(stat -c %a $P/data)\" = 700 ]"
check "data/.env: доступ только владельцу" "[ \"\$(stat -c %a $P/data/.env)\" = 600 ]"
check "задан DASHBOARD_AUTH_SECRET"        "[ -n \"\$(envval DASHBOARD_AUTH_SECRET)\" ]"
check "задан TELEGRAM_ALLOWED_USERS"       "grep -qE '^TELEGRAM_ALLOWED_USERS=.+' $P/data/.env"
check "нет разрешения писать боту всем"    "! grep -qiE '^[A-Z_]*ALLOW_ALL_USERS=(true|1|yes)' $P/data/.env"
check "нет YOLO-режима"                    "! grep -qiE '^HERMES_YOLO_MODE=(1|true|yes)' $P/data/.env"
check "одобрение команд не выключено"      "! docker exec $C gosu hermes hermes config get approvals.mode 2>/dev/null | grep -qiE '\\b(off|none)\\b'"

echo "Выход агента в интернет (проба изнутри контейнера)"
docker exec -i "$C" /opt/hermes/.venv/bin/python3 - <<'PY' || fails=$((fails+1))
import socket, urllib.request, urllib.error
bad = 0
def show(ok, text):
    global bad
    print(("  OK     " if ok else "  ПЛОХО  ") + text)
    bad += 0 if ok else 1
def direct(host):
    try:
        socket.create_connection((host, 443), timeout=5).close(); return True
    except Exception:
        return False
def via_proxy(url):
    try:
        urllib.request.urlopen(url, timeout=15); return "ok"
    except urllib.error.HTTPError as e:
        return "ok" if e.code < 400 else f"http{e.code}"
    except Exception:
        return "blocked"
show(not direct("example.com"), "напрямую в интернет не выходит (example.com)")
show(not direct("1.1.1.1"),     "напрямую по IP не выходит (1.1.1.1)")
show(via_proxy("https://example.com") == "ok", "через прокси обычный HTTPS-сайт открывается")
show(via_proxy("https://pastebin.com") != "ok", "через прокси pastebin закрыт")
show(via_proxy("https://1.1.1.1") != "ok", "через прокси голые IP закрыты")
show(via_proxy("http://169.254.169.254/") != "ok", "metadata-адрес облака закрыт")
show(via_proxy("http://example.com") != "ok", "простой HTTP (без TLS) закрыт")
raise SystemExit(1 if bad else 0)
PY

echo "Веб-интерфейс"
check "изнутри сервера веб отвечает (для SSH-туннеля)" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://172.31.250.10:4860/ | grep -qE '^(200|302)$'"
if [ "$(envval HERMES_WEB_VIA_VPN)" = true ]; then
  host="hermes-agent.$(envval TRAEFIK_HOST)"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/")
  # Запрос с самого сервера приходит с его публичного IP — это как «из интернета».
  if [ "$code" = 403 ]; then ok "с не-VPN адреса веб отдаёт 403 ($host)"; else bad "с не-VPN адреса веб отдаёт $code, ждали 403 ($host)"; fi
else
  check "веб через Traefik выключен" "[ \"\$(docker inspect -f '{{index .Config.Labels \"traefik.enable\"}}' $C)\" = false ]"
fi

echo "Порты снаружи"
echo "  Слушают не на loopback (сверь со списком VPN/Traefik/SSH):"
ss -tulnpH | grep -vE '(127\.0\.0\.[0-9]+|\[::1\]|%lo):' | awk '{print "    "$1, $5, $7}'

echo
if [ "$fails" -eq 0 ]; then echo "ИТОГ: всё в порядке"; else echo "ИТОГ: проблем — $fails, см. строки ПЛОХО"; fi
exit "$fails"
