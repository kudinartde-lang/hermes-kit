#!/usr/bin/env python3
"""Бэкап папки Hermes (все помощники + общая база) в приватный репозиторий на GitHub.

Что делает:
  1. коммитит всё, что не отсечено .gitignore корня Hermes;
  2. проверяет, нет ли в коммите живого ключа из .env любого профиля (есть - коммит отменяется);
  3. отправляет в приватный репозиторий по ssh (deploy key).
  Переписки (sqlite) по умолчанию НЕ бэкапятся; BACKUP_DB_DUMPS=1 - снимать их дампы в db-dumps/.

Запускается кроном (no-agent) или агентом руками.
Настройки (переменные окружения):
  BACKUP_DIR      - что бэкапить (по умолчанию корень Hermes: ~/.hermes);
  BACKUP_SSH_KEY  - deploy key репозитория (по умолчанию ~/.ssh/id_ed25519_hermes_backup).
Папку один раз готовит tools/setup-backup.sh из установочного набора.
Ничего не удаляет за пределами db-dumps/.
"""
from __future__ import annotations

import datetime as dt
import fcntl
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

def _root() -> Path:
    env = os.environ.get("BACKUP_DIR")
    if env:
        return Path(env).expanduser()
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes").expanduser()
    # из профиля (…/profiles/<имя>) поднимаемся к корню, чтобы в бэкап попали все помощники
    return home.parent.parent if home.parent.name == "profiles" else home


DATA = _root()
DUMPS = DATA / "db-dumps"
LOG = DATA / "logs" / "git-backup.log"
LOCK = DATA / "runtime" / "git-backup.lock"
SSH_KEY = Path(os.environ.get("BACKUP_SSH_KEY") or Path.home() / ".ssh" / "id_ed25519_hermes_backup").expanduser()
SSH_DIR = SSH_KEY.parent
MAX_BLOB_MB = 90  # GitHub жёстко отклоняет файлы больше 100 МБ

# папки, где sqlite искать не нужно (движок, кэши, браузер)
SKIP_DIRS = {
    "home", "bin", "core", "cache", "lazy-packages", "sandboxes",
    "image_cache", "audio_cache", "node_modules", "__pycache__", ".git",
    "db-dumps", ".agent-browser", ".npm", ".npm-global", ".cache", ".local",
}


def log(msg: str) -> None:
    stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {msg}"
    print(line, flush=True)
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    # пути задаём явно: HOME у процессов агента разный, на ~/.ssh полагаться нельзя
    if SSH_KEY.exists():
        cfg = SSH_DIR / "config"
        env["GIT_SSH_COMMAND"] = (
            (f"ssh -F {cfg}" if cfg.exists() else "ssh")
            + f" -o UserKnownHostsFile={SSH_DIR / 'known_hosts'}"
            f" -i {SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
        )
    return subprocess.run(
        ["git", "-C", str(DATA), *args],
        capture_output=True, text=True, check=check, env=env, timeout=1800,
    )


def find_sqlite_files() -> list[Path]:
    found: list[Path] = []
    for root, dirs, files in os.walk(DATA):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".git")]
        for name in files:
            if name.endswith((".db", ".sqlite", ".sqlite3")):
                found.append(Path(root) / name)

    # Состав бэкапа задаёт .gitignore. Сами файлы .db там исключены всегда (в репо
    # идут их дампы), поэтому спрашиваем git про КАТАЛОГ базы: лежит она в отсечённой
    # папке (хранилище ключей браузера, кэши) или в рабочей.
    if found:
        dirs_rel = sorted({str(p.parent.relative_to(DATA)) for p in found if p.parent != DATA})
        ignored: set[str] = set()
        if dirs_rel:
            res = subprocess.run(
                ["git", "-C", str(DATA), "check-ignore", "--stdin"],
                input="\n".join(dirs_rel), capture_output=True, text=True, timeout=120,
            )
            ignored = {line for line in res.stdout.split("\n") if line}
        found = [
            p for p in found
            if p.parent == DATA or str(p.parent.relative_to(DATA)) not in ignored
        ]

    return sorted(found)


# Секреты, которые могли попасть в переписку (владелец прислал ключ файлом, вставил
# токен и т.п.). В дамп для GitHub они уходят замаскированными; живая база на
# сервере не меняется.
SECRET_PATTERNS = re.compile(
    r"(GOCSPX-[A-Za-z0-9_-]{10,}"
    r"|sk-(?:ant-|proj-|kimi-|or-)?[A-Za-z0-9_-]{20,}"
    r"|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}"
    r"|AIza[0-9A-Za-z_-]{30,}"
    r"|ya29\.[A-Za-z0-9_-]{20,}|1//0[A-Za-z0-9_-]{20,}"
    r"|4/0A[A-Za-z0-9_-]{20,}"
    r"|\b[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}"
    r"|xox[bpas]-[A-Za-z0-9-]{10,}"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"
    r"|(?<=PRIVATE KEY-----)(?:\\n|\n)?[A-Za-z0-9+/=\\n\n]{40,})"
)


_SECRET_NAME = re.compile(r"KEY|TOKEN|SECRET|PASSWORD|PASS|AUTH", re.I)


def known_secret_values() -> list[str]:
    """Точные значения живых секретов сервера: .env, окружение контейнера, ключ шлюза.
    Ловят то, что не узнают шаблоны (например 64-символьный ключ шлюза без префикса)."""
    vals: set[str] = set()
    for env_file in [DATA / ".env", *sorted((DATA / "profiles").glob("*/.env"))]:
        try:
            for line in env_file.read_text(encoding="utf-8").splitlines():
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.split("=", 1)
                    if _SECRET_NAME.search(k):
                        vals.add(v.strip().strip('"').strip("'"))
        except OSError:
            pass
    for k, v in os.environ.items():
        # HERMES_SESSION_* - номера сессий, не секреты
        if _SECRET_NAME.search(k) and not k.startswith("HERMES_SESSION"):
            vals.add(v)
    try:
        vals.add((DATA / "cliproxy" / "client.key").read_text(encoding="utf-8").strip())
    except OSError:
        pass
    # короткие значения (id, true/false) не секреты и дали бы ложные срабатывания
    return sorted((v for v in vals if len(v) >= 12), key=len, reverse=True)


KNOWN_SECRETS = known_secret_values()


def redact(text: str) -> str:
    for v in KNOWN_SECRETS:
        if v in text:
            text = text.replace(v, v[:4] + "***REDACTED***")
    return SECRET_PATTERNS.sub(lambda m: m.group(0)[:6] + "***REDACTED***", text)


def staged_leaks() -> list[str]:
    """Файлы в коммите, где открытым текстом лежит живой секрет. Бэкап такой коммит не делает."""
    # --diff-filter=d: удалённые из бэкапа файлы не проверяем - они как раз уходят
    names = git("diff", "--cached", "--name-only", "--diff-filter=d", "-z", check=False).stdout.split("\0")
    bad = []
    for name in filter(None, names):
        p = DATA / name
        try:
            if not p.is_file() or p.stat().st_size > MAX_BLOB_MB * 1024 * 1024:
                continue
            data = p.read_bytes()
        except OSError:
            continue
        if any(v.encode() in data for v in KNOWN_SECRETS):
            bad.append(name)
    return bad


def sql_literal(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, bytes):
        return "X'" + value.hex() + "'"
    return "'" + redact(str(value)).replace("'", "''") + "'"


def dump_sqlite(conn: sqlite3.Connection, out) -> None:
    """Дамп, который разворачивается обратно.

    Штатный iterdump на этой базе даёт нерабочий файл: таблицы полнотекстового
    поиска (FTS5) он выгружает как обычные теневые таблицы, само объявление
    CREATE VIRTUAL TABLE теряется, и триггеры при восстановлении падают на
    несуществующей таблице. Поэтому: теневые таблицы пропускаем, виртуальные
    объявляем как есть, индекс поиска в конце пересобираем командой rebuild.
    """
    schema = list(conn.execute(
        "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL"
    ))
    virtual = {
        name for typ, name, sql in schema
        if typ == "table" and sql.strip().upper().startswith("CREATE VIRTUAL TABLE")
    }
    shadow_suffixes = (
        "_data", "_idx", "_docsize", "_config", "_content", "_stat", "_segdir",
        "_segments", "_docsize_idx",
    )
    shadow = {
        name for typ, name, _ in schema
        if typ == "table" and any(
            name == f"{v}{suf}" for v in virtual for suf in shadow_suffixes
        )
    }

    out.write("PRAGMA foreign_keys=OFF;\nBEGIN TRANSACTION;\n")

    # 1) обычные таблицы со своими данными
    for typ, name, sql in schema:
        if typ != "table" or name in virtual or name in shadow or name.startswith("sqlite_"):
            continue
        out.write(f"{sql};\n")
        cols = [r[1] for r in conn.execute(f"PRAGMA table_info([{name}])")]
        if not cols:
            continue
        col_list = ", ".join(f"[{c}]" for c in cols)
        for row in conn.execute(f"SELECT {col_list} FROM [{name}]"):
            values = ", ".join(sql_literal(v) for v in row)
            out.write(f"INSERT INTO [{name}] VALUES({values});\n")

    # 2) виртуальные таблицы: только объявление, содержимое пересоберётся
    for typ, name, sql in schema:
        if typ == "table" and name in virtual:
            out.write(f"{sql};\n")

    # 3) представления, триггеры, индексы - после того, как всё, на что они
    #    ссылаются, уже существует
    for wanted in ("view", "trigger", "index"):
        for typ, name, sql in schema:
            if typ == wanted and not name.startswith("sqlite_") and name not in shadow:
                out.write(f"{sql};\n")

    out.write("COMMIT;\n")
    for name in sorted(virtual):
        out.write(f"INSERT INTO [{name}]([{name}]) VALUES('rebuild');\n")


def dump_databases() -> tuple[int, int]:
    """Каждую базу -> текстовый .sql. Текст git дельтит в разы лучше бинарника."""
    DUMPS.mkdir(parents=True, exist_ok=True)
    ok = failed = 0
    live: set[str] = set()

    for db_path in find_sqlite_files():
        rel = db_path.relative_to(DATA)
        target = DUMPS / rel.with_suffix(rel.suffix + ".sql")
        live.add(str(target.relative_to(DUMPS)))
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp_copy = None
        try:
            # снимаем целостную копию средствами sqlite, не файловым cp
            fd, tmp_name = tempfile.mkstemp(suffix=".db", dir=str(DUMPS))
            os.close(fd)
            tmp_copy = Path(tmp_name)
            src = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=30)
            dst = sqlite3.connect(str(tmp_copy))
            with dst:
                src.backup(dst)
            src.close()

            with target.open("w", encoding="utf-8") as fh:
                dump_sqlite(dst, fh)
            dst.close()
            ok += 1
        except Exception as exc:  # noqa: BLE001 - одна битая база не должна ронять бэкап
            failed += 1
            log(f"  ! дамп {rel} не снялся: {type(exc).__name__}: {exc}")
        finally:
            if tmp_copy and tmp_copy.exists():
                tmp_copy.unlink()

    # чистим дампы баз, которых больше нет
    for stale in DUMPS.rglob("*.sql"):
        if str(stale.relative_to(DUMPS)) not in live:
            stale.unlink()
            log(f"  - убран дамп исчезнувшей базы: {stale.relative_to(DUMPS)}")

    return ok, failed


def drop_oversized() -> list[str]:
    """Файлы тяжелее лимита GitHub исключаем, иначе push отвергнут целиком."""
    dropped: list[str] = []
    res = git("ls-files", "-z", "--others", "--cached", "--exclude-standard")
    for rel in filter(None, res.stdout.split("\0")):
        path = DATA / rel
        try:
            size_mb = path.stat().st_size / 1024 / 1024
        except OSError:
            continue
        if size_mb > MAX_BLOB_MB:
            dropped.append(f"{rel} ({size_mb:.0f} МБ)")
            with (DATA / ".git" / "info" / "exclude").open("a", encoding="utf-8") as fh:
                fh.write(f"/{rel}\n")
            git("rm", "--cached", "--ignore-unmatch", "-q", rel, check=False)
    return dropped


def main() -> int:
    if not (DATA / ".git").exists():
        log(f"ОШИБКА: {DATA} не репозиторий, бэкап не настроен (tools/setup-backup.sh)")
        return 1

    LOCK.parent.mkdir(parents=True, exist_ok=True)
    lock_fh = LOCK.open("w")
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("прошлый бэкап ещё идёт, пропускаю такт")
        return 0

    log("=== бэкап начат ===")
    # Переписки (sqlite) по умолчанию НЕ уходят в бэкап: в чатах бывают персональные данные
    # клиентов компании. Включить осознанно: BACKUP_DB_DUMPS=1.
    if os.environ.get("BACKUP_DB_DUMPS") == "1":
        ok, failed = dump_databases()
        log(f"дампы баз: {ok} снято, {failed} не снялось")

    git("add", "-A", check=False)
    dropped = drop_oversized()
    for item in dropped:
        log(f"  ! слишком большой для GitHub, исключён: {item}")
    if dropped:
        git("add", "-A", check=False)

    status = git("status", "--porcelain")
    if not status.stdout.strip():
        log("изменений нет, коммит не нужен")
        log("=== бэкап закончен ===")
        return 0

    leaks = staged_leaks()
    if leaks:
        # имена файлов - не секрет; значения не печатаем
        log("ОШИБКА: в файлах для бэкапа открытым текстом лежит живой ключ, коммит отменён: "
            + ", ".join(leaks[:20]))
        git("reset", "-q", check=False)
        return 1

    changed = len(status.stdout.strip().splitlines())
    stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M")
    res = git("commit", "-q", "-m", f"бэкап {stamp}: файлов изменено {changed}", check=False)
    if res.returncode != 0:
        log(f"ОШИБКА коммита: {res.stderr.strip()[:500]}")
        return 1
    log(f"коммит сделан, файлов изменено {changed}")

    res = git("push", "origin", "HEAD:main", check=False)
    if res.returncode != 0:
        log(f"ОШИБКА push: {(res.stderr or res.stdout).strip()[:800]}")
        return 1
    log("push прошёл")
    log("=== бэкап закончен ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
