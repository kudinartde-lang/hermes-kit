#!/usr/bin/env python3
"""pool-model-watch: сообщает в stdout (крон -> Telegram), если в пуле CLIProxyAPI
появились новые модели claude-*/gpt-* которых нет в эталоне pool-models-known.txt.
Пустой stdout = ничего не изменилось. После принятия решения эталон обновляется."""
import json, os, sys, urllib.request

HOME = os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")
KEY = open(os.path.join(HOME, "cliproxy", "client.key")).read().strip()
KNOWN_PATH = os.environ.get("POOL_MODELS_KNOWN") or os.path.join(HOME, "scripts", "pool-models-known.txt")

req = urllib.request.Request(os.environ.get("CLIPROXY_URL", "http://127.0.0.1:8317") + "/v1/models",
                             headers={"Authorization": f"Bearer {KEY}"})
try:
    data = json.load(urllib.request.urlopen(req, timeout=30))
except Exception as e:
    print(f"⚠️ pool-model-watch: шлюз не ответил: {e}")
    sys.exit(0)

current = sorted(m["id"] for m in data.get("data", []))
if not os.path.exists(KNOWN_PATH):
    open(KNOWN_PATH, "w").write("\n".join(current) + "\n")
    sys.exit(0)

known = set(open(KNOWN_PATH).read().split())
new = [m for m in current if m not in known]
gone = [m for m in known if m and m not in current]

if new or gone:
    lines = ["🆕 Пул подписок: изменился список моделей"]
    for m in new:
        lines.append(f"+ {m} (новая)")
    for m in gone:
        lines.append(f"− {m} (исчезла)")
    if any(m.startswith("claude-") for m in new):
        lines.append("Есть новая модель Claude — скажи помощнику «переведи меня на новую модель», "
                     "если хочешь перейти на неё.")
    print("\n".join(lines))
