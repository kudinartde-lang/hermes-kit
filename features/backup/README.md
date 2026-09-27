# Ночной бэкап (backup) - только хранителю сервера

Каждую ночь в 3:00 копия всех помощников и общей базы в приватный GitHub компании. Ключи, пароли,
входы в подписки и переписки в бэкап не попадают.

    tools/features.sh --id anna --on backup
    tools/setup-backup.sh --repo git@github.com:<аккаунт>/<имя>-backup.git --keeper anna

До setup-backup.sh задача стоит на паузе. Подробно - docs/04-backup.md.
