---
name: inventory-scan
description: |
  Read-only инвентаризация сервера: dump-snapshot.sh → 9 текстовых документов в inventory/
  (services, networks, volumes, databases, domains, cron, host-scripts, automations, server).
  Сравнение с прошлым inventory с выделением drift'ов + чек «хлам» (сироты-volume, сети вне
  эталона, дубли compose). Диаграммы не генерирует (ADR-0019: источник фактов — снимок,
  витрина — дашборд). Green Zone.
  Триггеры: «инвентаризация», «снять снимок сервера», «что у меня на сервере», «обновить inventory»,
  «scan server», «inventory drift», «refresh inventory».
  НЕ для изменений на сервере (это cleanup-existing-server и др.); НЕ для аудита безопасности
  (audit-security).
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я снимаю полный снимок реального состояния сервера, генерирую или обновляю текстовый
inventory и выделяю drift'ы между документацией и реальностью. Я работаю в Green Zone —
только чтение, никаких изменений на сервере.
</role>

<context>
Что предполагается:
- SSH-доступ к серверу настроен (агентский ключ, BatchMode=yes работает)
- Docker установлен и работает на сервере
- Структура `inventory/hosts/<host>/` существует или будет создана при первом запуске

Что НЕ предполагается:
- Mock-сервер или dry-run — скилл нужен для реального снимка реальности
- Изменение состояния сервера — это Yellow/Red Zone, для них есть другие скиллы
  (cleanup-existing-server, deploy-service)
- Наличие свежего бэкапа — скилл read-only, бэкапы не нужны
</context>

<goals>
После выполнения:
- Snapshot создан в `inventory/hosts/<host>/snapshots/YYYY-MM-DD/`
- Snapshot содержит все ожидаемые файлы (containers, networks, volumes, host-resources,
  crontab, nginx-sites, tls-certs, host-scripts-content, host-env-redacted, cron-d-content,
  systemd-enabled, systemd-timers, watchers, compose-files, containers-inspect.json,
  health-flags) — проверяется по непустоте ключевых, не по суммарному размеру
- 9 inventory-документов в `inventory/hosts/<host>/` обновлены или созданы из шаблона
  (`automations.md` — только при наличии хоть одной автоматизации)
- Drift между inventory и реальностью явно обозначен в `drift-report.md` свежего snapshot
- Honest unknown применён везде, где данные отсутствуют (`? уточнить` или `нет данных` —
  никаких выдуманных значений)
</goals>

# Параметры

| Параметр | Default | Описание |
|----------|---------|----------|
| `SSH_HOST` | (обязательный) | SSH-target — `user@<your-server-ip>`, SSH-алиас из `~/.ssh/config` или `local` (без SSH) |
| `INVENTORY_DIR` | `inventory` | Корневая папка inventory (относительно репо) |
| `SNAPSHOT_DATE` | `$(date +%Y-%m-%d)` | Дата снимка (формат YYYY-MM-DD) |
| `RETENTION_SNAPSHOTS` | `10` | Сколько последних snapshots оставлять |

# Процедура

## Шаг 1. Pre-check

Проверяю предусловия одной командой:

```bash
# SSH-доступ
ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" 'echo ok' || {
  echo "ОШИБКА: SSH-доступ к $SSH_HOST не настроен"; exit 1; }

# Существующий inventory
mkdir -p "$INVENTORY_DIR/hosts/"

# Конкурентный лок (P22): два одновременных скана пишут в одни файлы → гонка.
# Атомарно через mkdir (НЕ -p: падает, если каталог уже есть). Зависший лок
# старше 30 мин (предыдущий скан упал) снимаем как stale.
LOCK="$INVENTORY_DIR/.scan.lock"
[ -d "$LOCK" ] && find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null | grep -q . && {
  echo "→ лок старше 30 мин — снимаю как зависший (stale)."; rm -rf "$LOCK"; }
if mkdir "$LOCK" 2>/dev/null; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$LOCK/started_at" 2>/dev/null
  echo "→ лок inventory-scan взят: $LOCK"
else
  echo "СТОП: уже идёт inventory-scan (лок $LOCK, начат $(cat "$LOCK/started_at" 2>/dev/null || echo '?'))."
  echo "      Дождись его завершения. Если уверен, что скан не идёт — сними лок: rm -rf \"$LOCK\"."
  exit 1
fi
```

Если SSH не настроен — стоп, без выдумывания «возможно, ключ ниже». Прошу оператора
проверить ключ и повторить. **Лок держится до Шага 7** (снимается в конце или при отмене —
освобождаю `rm -rf "$LOCK"`, чтобы не заблокировать следующий скан).

## Шаг 2. Запуск dump-snapshot.sh

**Каноничное имя папки хоста — из `infra-config.json` `servers[].alias`**, не из
SSH-аргумента: иначе алиас `selectel` создаст `prod-selectel` вместо записанного
`prod-82.148.28.22` и раздвоит inventory (находка /retro 2026-06-14). Резолвлю канон и
передаю в скрипт через env `HOST_DIR` — при расхождении с SSH-target скрипт громко
предупредит и возьмёт канон:

```bash
INFRA="$(dirname "$INVENTORY_DIR")"
HOST_DIR="$(jq -r '.servers[0].alias // empty' "$INFRA/infra-config.json" 2>/dev/null)"
export HOST_DIR   # пусто → скрипт выведет из SSH-target (fallback)
bash scripts/dump-snapshot.sh "$SSH_HOST" "$SNAPSHOT_DATE" "$INVENTORY_DIR"
```

Скрипт собирает (через single-shot SSH с timeout 10c):

- Список и inspect контейнеров (`containers.txt`, `containers-inspect.json`)
- Список compose-файлов (`compose-files.txt`)
- Docker-сети и volumes (`networks.txt`, `volumes.txt`)
- Ресурсы хоста — uptime, память, диск, открытые порты, доступные APT-обновления
  (`host-resources.txt`)
- Crontab + `/etc/cron.d/*` (`crontab.txt`, `cron-d-content.txt`)
- nginx-конфиг через `nginx -T` (`nginx-sites.txt`)
- TLS-сертификаты (letsencrypt + acme.sh) — **даты валидности** через `openssl x509`
  (`tls-certs.txt`); openssl бежит по обоим источникам (фикс /retro)
- Список и содержимое host-скриптов в `/opt/*.sh` (`host-scripts-list.txt`,
  `host-scripts-content.txt`)
- Структура .env-файлов на хосте (имена переменных, значения redacted)
  (`host-env-redacted.txt`)
- Включённые systemd-юниты (`systemd-enabled.txt`)
- systemd-таймеры оператора — расписание наравне с cron на Ubuntu 24.04 (`systemd-timers.txt`)
- Скрипты-наблюдатели — долгоживущие процессы inotify/fswatch/watchdog,
  слушающие события, а не запускаемые по расписанию (`watchers.txt`)
- Готовая сводка здоровья хоста (`health-flags.txt`) — swap%, disk%, loadavg,
  exited-контейнеры, OOM-коды 137, число отложенных apt/security-обновлений
- Метаданные снимка (`meta.txt`)

**Verify по СОДЕРЖАНИЮ, не по суммарному размеру.** Малый сервер даёт снимок <1 МБ — это
норма, а не сбой (порог «≥1 МБ» давал false-negative на валидном снимке 324 КБ — находка
/retro). Проверяю непустоту ключевых файлов и парсинг JSON:

```bash
SNAPSHOT_DIR="$INVENTORY_DIR/hosts/$HOST_DIR/snapshots/$SNAPSHOT_DATE"
ok=1
for f in containers.txt networks.txt host-resources.txt; do
  [ -s "$SNAPSHOT_DIR/$f" ] || { echo "ОШИБКА: пустой ключевой файл $f"; ok=0; }
done
jq -e . "$SNAPSHOT_DIR/containers-inspect.json" >/dev/null 2>&1 \
  || { echo "ОШИБКА: containers-inspect.json не парсится"; ok=0; }
[ "$ok" = 1 ] || { echo "ОШИБКА: snapshot неполный"; exit 1; }
```

Где `$HOST_DIR` = канон из `infra-config.json` (`prod-<ip>` для удалённых или
`local-<hostname>` для локальной машины).

## Шаг 3. Сравнение с существующим inventory

Две независимые оси сравнения — **не смешивать** (находка /retro: их смешение даёт
«мнимый drift», когда снимок просто старее обновлённого inventory):

**Ось A — что изменилось на сервере** (снимок-к-снимку, стабильный источник
`containers-inspect.json`, НЕ grep по рукописному `services.md`):

```bash
HOSTD="$INVENTORY_DIR/hosts/$HOST_DIR"
PREV="$(ls -1d "$HOSTD/snapshots"/*/ 2>/dev/null | sort | tail -2 | head -1)"
diff <(jq -r '.[].Name' "$PREV/containers-inspect.json" 2>/dev/null | sed 's#^/##' | sort) \
     <(jq -r '.[].Name' "$SNAPSHOT_DIR/containers-inspect.json"      | sed 's#^/##' | sort)
```

**Ось B — что не задокументировано** (реальность ↔ `services.md`). `services.md` ведёт
контейнеры **таблицей** `| имя | … |`, поэтому проверяю присутствие каждого имени как
ячейки, а не паттерном `container_name:` (его в формате нет — давал ложный drift на все
контейнеры):

```bash
for name in $(jq -r '.[].Name' "$SNAPSHOT_DIR/containers-inspect.json" | sed 's#^/##'); do
  grep -qE "^\| *$name *\|" "$HOSTD/services.md" || echo "drift+ (не задокументирован): $name"
done
```

**Тома** сверяю по ИМЕНАМ (`docker volume ls` — часть `volumes.txt` ДО строки `---`),
не по `docker system df` (волатильные относительные даты `3 weeks ago` дают шум-diff).

Drift-категории: **drift+** (есть в реальности, нет в inventory) / **drift-** (есть в
inventory, нет в реальности) / **drift~** (расхождение полей — порт, образ, статус).

**Чек «хлам»** (якорь §3.10 персоны, «как в аптеке») — отдельная секция drift-отчёта:

```bash
# 1. Анонимные volume без потребителей (сироты restore-тестов/миграций)
grep -E "^local +[0-9a-f]{64}$" "$SNAPSHOT_DIR/volumes.txt" || true
# в volumes.txt (docker system df -v) сирота = LINKS 0 у hash-имени
# 2. Сети вне эталона: всё, что не {data, services, proxy-corridor/xray, monitoring,
#    bridge, host, none} — особенно автосети compose <project>_default
# 3. Дубли compose: один container_name в двух working_dir
jq -r '.[] | .Name + "\t" + (.Config.Labels["com.docker.compose.project.working_dir"] // "-")' \
  "$SNAPSHOT_DIR/containers-inspect.json"
# + сверить compose-files.txt: файлы, не породившие ни одного контейнера
# 4. Публичные порты (0.0.0.0/*) из host-resources.txt без владельца в services/server.md
```

Каждая находка — в секцию `## Хлам` drift-отчёта с предложением сноса. Сам не удаляю
(Green Zone + C.7) — решает оператор.

Результат — `$SNAPSHOT_DIR/drift-report.md`. Нет drift'ов — пишу «drift'ов не найдено,
inventory синхронен». **Мнимый drift** (снимок старее, чем уже обновлённый inventory)
помечаю отдельно как объяснённый, не как реальное расхождение.

## Шаг 4. Обновление 9 inventory-документов

Для каждого документа (services / networks / volumes / databases / domains / cron /
host-scripts / automations / server):

- Если документ существует — `Edit` правлю изменённые строки, добавляю пометку
  `<!-- snapshot YYYY-MM-DD: было X, стало Y -->` рядом со старым значением
- Если не существует — генерирую из `templates/inventory-doc-template.md`,
  подставляю данные из snapshot

Никогда не переписываю файл с нуля — теряется история ручных правок и комментариев
оператора.

**`automations.md` — сводная витрина (генерируется только при наличии автоматизаций).**
Это «оглавление всего, что работает само». Колонки: `name | trigger | schedule | runs |
touches | log | status`. Агрегирую данные из четырёх источников:

- `crontab.txt` / `cron-d-content.txt` → trigger `cron`
- `systemd-timers.txt` → trigger `systemd-timer` (расписание из `list-timers`, что
  запускается — из парного `*.service` юнита)
- `watchers.txt` → trigger `watcher` (событие, не расписание)
- `host-scripts-content.txt` → чем pipeline/скрипт занят (для колонки `touches`)

Колонка `touches` — главная: что автоматизация трогает (БД из `databases.md`, сервис
из `services.md`, внешний API — Telegram/RSS/Claude). Это источник связей для сборщика
дашборда (ADR-0019). Не дублирую `cron.md`/`host-scripts.md` слово в слово —
агрегирую и осмысляю. Если автоматизаций на сервере нет — документ не создаю.

## Шаг 5. Honest unknown — везде

Если данные не получены (snapshot-файл пустой, syntax error, поле отсутствует) —
ставлю `? уточнить` или `нет данных`. **NEVER** выдумываю правдоподобные значения.

Это правило перекрывает любые другие — лучше пустое поле, чем красивая ложь.
Подробнее — `references/dump-snapshot-quirks.md` (известные баги и их симптомы).

## Шаг 6. Cleanup старых snapshots

```bash
# Оставляем последние RETENTION_SNAPSHOTS, остальные удаляем
find "$INVENTORY_DIR/hosts/<host>/snapshots/" -mindepth 1 -maxdepth 1 -type d \
  | sort -r | tail -n +$((RETENTION_SNAPSHOTS+1)) | xargs -r rm -rf
```

Сортировка по имени (snapshots датированы), не по `-mtime` — `find -mtime +N` округляет
вниз до целых дней (типичная грабля при чистке временных файлов).

## Шаг 7. Отчёт оператору

Формирую короткий отчёт в чат:
- Дата и путь нового snapshot
- **Сводка здоровья из `health-flags.txt`** — подаю готовое (swap%, disk%, loadavg,
  exited-контейнеры, OOM-137, отложенные apt/security-обновления), не грепаю сырьё руками
- **Enforcement `automations.md`:** если в снимке есть автоматизации (непустые cron/
  systemd-timers/watchers), а `inventory/hosts/$HOST_DIR/automations.md` отсутствует —
  отдельной строкой «автоматизации есть, витрина не создана → нужен Шаг 4»
- Список drift'ов (если найдены) — с категориями + / - / ~; мнимый drift помечен отдельно
- **Секция «Хлам»** (если чек Шага 3 что-то нашёл): каждая находка с предложением сноса
- Список изменённых inventory-документов
- Рекомендации, если нужно: что ещё проверить вручную

Освобождаю конкурентный лок (взят на Шаге 1) — иначе следующий скан упрётся в «уже идёт»:

```bash
rm -rf "$LOCK"   # $INVENTORY_DIR/.scan.lock — снять в конце ИЛИ при любой отмене/ошибке
```

# Failed Attempts (граблекейс)

- **«tls-certs.txt syntax error»** — известный баг dump-snapshot v1, в v2 исправлен
  через `set +e` вокруг openssl-вызова. Симптом: tls-certs.txt пустой или содержит
  «openssl: unknown option». Лечение: убедиться, что используется bundled
  `scripts/dump-snapshot.sh` (v2), а не старый из `~/scripts/`.
- **«SSH-alias из ~/.ssh/config не работает в bash sandbox»** — sandbox запускает bash
  без загрузки пользовательской конфигурации SSH. Лечение: использовать прямой
  `user@host` вместо алиаса, ключ через `-i` если нужен явный.
- **«find -mtime +N округляет вниз»** — `find -mtime +1` найдёт файлы старше **2 дней**,
  а не 1. Для retention снимков использовать сортировку по имени, не -mtime.
- **«python-regex редакция не покрывает все паттерны»** — `host-env-redacted.txt`
  маскирует только `=value`, но в URL вида `postgres://user:pass@host` пароль
  виден. Лечение: добавлять новые regex-паттерны при обнаружении (см.
  `references/dump-snapshot-quirks.md`).
- **«ложный drift на все контейнеры»** — ИСПРАВЛЕНО (находка /retro 2026-06-14). Симптом:
  Шаг 3 грепал `container_name:` по `services.md`, а тот ведёт контейнеры таблицей
  `| имя | … |` → diff показывал «20 недокументированных». Лечение: ось A — снимок-к-снимку
  по `containers-inspect.json`; ось B — таблично-aware проверка имени в `services.md`.
- **«TLS-expiry не считается на acme.sh-хостах»** — ИСПРАВЛЕНО (находка /retro 2026-06-14).
  Симптом: `tls-certs.txt` содержал только `ls -la` (даты файлов), хотя description обещает
  «даты валидности». Причина: openssl бежал только по `/etc/letsencrypt/live`. Лечение:
  `openssl x509 -enddate` теперь и по `~/.acme.sh/*/fullchain.cer`.
- **«HOST_DIR из SSH-аргумента раздваивал inventory»** — ИСПРАВЛЕНО (находка /retro
  2026-06-14). Симптом: алиас `selectel` → папка `prod-selectel` вместо записанной
  `prod-82.148.28.22`. Лечение: канон из `infra-config.json` `servers[].alias` через env
  `HOST_DIR`; при расхождении с SSH-target скрипт громко предупреждает и берёт канон.
- **«verify заваливал валидный малый снимок»** — ИСПРАВЛЕНО (находка /retro 2026-06-14).
  Симптом: порог «размер ≥1 МБ» — false-negative на снимке 324 КБ. Лечение: проверка
  непустоты ключевых файлов + парсинг `containers-inspect.json` через jq, не суммарный размер.
- **«секреты в containers-inspect.json»** — ИСПРАВЛЕНО (redaction v1). Скрипт
  маскирует env-секреты (`KEY=value` и креды в URL) **до записи на диск** —
  не полагаясь только на `.gitignore`. Метки в `meta.txt`: `redaction_applied: true`.
  Подробности — `references/dump-snapshot-quirks.md`. gitleaks по этому файлу больше
  не должен находить реальных секретов; имена переменных (`*_API_KEY=<REDACTED>`)
  остаются для аудита.

# Граничные случаи

- **Сервер недоступен (down)** — скилл валит с явной ошибкой ещё на Pre-check, не
  генерирует пустой snapshot
- **Disk full на сервере** — некоторые секции snapshot частично собраны, отчёт явно
  говорит «частичный snapshot, причина: disk full». В drift-report не доверяем
  частичным данным
- **Контейнер в restart loop** — попадает в snapshot со статусом `Restarting (N)`,
  в drift-report помечается отдельно как «требует внимания»
- **Несколько серверов** — переключаются параметром `SSH_HOST`. Не запускать
  одновременно (нет locking) — снимки будут вперемешку
- **Локальный режим (`SSH_HOST=local`)** — собирает данные с локальной машины через
  `eval`, не SSH. Полезно для разработки или mock-инфраструктуры

# Bundled resources

- `scripts/dump-snapshot.sh` — основной dump-скрипт (v2, копия из
  `scripts/inventory/dump-snapshot.sh` проекта-носителя)
- `templates/inventory-doc-template.md` — общий шаблон inventory-документа
- `references/dump-snapshot-quirks.md` — известные баги, симптомы, обходы