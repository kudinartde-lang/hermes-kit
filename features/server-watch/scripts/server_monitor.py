#!/usr/bin/env python3
"""Сторож нагрузки сервера Hermes.

Режимы:
  server_monitor.py            - проверка раз в 5 минут: пишет замер в историю,
                                 печатает тревоги (пустой вывод = тишина).
  server_monitor.py --digest   - утренняя сводка за сутки.
  server_monitor.py --status   - текущие цифры (для ручной проверки).

Ничего не убивает сам - только сообщает. Решение за владельцем.

Настройки (переменные окружения, все необязательные):
  MONITOR_EXPECT_PROXY=1   - ждать шлюз подписок CLIProxyAPI и тревожить, если его нет.
  MONITOR_ALL_USERS=1      - смотреть процессы всех пользователей (по умолчанию - только свои).
"""
import json, os, re, sys, time, shutil, subprocess

HOME = os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")
DIR = os.path.join(HOME, "monitor")
STATE = os.path.join(DIR, "state.json")
HIST = os.path.join(DIR, "history.jsonl")
CG = "/sys/fs/cgroup"

# Пороги
MEM_WARN, MEM_CRIT = 80, 95          # % от лимита контейнера (без кэша)
CPU_WARN = 85                        # % от квоты, держится 2 замера подряд (~10 мин)
DISK_WARN, DISK_CRIT = 80, 92
FORGOTTEN_MIN = 60                   # процесс вне белого списка живет дольше - подозрение
REPEAT_SEC = 3600                    # одну и ту же тревогу - не чаще раза в час
HIST_DAYS = 30

# Постоянные штатные процессы (подстроки командной строки)
WHITELIST = [
    "s6-", "/package/admin/", "/run/s6", "rc.init", "sleep infinity",
    "gateway run", "hermes serve", "hermes dashboard", "/bin/hermes",
    "cli-proxy-api", "server_monitor.py", "/lsp/",
    "systemd --user", "(sd-pam)", "sshd:", "-bash", "tmux",
]
EXPECT_PROXY = os.environ.get("MONITOR_EXPECT_PROXY") == "1"
ALL_USERS = os.environ.get("MONITOR_ALL_USERS") == "1"


def rd(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return default


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def cg_kv(name):
    out = {}
    for line in rd(os.path.join(CG, name)).splitlines():
        p = line.split()
        if len(p) == 2:
            out[p[0]] = int(p[1])
    return out


def mb(x):
    return round(x / 1048576)


def collect():
    now = time.time()
    # Память: лимит контейнера, реально занято = всё минус вытесняемый кэш
    mmax = rd(os.path.join(CG, "memory.max"), "max")
    mcur = int(rd(os.path.join(CG, "memory.current"), "0") or 0)
    st = cg_kv("memory.stat")
    if mmax == "max":
        mmax = int(rd("/proc/meminfo").split()[1]) * 1024
    mmax = int(mmax)
    real = max(0, mcur - st.get("inactive_file", 0))
    ev = cg_kv("memory.events")
    # CPU: квота контейнера
    q = rd(os.path.join(CG, "cpu.max"), "max 100000").split()
    cores = (int(q[0]) / int(q[1])) if q[0] != "max" else (os.cpu_count() or 1)
    cpu = cg_kv("cpu.stat")
    du = shutil.disk_usage(HOME)
    load1 = float(rd("/proc/loadavg", "0").split()[0])
    return {
        "ts": int(now), "mem_real": real, "mem_max": mmax,
        "mem_pct": round(real * 100 / mmax, 1), "anon": st.get("anon", 0),
        "oom_kill": ev.get("oom_kill", 0), "cpu_usec": cpu.get("usage_usec", 0),
        "throttled": cpu.get("nr_throttled", 0), "cores": round(cores, 2),
        "disk_pct": round(du.used * 100 / du.total, 1),
        "disk_free_gb": round(du.free / 1e9, 1), "load1": load1,
    }


def processes():
    """Список процессов: pid, возраст (мин), cpu-время (сек), память (МБ), команда."""
    try:
        who = ["-e"] if ALL_USERS else ["-u", str(os.getuid())]
        out = subprocess.run(["ps", *who, "-o", "pid=,ppid=,etimes=,times=,rss=,stat=,args="],
                             capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return []
    me = os.getpid()
    res = []
    for line in out.splitlines():
        p = line.split(None, 6)
        if len(p) < 7:
            continue
        pid, ppid, et, ct, rss, stat, args = p
        pid = int(pid)
        if pid == me or int(ppid) == me:
            continue
        res.append({"pid": pid, "age_min": int(et) // 60, "cpu_s": int(ct),
                    "rss_mb": int(rss) // 1024, "stat": stat, "cmd": args[:160]})
    return res


def suspicious(procs, prev_cpu):
    """Процессы вне белого списка, живущие дольше FORGOTTEN_MIN, и зомби."""
    out = []
    for p in procs:
        if p["stat"].startswith("Z"):
            p["why"] = "зомби"
            out.append(p)
            continue
        if any(w in p["cmd"] for w in WHITELIST):
            continue
        if p["cmd"].startswith(("ps ", "/usr/bin/bash -c source ")) \
                and p["age_min"] < FORGOTTEN_MIN:
            continue
        if p["age_min"] >= FORGOTTEN_MIN:
            before = prev_cpu.get(str(p["pid"]))
            idle = before is not None and p["cpu_s"] - before < 2
            p["why"] = "простаивает" if idle else "работает"
            out.append(p)
    return out


def human_age(m):
    return f"{m // 60} ч {m % 60} мин" if m >= 60 else f"{m} мин"


def fmt_proc(p):
    cmd = p["cmd"]
    if len(cmd) > 90:
        cmd = cmd[:90] + "…"
    return f"• PID {p['pid']} - {p['why']}, живет {human_age(p['age_min'])}, {p['rss_mb']} МБ\n  {cmd}"


def check():
    os.makedirs(DIR, exist_ok=True)
    state = load(STATE, {})
    cur = collect()
    prev = state.get("last")
    cpu_pct = None
    if prev and cur["ts"] > prev["ts"]:
        d_us = cur["cpu_usec"] - prev["cpu_usec"]
        cpu_pct = round(d_us / ((cur["ts"] - prev["ts"]) * 1e6 * cur["cores"]) * 100, 1)
    cur["cpu_pct"] = cpu_pct
    procs = processes()
    cur["top"] = sorted(({"cmd": p["cmd"][:70], "mb": p["rss_mb"]} for p in procs),
                        key=lambda x: -x["mb"])[:3]
    gw_ok = any("gateway run" in p["cmd"] for p in procs)
    px_ok = (not EXPECT_PROXY) or any("cli-proxy-api" in p["cmd"] for p in procs)
    susp = suspicious(procs, state.get("proc_cpu", {}))
    cur["suspicious"] = len(susp)

    with open(HIST, "a") as f:
        f.write(json.dumps({k: v for k, v in cur.items()}, ensure_ascii=False) + "\n")
    trim_history()

    # Активные проблемы: ключ -> текст
    active = {}
    if cur["mem_pct"] >= MEM_CRIT:
        active["mem"] = f"🔴 Память почти кончилась: {cur['mem_pct']}% ({mb(cur['mem_real'])} из {mb(cur['mem_max'])} МБ)."
    elif cur["mem_pct"] >= MEM_WARN:
        active["mem"] = f"🟡 Память высокая: {cur['mem_pct']}% ({mb(cur['mem_real'])} из {mb(cur['mem_max'])} МБ)."
    if cpu_pct is not None and cpu_pct >= CPU_WARN and (state.get("cpu_high") or 0) >= 1:
        active["cpu"] = f"🟡 Процессор загружен {cpu_pct}% уже больше 10 минут."
    if cur["disk_pct"] >= DISK_CRIT:
        active["disk"] = f"🔴 Диск почти полон: {cur['disk_pct']}%, свободно {cur['disk_free_gb']} ГБ."
    elif cur["disk_pct"] >= DISK_WARN:
        active["disk"] = f"🟡 Диск заполнен на {cur['disk_pct']}%, свободно {cur['disk_free_gb']} ГБ."
    if not gw_ok:
        active["gateway"] = "🔴 Шлюз Hermes (Телеграм) не запущен - помощники не отвечают в Телеграме."
    if not px_ok:
        active["proxy"] = "🔴 Шлюз подписок (CLIProxyAPI) не запущен."

    msgs = []
    # Разовые события: убитые из-за памяти процессы
    if prev and cur["oom_kill"] > prev.get("oom_kill", cur["oom_kill"]):
        n = cur["oom_kill"] - prev["oom_kill"]
        msgs.append(f"🔴 Из-за нехватки памяти убито процессов: {n}. Пора поднимать лимит памяти или искать, кто её съел.")
    # Новые подозрительные процессы - сообщаем один раз на процесс
    seen = set(state.get("susp_seen", []))
    new_s = [p for p in susp if f"{p['pid']}:{p['cmd'][:40]}" not in seen]
    if new_s:
        msgs.append("🧹 Похоже, остались лишние процессы (запущены не как постоянные службы):\n"
                    + "\n".join(fmt_proc(p) for p in new_s[:8])
                    + "\nНапиши агенту «проверь процессы» - разберусь и предложу, что выключить.")
    state["susp_seen"] = sorted({f"{p['pid']}:{p['cmd'][:40]}" for p in susp})

    alerts = state.get("alerts", {})
    now = cur["ts"]
    for k, text in active.items():
        a = alerts.get(k)
        if not a or now - a.get("sent", 0) >= REPEAT_SEC:
            msgs.append(text)
            alerts[k] = {"sent": now}
    for k in list(alerts):
        if k not in active:
            msgs.append(f"✅ Норма: {({'mem': 'память', 'cpu': 'процессор', 'disk': 'диск', 'gateway': 'шлюз Hermes', 'proxy': 'шлюз подписок'}).get(k, k)} - проблема ушла.")
            del alerts[k]

    state["alerts"] = alerts
    state["cpu_high"] = (state.get("cpu_high", 0) + 1) if (cpu_pct or 0) >= CPU_WARN else 0
    state["proc_cpu"] = {str(p["pid"]): p["cpu_s"] for p in procs}
    state["last"] = {k: cur[k] for k in ("ts", "cpu_usec", "oom_kill")}
    with open(STATE, "w") as f:
        json.dump(state, f)

    if msgs:
        print("Сервер Hermes:\n" + "\n\n".join(msgs))


def trim_history():
    try:
        if os.path.getsize(HIST) < 3_000_000:
            return
        cutoff = time.time() - HIST_DAYS * 86400
        with open(HIST) as f:
            lines = [l for l in f if json.loads(l).get("ts", 0) >= cutoff]
        with open(HIST, "w") as f:
            f.writelines(lines)
    except Exception:
        pass


def bar(pct):
    n = max(0, min(10, round((pct or 0) / 10)))
    return "▓" * n + "░" * (10 - n)


def digest(label="Утренняя сводка по серверу"):
    cur = collect()
    since = time.time() - 86400
    rows = []
    try:
        with open(HIST) as f:
            for l in f:
                r = json.loads(l)
                if r.get("ts", 0) >= since:
                    rows.append(r)
    except Exception:
        pass
    cpus = [r["cpu_pct"] for r in rows if r.get("cpu_pct") is not None]
    mems = [r["mem_pct"] for r in rows]
    avg = lambda xs: round(sum(xs) / len(xs), 1) if xs else 0
    procs = processes()
    susp = suspicious(procs, load(STATE, {}).get("proc_cpu", {}))
    oom_day = (rows[-1]["oom_kill"] - rows[0]["oom_kill"]) if len(rows) > 1 else 0

    # Прогноз диска по росту за сутки
    disk_note = ""
    if len(rows) > 12:
        grow = rows[-1]["disk_pct"] - rows[0]["disk_pct"]
        if grow > 0.05:
            days = (100 - cur["disk_pct"]) / grow
            disk_note = f", растет ~{round(grow, 2)}%/сутки (хватит на ~{int(days)} дн.)"

    L = [f"📊 {label}", ""]
    L.append(f"Процессор: {bar(avg(cpus))} в среднем {avg(cpus)}%, пик {max(cpus) if cpus else 0}% (квота {cur['cores']} ядра)")
    L.append(f"Память:    {bar(cur['mem_pct'])} сейчас {cur['mem_pct']}% ({mb(cur['mem_real'])} из {mb(cur['mem_max'])} МБ), пик за сутки {max(mems) if mems else cur['mem_pct']}%")
    L.append(f"Диск:      {bar(cur['disk_pct'])} {cur['disk_pct']}%, свободно {cur['disk_free_gb']} ГБ{disk_note}")
    L.append(f"Замеров за сутки: {len(rows)}. Убито из-за памяти: {oom_day}.")
    L.append("")
    L.append("Больше всех памяти едят:")
    for p in sorted(procs, key=lambda x: -x["rss_mb"])[:5]:
        cmd = re.sub(r"\S*/\.venv/bin/", "", p["cmd"])
        L.append(f"• {p['rss_mb']} МБ - {cmd[:70]}")
    L.append("")
    if susp:
        L.append(f"🧹 Лишние процессы ({len(susp)}):")
        L += [fmt_proc(p) for p in susp[:10]]
        L.append("Напиши «проверь процессы» - разберу и предложу, что выключить.")
    else:
        L.append("🧹 Забытых процессов нет.")
    # Совет
    peak = max(mems) if mems else cur["mem_pct"]
    L.append("")
    if peak >= MEM_WARN or oom_day:
        L.append("💡 Совет: память на пределе - пора добавить серверу памяти (тариф побольше).")
    elif cpus and avg(cpus) >= 60:
        L.append("💡 Совет: процессор загружен в среднем больше 60% - стоит подумать о сервере мощнее.")
    else:
        L.append("💡 Запас мощности есть, всё спокойно.")
    print("\n".join(L))


if __name__ == "__main__":
    if "--digest" in sys.argv:
        digest()
    elif "--status" in sys.argv:
        digest("Состояние сервера сейчас")
    else:
        check()
