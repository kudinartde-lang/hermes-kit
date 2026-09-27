# Шаг 5. Обновление набора у клиентов

Набор - профиль-дистрибутив Hermes. Обновление меняет только файлы набора
(SOUL.md, навыки, плагины, скрипты, расписание). Память помощника, переписки, ключи,
личные файлы человека (workspace/), папка local/ и общая база компании - не трогаются.

## Выпустить новую версию (у себя)

1. Поправить файлы набора.
2. В distribution.yaml поднять version (0.1.0 -> 0.2.0).
3. Коротко записать в CHANGELOG.md, что поменялось.
4. Отправить в репозиторий набора.

## Обновить у клиента (на его сервере)

    cd ~/hermes-kit && git pull
    tools/update-all.sh
    hermes gateway restart

update-all.sh обновляет основу всех помощников (hermes profile update) и заново ставит каждому
его выбранные фичи из свежего набора (tools/features.sh --reapply): навыки, плагины, скрипты,
расписание. Выбор человека (local/features) не меняется. Новая фича в наборе сама никому не ставится -
предложить людям: `tools/features.sh --id <id>`.

Шлюз подписок обновляется отдельно, когда в наборе одобрена новая версия (сторож шлюза сообщит):
`tools/pool-update.sh`.

- config.yaml при обновлении НЕ перезаписывается (правки клиента сохраняются).
  Нужно принудительно - `hermes profile update <id> --force-config` (правки клиента пропадут:
  сначала посмотреть, что там поменяли), потом `tools/features.sh --id <id> --reapply`
  (фичи pool и use-claude.sh пишут в config.yaml - после --force-config их надо поставить заново).
- Проверить версию: `hermes profile info anna`.

## Когда OpenAI меняет модели

Новые имена (например, следующая Astra) - поправить config.yaml набора (model, model_aliases,
auxiliary, delegation) и навык model-orchestration, выпустить версию. У уже установленных клиентов
config.yaml сам не обновится - на их сервере:

    hermes -p <id> config set model.default <новая-модель>
    hermes -p <id> config set model_aliases.astra.model <новая-модель>
