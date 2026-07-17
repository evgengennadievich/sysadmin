# Diun Update Review — Example

**Дата:** YYYY-MM-DD
**Образ:** `<registry>/<image>:<old-tag>` → `<new-tag>`
**Старый digest:** `sha256:...`
**Новый digest:** `sha256:...`
**Источник:** Telegram-уведомление от Diun, чат `@<bot>`

> **Подсказка:** этот шаблон — стартовая точка. После заполнения переименуй файл
> в `diun-update-review-YYYY-MM-DD.md` и обезличь перед коммитом.

---

## Шаг 1: Что обновляется

Образ: `<registry>/<image>`
Текущая версия: `<old-tag>` (digest `sha256:<old-short>...`)
Новая версия: `<new-tag>` (digest `sha256:<new-short>...`)

**Что это за образ:** [одно-два предложения — назначение, роль в инфре]
**Где используется в инфре оператора:** [ссылка на `inventory/services.md` секцию]

## Шаг 2: Changelog

**Источник changelog:** [GitHub releases / Docker Hub / официальный сайт — точная ссылка]

**Ключевые изменения между текущей и новой версией:**

- [пункт 1 с цитатой из release notes]
- [пункт 2]
- [пункт 3]

> Цитаты из release notes — короткие. Полный текст — по ссылке выше.

## Шаг 3: Breaking changes / Security / Deprecations

**Breaking changes:** [список или «нет»]

- [конкретное изменение] — что сломается, как мигрировать

**Security fixes:** [CVE-ссылки или «нет»]

- CVE-XXXX-XXXXX — описание, severity, применимо ли к нашему сценарию

**Deprecations:** [список или «нет»]

- [фича] — будет удалена в версии X.Y, у нас используется/не используется

## Шаг 4: Кто использует

Список контейнеров на основе `inventory/services.md` + проверка по compose-файлам:

```bash
# Команда, которой агент проверял
grep -rE "image:.*<image>" /opt/*/docker-compose.yml
```

Результат:

```
<service-1>  — роль в системе, depends_on: [<x>, <y>]
<service-2>  — роль, depends_on: [<z>]
```

**Зависимые сервисы (если упадёт):** [перечисление цепочки]

## Шаг 5: Зона доверия

**Категория:**

- 🟢 **Зелёная** — только диагностика changelog, никаких изменений на сервере
- 🟡 **Жёлтая** — решение об обновлении с подтверждением оператора
- 🔴 **Красная** — если затрагивает stateful (postgres, redis с данными), требует 4-шаговой процедуры

**Обоснование выбора зоны:** [почему именно эта зона — конкретные критерии из персоны]

## Шаг 6: План отката

Команды для rollback к предыдущему digest:

```bash
# В /opt/<service>/docker-compose.yml — откатить image на предыдущий digest
sed -i 's|image: .*|image: <registry>/<image>@sha256:<old-digest>|' /opt/<service>/docker-compose.yml

# Pull старого образа (если purge'нут локально)
docker pull <registry>/<image>@sha256:<old-digest>

# Restart с откатом
cd /opt/<service> && docker compose up -d <service>

# Проверка
docker exec <service> <healthcheck-command>
```

**Ожидаемое время отката:** ~N минут.
**Что проверить после отката:** [healthcheck endpoints, ключевые метрики, логи]

## Шаг 7: Рекомендация

**Конкретное действие:** ⬜ Обновлять сейчас / ⬜ Отложить до YYYY-MM-DD / ⬜ Не обновлять

**Обоснование:**

- [пункт 1 — например: «security fix критичен, наш стек подвержен»]
- [пункт 2 — например: «breaking changes не затрагивают наши use-case»]
- [пункт 3 — например: «changelog подтверждает совместимость с нашей версией postgres»]

**Если обновлять — план:**

1. [шаг 1: например, бэкап БД перед обновлением]
2. [шаг 2: pull новый образ]
3. [шаг 3: rolling restart с healthcheck]
4. [шаг 4: проверка после]

**Подтверждение оператора:** ⬜ получено / ⬜ ожидается / ⬜ type-to-confirm для красной зоны

---

**Артефакт записан:** `examples/agent-in-action/diun-update-review-YYYY-MM-DD.md`
**Связанные документы:** `inventory/services.md`, `decisions/00NN-...md` (если решение зафиксировано в ADR)
**Last verified:** YYYY-MM-DD (заполняется после применения разбора в продакшене)
