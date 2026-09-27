# Установка Hermes Agent на VPS — инструкция для Claude Code

## Контекст

- Сервер: VPS у Hostinger, Ubuntu. На нём **уже работает VPN на xray** (клиент — Happ). VPN — рабочий инструмент владелицы, его нельзя сломать.
- Цель: поставить Hermes Agent в Docker по схеме, проверенной на соседнем сервере (сентябрь 2026, Hermes v0.21.4):
  - агент во внутренней Docker-сети без выхода в интернет, наружу — только через squid-прокси (HTTPS, без приватных сетей, metadata, голых IP и сервисов для слива данных);
  - SSH только по ключу, без root; UFW; автообновления; fail2ban;
  - Telegram-бот отвечает только владелице;
  - веб-интерфейс не открыт интернету: либо только из VPN (вариант A), либо только через SSH-туннель (вариант B).
- Ты работаешь с компьютера владелицы через `ssh hermes-vps`. Файлы для сервера лежат в `server/`, скрипты проверки — в `scripts/`.

## Жёсткие правила

1. **VPN не трогать.** Не менять конфиг xray, не перезапускать и не пересоздавать его контейнер и сеть, не перезапускать Docker-демон, не трогать Traefik. Если какой-то шаг требует этого — остановись и объясни, что и зачем.
2. **Каждая фаза — с согласия.** Перед фазой коротко скажи, что будет сделано и что может пойти не так, дождись «да». После фаз 2, 3 и 6 попроси владелицу проверить, что VPN в Happ работает.
3. **Бэкап перед правкой.** Любой существующий файл на сервере перед изменением копируй рядом: `<файл>.pre-<что>-<ГГГГММДД>`.
4. **Не потерять доступ.** Изменения SSH применяй только после того, как вход новым пользователем проверен отдельным подключением. UFW включай только с уже разрешённым 22/tcp.
5. **Секреты.** Никогда не проси вставить ключ, токен или пароль в чат. Не выводи значения из `.env` — только имена ключей (`grep -oE '^[A-Z_]+='`). Пароли генерируй на сервере. Всё, где нужно ввести секрет, владелица делает сама в отдельном терминале VS Code.
6. **Никогда:** `ports:` у сервиса Гермеса; `GATEWAY_ALLOW_ALL_USERS=true` или любые `*_ALLOW_ALL_USERS`; `approvals.mode: off`; YOLO (`HERMES_YOLO_MODE`, `--yolo`); `--insecure`; монтировать `/var/run/docker.sock` в Гермеса; образ `:latest` вместо digest; одобрять незнакомые коды pairing.
7. **Не по плану — стоп.** Если вывод не совпадает с ожидаемым, остановись и опиши, что видишь. Не импровизируй на рабочем сервере.

Команды ниже запускай из корня этой папки. `NAME` — имя пользователя, которое выберет владелица.

---

## Фаза 0. Подготовка (делает владелица, ты подсказываешь)

1. hPanel Hostinger: включить 2FA на аккаунте (панель даёт полный доступ к серверу). В разделе VPS → **Snapshots** сделать снапшот — это точка отката.
2. SSH-ключ на этом компьютере (с паролем-фразой — его спросят один раз):
   ```bash
   ssh-keygen -t ed25519 -C "hermes-vps" -f ~/.ssh/id_ed25519_hermes
   ssh-add --apple-use-keychain ~/.ssh/id_ed25519_hermes   # Mac: фраза сохранится в Связке ключей
   ```
   Windows: `Get-Service ssh-agent | Set-Service -StartupType Automatic; Start-Service ssh-agent; ssh-add $HOME\.ssh\id_ed25519_hermes`.
3. Положить публичный ключ на сервер: hPanel → VPS → SSH keys → добавить содержимое `~/.ssh/id_ed25519_hermes.pub`, **или** `ssh-copy-id -i ~/.ssh/id_ed25519_hermes.pub root@<IP>` (пароль root она вводит сама).
4. Добавить в `~/.ssh/config`:
   ```
   Host hermes-vps
     HostName <IP сервера>
     User root
     IdentityFile ~/.ssh/id_ed25519_hermes
     IdentitiesOnly yes
     AddKeysToAgent yes
     UseKeychain yes
     ServerAliveInterval 30
   ```
   (`UseKeychain` — только на Mac, на Windows строку убрать.)
5. Проверка: `ssh -o BatchMode=yes hermes-vps 'echo OK'` → `OK`.
6. Под рукой: свой ключ к модели ИИ, токен Telegram-бота от @BotFather, свой Telegram ID (@userinfobot).

## Фаза 1. Разведка (только чтение)

```bash
ssh hermes-vps 'sudo bash -s' < scripts/discover.sh
```

Расскажи владелице простыми словами:
- как устроен VPN: контейнер или служба, какие порты слушает, стоит ли за Traefik;
- вариант веба: **A** (xray в Docker за Traefik по SNI — как на соседнем сервере) или **B** (всё остальное);
- чего не хватает: пользователь, SSH, UFW, fail2ban, автообновления;
- версии Docker/Compose. Нужен Compose ≥ 2.33 (для `gw_priority`). Если старше — **не обновляй Docker** (перезапустит VPN), а убери строку `gw_priority: 1` из `server/docker-compose.yml`: у внутренней сети нет шлюза, маршрут и так один.
- Если Docker нет вовсе или `/docker/hermes-agent` уже существует — стоп, обсуди.

## Фаза 2. Пользователь и SSH

1. Покажи комментарии ключей root (`sudo awk '{print $NF}' /root/.ssh/authorized_keys`), спроси, какие переносить. Лишние не переносить.
2. Выбор sudo. Рекомендация — **без пароля**, как на соседнем сервере: иначе ты не сможешь выполнять команды без её ввода на каждом шаге. Цена: SSH-ключ = root на сервере, поэтому ключ защищён фразой (фаза 0). Альтернатива — sudo с паролем (задать `passwd NAME`), тогда sudo-команды она запускает сама.
3. Создать пользователя (вариант без пароля для sudo):
   ```bash
   ssh hermes-vps 'bash -s -- NAME' < scripts/create-user.sh
   ```
   Ожидается `CREATE_USER_OK`. Если на шаге 1 решили переносить не все ключи — убери лишние строки из `/home/NAME/.ssh/authorized_keys`.
4. **Проверка отдельным подключением:** `ssh -o BatchMode=yes -o User=NAME hermes-vps 'sudo -n true && echo SUDO_OK'` → `SUDO_OK`. Без этого дальше не идти.
5. Закрыть пароли и root:
   ```bash
   ssh hermes-vps 'sudo tee /etc/ssh/sshd_config.d/00-hardening.conf >/dev/null' < server/sshd/00-hardening.conf
   ssh hermes-vps 'sudo sshd -t && sudo systemctl reload ssh && sudo sshd -T | grep -E "^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication) "'
   ```
   Ожидается: `permitrootlogin no`, `passwordauthentication no`, `kbdinteractiveauthentication no`. Если `00-hardening.conf` уже был — сначала бэкап (правило 3).
6. Проверка: `ssh -o BatchMode=yes -o User=NAME hermes-vps 'echo OK'` → `OK`; `ssh -o BatchMode=yes -o User=root hermes-vps true` → `Permission denied`. Затем в `~/.ssh/config` заменить `User root` на `User NAME`.
7. Попросить проверить VPN.

## Фаза 3. Фаервол, автообновления, fail2ban

1. По разведке составь список портов, которые должны быть открыты: `22/tcp` + всё, что слушает VPN/Traefik снаружи (обычно `80/tcp` и `443/tcp`; если xray слушает другой порт или UDP — его тоже). **Покажи список владелице до включения.**
   Помни: порты, опубликованные Docker через `ports:`, UFW не фильтрует — они работают в обход. А сервисы в `network_mode: host` (часто Traefik и 3x-ui) — фильтрует, их порты обязательно разрешить.
2. Включить UFW. 22/tcp скрипт разрешает сам; остальные порты из согласованного списка — аргументами. Если UFW уже включён, скрипт ничего не сбрасывает, только добавляет правила.
   ```bash
   ssh hermes-vps 'sudo bash -s -- 80/tcp 443/tcp' < scripts/firewall.sh
   ```
   Ожидается `FIREWALL_OK` и в списке — `Default: deny (incoming)`.
3. Автообновления и fail2ban (если нет `/var/log/auth.log`, скрипт сам переключит fail2ban на journald):
   ```bash
   ssh hermes-vps 'sudo bash -s' < scripts/updates-fail2ban.sh
   ```
   Ожидается `UPDATES_FAIL2BAN_OK` и статус jail `sshd`.
4. Попросить проверить VPN и что SSH пускает.

## Фаза 4. Гермес в Docker

1. Папки проекта и `.env`. Секреты генерируются на сервере и на экран не выводятся (что означает каждый ключ — в `server/env.example`). Если `/docker/hermes-agent` уже есть, скрипт остановится.
   ```bash
   ssh hermes-vps 'sudo bash -s' < scripts/hermes-prepare.sh
   ```
   Ожидается `PREPARE_OK` и `TRAEFIK_HOST` вида `srv1234567.hstgr.cloud`.
2. Файлы схемы:
   ```bash
   ssh hermes-vps 'sudo tee /docker/hermes-agent/docker-compose.yml >/dev/null' < server/docker-compose.yml
   ssh hermes-vps 'sudo tee /docker/hermes-agent/egress/squid.conf >/dev/null' < server/egress/squid.conf
   ```
3. Пароль от веба владелица смотрит **сама** в своём терминале и сохраняет в Bitwarden (ты эту команду не запускаешь):
   `ssh -t hermes-vps "sudo grep ^ADMIN_PASSWORD= /docker/hermes-agent/.env"`
4. Запуск:
   ```bash
   ssh hermes-vps 'cd /docker/hermes-agent && sudo docker compose pull && sudo docker compose up -d && sleep 30 && sudo docker compose ps'
   ssh hermes-vps 'cd /docker/hermes-agent && sudo docker compose logs --tail 60 hermes-agent'
   ```
   Ожидается: `egress-proxy` — `healthy`, `hermes-agent` — `Up`. Ошибки про незаданную модель на этом этапе нормальны.
5. Ротация журнала прокси (иначе tmpfs переполнится примерно за три недели):
   ```bash
   ssh hermes-vps 'sudo tee /usr/local/sbin/hermes-squid-log-rotate.sh >/dev/null && sudo chmod 755 /usr/local/sbin/hermes-squid-log-rotate.sh' < server/cron/hermes-squid-log-rotate.sh
   ssh hermes-vps 'echo "17 3 * * * root /usr/local/sbin/hermes-squid-log-rotate.sh >> /var/log/hermes-squid-rotate.log 2>&1" | sudo tee /etc/cron.d/hermes-squid-rotate >/dev/null && sudo chmod 644 /etc/cron.d/hermes-squid-rotate'
   ```

## Фаза 5. Настройка Гермеса (секреты вводит владелица)

1. Владелица в **отдельном терминале VS Code** (Terminal → New Terminal) запускает мастер и вводит ключи сама:
   ```bash
   ssh -t hermes-vps "sudo docker exec -it hermes-agent-hermes-agent-1 gosu hermes hermes setup model"
   ssh -t hermes-vps "sudo docker exec -it hermes-agent-hermes-agent-1 gosu hermes hermes setup gateway"
   ```
   В `setup gateway` — Telegram: токен бота и **её Telegram ID в список разрешённых**.
2. Проверь только имена ключей и права:
   ```bash
   ssh hermes-vps 'sudo grep -oE "^[A-Z_]+=" /docker/hermes-agent/data/.env; sudo stat -c "%a %U" /docker/hermes-agent/data/.env'
   ```
   Должны быть `TELEGRAM_BOT_TOKEN=` и `TELEGRAM_ALLOWED_USERS=`; не должно быть `*_ALLOW_ALL_USERS`. Права — `600`; если нет — `sudo chmod 600`.
3. Настройки без секретов:
   ```bash
   ssh hermes-vps 'C=hermes-agent-hermes-agent-1; sudo docker exec $C gosu hermes hermes config set privacy.redact_pii true; sudo docker exec $C gosu hermes hermes config get approvals.mode'
   ssh hermes-vps 'cd /docker/hermes-agent && sudo docker compose restart hermes-agent'
   ```
   Одобрение опасных команд — `smart` по умолчанию (как на соседнем сервере). Предложи `manual`, если она хочет подтверждать каждую рискованную команду в Telegram: `hermes config set approvals.mode manual`.
4. Проверка: она пишет боту — он отвечает. С чужого аккаунта бот работать не должен; если чужой пришлёт код pairing — не одобрять.

## Фаза 6. Веб-интерфейс

Вход в веб живёт 30 дней и не слетает при перезапуске (`DASHBOARD_AUTH_SECRET`).

### Вариант A — xray в Docker за Traefik (как на соседнем сервере)

1. Убедись, что адрес VPN-контейнера входит в `VPN_SOURCE_RANGE` (`172.16.0.0/12`):
   `ssh hermes-vps 'sudo docker inspect -f "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}}={{\$v.IPAddress}} {{end}}" <xray-контейнер>'`
   Если адрес `192.168.x.x` — поставь в `VPN_SOURCE_RANGE` подсеть этой сети. Если у xray `network_mode: host` — поставь `<публичный IP>/32`.
2. Включить (бэкап `.env` по правилу 3):
   ```bash
   ssh hermes-vps 'cd /docker/hermes-agent && sudo cp .env .env.pre-web-$(date +%Y%m%d) && sudo sed -i "s/^HERMES_WEB_VIA_VPN=.*/HERMES_WEB_VIA_VPN=true/" .env && sudo docker compose up -d'
   ```
   Пересоздаётся только `hermes-agent`, VPN не затрагивается.
3. Проверка владелицей: Happ **включён** → `https://hermes-agent.<TRAEFIK_HOST>` открывает страницу входа; Happ **выключен** → `403 Forbidden`.
   Если с включённым Happ тоже 403 — Happ пускает трафик к собственному серверу в обход туннеля. Проверить в Happ, что включён режим «весь трафик через VPN» и нет правила «напрямую» для этого адреса. Не помогло — пользоваться туннелем из варианта B (работает всегда), а `HERMES_WEB_VIA_VPN` вернуть в `false`.

### Вариант B — всё остальное: веб только через SSH-туннель

Ничего не публикуется. На её компьютере в `~/.ssh/config`:
```
Host hermes-web
  HostName <IP сервера>
  User NAME
  IdentityFile ~/.ssh/id_ed25519_hermes
  IdentitiesOnly yes
  LocalForward 4860 172.31.250.10:4860
  ExitOnForwardFailure yes
```
И в `~/.zshrc` (Mac):
```bash
alias hermes-web='ssh -fN hermes-web 2>/dev/null; open http://localhost:4860'
```
Проверка: `hermes-web` в новом терминале → открывается страница входа.

## Фаза 7. Проверка и финал

1. `ssh hermes-vps 'sudo bash -s' < scripts/verify.sh` → `ИТОГ: всё в порядке`. Любое `ПЛОХО` — разобрать с владелицей.
2. С её компьютера при **выключенном** VPN: `nc -vz -w5 <IP> 4860` — соединение не должно устанавливаться.
3. Команда для терминала — в `~/.zshrc`:
   ```bash
   alias hermes='ssh -t hermes-vps "sudo docker exec -it hermes-agent-hermes-agent-1 gosu hermes hermes"'
   ```
4. Снапшот в hPanel — точка «всё настроено».
5. Короткий отчёт владелице: что сделано, где пароль от веба (Bitwarden), как заходить (Telegram / `hermes` / веб), что `verify.sh` можно запускать в любой момент.

## Обслуживание

- **Обновление Гермеса:** бэкап `docker-compose.yml` (`.pre-update-<версия>-<дата>`), заменить digest образа `ghcr.io/hostinger/hvps-hermes-agent@sha256:…` на digest новой версии, `sudo docker compose pull && sudo docker compose up -d`, затем `verify.sh`. Не переходить на `:latest`.
- Никогда не запускать два контейнера Гермеса на одной папке `data/`.
- Бэкап данных агента в приватный git-репозиторий (как на соседнем сервере) — можно добавить позже отдельной задачей.
