# Выбор модели под задачу (models)

Навык model-orchestration: три роли - сильная (`/model strong`), основная (`/model main`),
лёгкая (`/model light`). Помощник сам берёт сильную для стратегий и важных решений, основную для
обычной работы, лёгкую для служебного. Работает с любыми подписками: только ChatGPT
(по умолчанию GPT-6 Astra/Sol/Luna), только Claude (`tools/use-claude.sh`) или шлюз подписок (фича pool).

    tools/features.sh --id anna --on models
