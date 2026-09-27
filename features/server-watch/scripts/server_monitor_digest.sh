#!/bin/sh
# Утренняя сводка по серверу (крон server-digest-morning, без ИИ).
exec python3 "$(dirname "$0")/server_monitor.py" --digest
