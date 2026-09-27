#!/usr/bin/env python3
"""Следит за одной сессией Hermes и печатает новое с прошлого запуска.

session_watch.py <session_id> monitor  -> печатает id последнего сообщения (для гейта крона)
session_watch.py <session_id> digest   -> печатает новые сообщения с прошлого digest и сдвигает курсор
"""
import json, os, sqlite3, sys, time
from pathlib import Path

HOME = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
DB = str(HOME / "state.db")
TZ_H = float(os.environ.get("WATCH_TZ_OFFSET_HOURS", "3"))  # Москва
sid, mode = sys.argv[1], sys.argv[2]
(HOME / "cache").mkdir(exist_ok=True)
cursor_file = HOME / "cache" / f"session_watch_{sid}.cursor"

c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
last = c.execute("select max(id) from messages where session_id=?", (sid,)).fetchone()[0] or 0

if mode == "monitor":
    print(last)
    sys.exit(0)

start = int(cursor_file.read_text()) if cursor_file.exists() else last - 1
rows = c.execute(
    "select id, role, timestamp, content, tool_calls, tool_name from messages "
    "where session_id=? and id>? order by id", (sid, start)).fetchall()
now = time.time()
last_ts = c.execute("select max(timestamp) from messages where session_id=?", (sid,)).fetchone()[0] or 0
print(f"Сессия {sid}. Последняя активность {int((now-last_ts)/60)} мин назад. Новых сообщений: {len(rows)}.")
for mid, role, ts, content, tcalls, tname in rows:
    t = time.strftime("%H:%M", time.gmtime(ts + TZ_H * 3600))
    if role == "user":
        print(f"\n[{t} ЧЕЛОВЕК] {content}")
    elif role == "assistant":
        if content and content.strip():
            print(f"\n[{t} ПОМОЩНИК пишет]\n{content}")
        if tcalls:
            try:
                for tc in json.loads(tcalls):
                    fn = tc.get("function", {})
                    print(f"[{t} действие] {fn.get('name')}: {fn.get('arguments', '')[:300]}")
            except Exception:
                pass
    elif role == "tool":
        print(f"[{t} результат {tname}] {(content or '')[:200]}")
cursor_file.parent.mkdir(parents=True, exist_ok=True)
cursor_file.write_text(str(last))
