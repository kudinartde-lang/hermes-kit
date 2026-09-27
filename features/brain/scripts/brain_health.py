#!/usr/bin/env python3
"""Здоровье второго мозга: сводка для ежемесячной проверки (только чтение).

Запуск: brain_health.py [папка базы] [файл правил AGENTS.md]
Без аргументов берет BRAIN_DIR и AGENTS_FILE из окружения.

Печатает: устаревшие документы (checked старше N дней), документы без шапки,
размер карты INDEX.md, размер AGENTS.md, возможные дубли фактов (одинаковые суммы
в разных файлах), изменения за последние 31 день из log.md, результат brain_check.
"""
import re
import subprocess
import sys
from datetime import date, timedelta
from pathlib import Path

import os
_home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes").expanduser()
_args = [a for a in sys.argv[1:] if not a.startswith("-")]


def _local(name, default):
    """Путь из local/<name> профиля (пишет tools/add-person.sh; папка local/ переживает обновления набора)."""
    f = _home / "local" / name
    return f.read_text(encoding="utf-8").strip() if f.is_file() else default


BASE = Path(_args[0] if _args else os.environ.get("BRAIN_DIR") or _local("brain-dir", _home / "company" / "brain")).expanduser()
AGENTS = Path(_args[1] if len(_args) > 1 else os.environ.get("AGENTS_FILE") or _local("agents-file", _home / "AGENTS.md")).expanduser()
CHECK = next((p for p in (_home / "skills" / "second-brain" / "scripts" / "brain_check.py",
                          _home / "skills" / "productivity" / "second-brain" / "scripts" / "brain_check.py")
              if p.exists()), _home / "skills" / "second-brain" / "scripts" / "brain_check.py")
STALE_DAYS = 60
today = date.today()

def header(text):
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        return None
    out = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip()] = v.split("#")[0].strip()
    return out

docs = [p for p in sorted(BASE.rglob("*.md"))
        if "archive" not in p.parts and p.name not in {"INDEX.md", "RULES.md", "log.md"}]
stale, nohead, drafts = [], [], []
money = {}
for p in docs:
    rel = p.relative_to(BASE).as_posix()
    t = p.read_text(encoding="utf-8")
    h = header(t)
    if not h:
        nohead.append(rel)
    else:
        try:
            d = date.fromisoformat(h.get("checked", ""))
            if (today - d).days > STALE_DAYS:
                stale.append(f"{rel} (проверено {d}, {(today - d).days} дн назад)")
        except ValueError:
            stale.append(f"{rel} (нет даты проверки)")
        if h.get("status") == "черновик":
            drafts.append(rel)
    for m in re.finditer(r"\d[\d\s]{1,9}\s?(?:тыс|млн|руб|₽)", t):
        money.setdefault(re.sub(r"\s+", " ", m.group(0)), set()).add(rel)

print(f"# Здоровье второго мозга на {today}")
print(f"Документов: {len(docs)}")
idx = (BASE / "INDEX.md").read_text(encoding="utf-8")
print(f"INDEX.md: {len(idx)} знаков, {idx.count('[[')} ссылок" + ("  <- БОЛЬШЕ 8000, пора делить на карты разделов" if len(idx) > 8000 else ""))
a = AGENTS.read_text(encoding="utf-8") if AGENTS.exists() else ""
print(f"AGENTS.md: {len(a)} знаков" + ("  <- БОЛЬШЕ 10000, пора сжимать" if len(a) > 10000 else ""))
print(f"\n## Не проверялись больше {STALE_DAYS} дней ({len(stale)})")
print("\n".join("- " + s for s in stale) or "- нет")
print(f"\n## Черновики ({len(drafts)})")
print("\n".join("- " + s for s in drafts) or "- нет")
print(f"\n## Без шапки ({len(nohead)})")
print("\n".join("- " + s for s in nohead) or "- нет")
print("\n## Одинаковые суммы в нескольких файлах (возможные дубли - проверить, что в одном месте факт, в других ссылка)")
dups = [(k, v) for k, v in money.items() if len(v) > 2]
print("\n".join(f"- {k}: {', '.join(sorted(v))}" for k, v in dups[:15]) or "- нет")
print("\n## Изменения за 31 день (log.md)")
since = today - timedelta(days=31)
n = 0
for line in (BASE / "log.md").read_text(encoding="utf-8").splitlines():
    m = re.match(r"## \[(\d{4}-\d{2}-\d{2})\]", line)
    if m and date.fromisoformat(m.group(1)) >= since:
        print(line[3:]); n += 1
print(f"Всего записей: {n}")
print("\n## Проверка ссылок")
r = subprocess.run([sys.executable, str(CHECK), "check", str(BASE)], capture_output=True, text=True)
errs = [l for l in r.stdout.splitlines() if "ОШИБКА" in l and "входной файл" not in l]
print("\n".join(errs) or "- ошибок нет")
