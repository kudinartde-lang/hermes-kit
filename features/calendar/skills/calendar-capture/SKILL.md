---
name: calendar-capture
description: "Use when the person dictates a task or meeting to add to the calendar."
version: 1.0.0
---

# Занос задач в календарь

Календарь - Google. Техника - навык google-workspace (читать раздел Pitfalls). Первый раз нужен вход:
навык google-workspace, раздел First-Time Setup, только календарь (`--services calendar`).
Проверка входа: `$GSETUP --check` -> AUTHENTICATED.

```bash
GAPI="python ${HERMES_HOME:-$HOME/.hermes}/skills/google-workspace/scripts/google_api.py"
$GAPI calendar list --start 2026-10-01T00:00:00+03:00 --end 2026-10-07T23:59:59+03:00
$GAPI calendar create --summary "..." --start 2026-10-02T15:00:00+03:00 --end 2026-10-02T16:00:00+03:00 --description "..."
```
(Если скрипта нет по этому пути - `find "$HERMES_HOME" -name google_api.py`.)

## Порядок

1. Источник: текст или голосовое в Telegram или приложении, запись встречи файлом (расшифровка - навык local-media-transcription, если стоит).
2. Разобрать: что, дата, время, длительность (по умолчанию 1 час), место, с кем. Относительные даты ("в пятницу", "завтра") считать от текущей даты в часовом поясе человека (из настроек; Москва - смещение +03:00).
3. Голос распознаётся с огрехами - имена и время перепроверить по смыслу; неоднозначно - спросить одним вопросом.
4. Проверить list на пересечение по времени - сказать, если есть.
5. Показать коротко "Заношу: пт 02.10, 15:00-16:00, Встреча с ..., где. Ок?" и создать после подтверждения. Если человек разрешил заносить без подтверждения (записано в его AGENTS.md) - сразу создавать.
6. После создания - одна строка со ссылкой htmlLink.

Из записи встречи: вытащить все задачи с датами списком, предложить занести пачкой, человек отмечает нужные.

## Повторяющиеся события

В CLI нет флага повтора. Создавать через python из папки scripts навыка google-workspace: `import google_api as g`, тело с `'recurrence':['RRULE:FREQ=WEEKLY;BYDAY=WE']` и `timeZone` (например `Europe/Moscow`) в start и end (без timeZone повтор не работает), вставка через `g._run_gws(...)`, если `g._gws_binary()`, иначе `g.build_service('calendar','v3').events().insert(calendarId='primary', body=ev)`. Первое вхождение - ближайший нужный день недели.

Удалять и менять существующие события - только показав, что именно.
