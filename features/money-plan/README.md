# План дня к деньгам (money-plan)

Нужна фича brain. Каждое утро вс-пт в 9:00 - план дня: три сценария, разбор, одна главная задача.
Сверка со вчерашним планом, план сохраняется в личную папку `me/daily-plans/`.

    tools/features.sh --id anna --on money-plan

Выходные или другое время: `hermes -p anna cron edit <id> --schedule "0 8 * * 1-5"`.
