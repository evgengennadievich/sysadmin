---
name: install-monitoring-stack
description: |
  Опциональный мониторинг-стек: Uptime Kuma + Beszel + Dozzle + Dockge + Diun + Telegram.
  Параметр COMPONENTS — можно только Kuma или весь набор. Все версии запинены (без latest),
  nginx vhost с Basic Auth + Let's Encrypt, Kuma через socket.io API 2.x. RAM-бюджет 200-350 МБ.
  Триггеры: «хочу дашборд», «поставь мониторинг», «Uptime Kuma + Beszel», «нужны глаза на сервер»,
  «monitoring stack».
  НЕ для серверов <2 ГБ RAM; НЕ для VPN-панели (для этого — отдельный скилл VPN-блока).
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я разворачиваю опциональный мониторинг-стек так, чтобы оператор мог увидеть состояние
сервера за секунду, а агент — узнать о проблеме раньше пользователя. Состав стека —
параметрический: можно начать с одной Kuma, можно сразу весь набор.
</role>

<context>
Что предполагается на сервере:
- Docker и docker compose установлены
- nginx установлен и настроен как reverse-proxy (для нескольких компонентов)
- Домен резолвится: `dig +short panel.<DOMAIN>` возвращает IP сервера
- Свободно >= 350 МБ RAM (если ставить весь стек)
- Telegram-бот создан (если COMPONENTS включает telegram), есть BOT_TOKEN и CHAT_ID

Что НЕ предполагается:
- Установка Docker/nginx с нуля (отдельный скилл `bootstrap-new-server`)
- Настройка домена и DNS (делает оператор)
- Создание Telegram-бота (делает оператор через @BotFather)
</context>

<goals>
После выполнения должно стать TRUE:
- Compose-файлы установлены в `$INSTALL_DIR` со всеми выбранными компонентами
- Все контейнеры в статусе running, проходят health-check
- nginx vhost `panel.$DOMAIN` отдаёт компоненты с Basic Auth + TLS (Let's Encrypt)
- Kuma настроен через socket.io API (первичная учётка + Telegram notification provider)
- Beszel hub настроен, agent сопряжён с hub, метрики поступают
- Тестовый алерт в Telegram доходит (Kuma создаёт тестовый монитор и отправляет проверку)
- Запись в `inventory/services.md` обновлена — добавлены новые контейнеры
</goals>

# Шаг 0: Чтение конфига (STRICT)

Скилл — STRICT-режим: без конфига инфры (`infra-config.json`) он не запускается. Конфиг определяет, что именно ставить (стек, домен, Telegram), и явно фиксирует «оператор хочет мониторинг». Без этого решения скилл угадывал бы намерения — это запрещено правилами агента.

Используй общий helper `_lib/find-config.sh` (единая точка изменения для всех
STRICT/OPTIONAL скиллов — алгоритм идентичен Cold Start Protocol персоны).
`$SYSADMIN_ROOT` запоминается на Шаге 1 Cold Start (ссылается на корень `sysadmin/` репо).

```bash
source "$SYSADMIN_ROOT/.claude/skills/_lib/find-config.sh"

# STRICT: exit 1 с понятным сообщением если конфига нет
find_sysadmin_config strict

# Подсистема должна быть включена
MON_ENABLED=$(get_config_field monitoring.enabled false)
if [ "$MON_ENABLED" != "true" ]; then
    cat <<'EOF' >&2
В infra-config.json указано monitoring.enabled=false — мониторинг не нужен.

Если хочешь включить — запусти /sysadmin-init --reconfigure
и переключи monitoring.enabled на true. После этого скилл заработает.
EOF
    exit 0
fi

# Чтение значений из конфига
COMPONENTS_FROM_CONFIG=$(jq -r '.monitoring.stack | join(",")' "$CONFIG")
DOMAIN_FROM_CONFIG=$(get_config_field monitoring.panel_domain)
[ -z "$DOMAIN_FROM_CONFIG" ] && DOMAIN_FROM_CONFIG=$(get_config_field 'servers[0].domain')

TG_ENABLED=$(get_config_field notifications.telegram.enabled false)
if [ "$TG_ENABLED" = "true" ]; then
    # Сам токен бота читается из менеджера паролей оператора по индексу
    # (поле secrets.manager в agent-config.json + конвенция "infra/<bot>/token").
    # Конфиг хранит ИНДЕКС, не значение секрета.
    COMPONENTS_FROM_CONFIG="${COMPONENTS_FROM_CONFIG},telegram"
fi

# CLI-override > конфиг (для отладочных прогонов)
COMPONENTS="${COMPONENTS:-$COMPONENTS_FROM_CONFIG}"
DOMAIN="${DOMAIN:-$DOMAIN_FROM_CONFIG}"
```

**Важно:** STOP-сообщение при `monitoring.enabled=false` дословно содержит `/sysadmin-init --reconfigure` — это единственный путь оператора к включению подсистемы. Без явного указания пути STOP превращается в тупик.

# Параметры

| Параметр | Default | Описание |
|----------|---------|----------|
| `COMPONENTS` | (из `infra-config.json`: `monitoring.stack`) | Комбинация компонентов через запятую |
| `DOMAIN` | (из `infra-config.json`: `monitoring.panel_domain`) | Базовый домен (для panel.$DOMAIN) |
| `TELEGRAM_BOT_TOKEN` | (если telegram; читается из менеджера паролей оператора по `secrets.manager` + конвенции) | Bot token из BotFather |
| `TELEGRAM_CHAT_ID` | (из `infra-config.json`: `notifications.telegram.*` + менеджер паролей) | Chat ID куда слать алерты |
| `BASIC_AUTH_USER` | (required) | Имя пользователя для panel-доступа |
| `BASIC_AUTH_PASS` | (required, из менеджера паролей) | Пароль для panel-доступа |
| `INSTALL_DIR` | `/opt/monitoring` | Куда разворачивать compose |
| `KUMA_USERNAME` | `admin` | Первичная учётка Kuma |
| `KUMA_PASSWORD` | (required, из менеджера паролей) | Первичный пароль Kuma |

# Процедура

## Шаг 1: Pre-check

Проверяем перед началом — что нет конфликтов и всё готово.

```bash
# Docker и compose установлены
docker --version && docker compose version

# nginx установлен (если будет reverse-proxy)
nginx -v

# Домен резолвится
dig +short panel.$DOMAIN
# должен вернуть IP сервера; если пусто — DNS не настроен, остановиться

# Порты свободны (binds на 127.0.0.1 — внешний доступ только через nginx)
for port in 3001 8090 8080 5001; do
  ss -tlnp | grep -q ":$port " && echo "ZANYAT $port — конфликт" || echo "OK $port"
done

# RAM-бюджет
free -h
```

**Verify:** все проверки PASS, иначе блокер.

## Шаг 2: Подготовка INSTALL_DIR и compose-файлов

```bash
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Копируем compose-файлы только тех компонентов, что в $COMPONENTS
for comp in $(echo "$COMPONENTS" | tr ',' ' '); do
  case "$comp" in
    kuma)    cp templates/uptime-kuma-compose.yml docker-compose.yml ;;
    beszel)  cp templates/beszel-compose.yml      beszel.yml ;;
    dozzle)  cp templates/dozzle-compose.yml      dozzle.yml ;;
    dockge)  cp templates/dockge-compose.yml      dockge.yml ;;
    diun)    cp templates/diun-compose.yml        diun.yml ;;
  esac
done
```

Все версии в шаблонах **запинены** (без `:latest`): Docker Compose пересоздаёт контейнер
на каждый `up -d` при `:latest`, даже если digest не менялся. Разбор — `references/pitfalls.md`.

## Шаг 3: nginx reverse-proxy

```bash
# Создаём htpasswd для Basic Auth
htpasswd -c -B /etc/nginx/htpasswd-monitoring "$BASIC_AUTH_USER"
# Вводим пароль интерактивно или через -ib (но тогда пароль попадёт в shell history!)

# Устанавливаем vhost
cp templates/nginx-monitoring-vhost.conf /etc/nginx/sites-available/panel.$DOMAIN.conf
sed -i "s|<DOMAIN>|panel.$DOMAIN|g" /etc/nginx/sites-available/panel.$DOMAIN.conf
sed -i "s|<HTPASSWD>|/etc/nginx/htpasswd-monitoring|g" /etc/nginx/sites-available/panel.$DOMAIN.conf

# Активируем
ln -s /etc/nginx/sites-available/panel.$DOMAIN.conf /etc/nginx/sites-enabled/
nginx -t && nginx -s reload
```

**Verify:** `curl -I http://panel.$DOMAIN/` отвечает 401 (Basic Auth требуется).

## Шаг 4: Let's Encrypt сертификат

```bash
# HTTP-01 challenge (требует публичный IP и DNS уже настроен)
acme.sh --issue -d panel.$DOMAIN -w /var/www/html

# Установить cert в nginx
acme.sh --install-cert -d panel.$DOMAIN \
  --key-file       /etc/nginx/ssl/panel.$DOMAIN.key \
  --fullchain-file /etc/nginx/ssl/panel.$DOMAIN.pem \
  --reloadcmd     "nginx -s reload"
```

Если на сервере нет публичного IP / есть CDN перед nginx — использовать DNS-01 challenge
через API провайдера (см. `references/component-tradeoffs.md`).

## Шаг 5: Поднятие стека

Запускаем компоненты последовательно (не параллельно — проще диагностировать падение):

```bash
cd "$INSTALL_DIR"

for f in docker-compose.yml beszel.yml dozzle.yml dockge.yml diun.yml; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  docker compose -f "$f" up -d
done

# Проверка health
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '(uptime-kuma|beszel|dozzle|dockge|diun)'
```

**Verify:** все контейнеры в статусе `Up`. Если какой-то в `Restarting` — смотри
`docker logs <container>`.

## Шаг 6: Конфигурация Uptime Kuma

Kuma 2.x использует **socket.io API**, а не REST. Старая Python-библиотека
`uptime-kuma-api` поддерживает только Kuma 1.x — для 2.x работает Node.js socket.io клиент
изнутри контейнера.

```bash
# Запустить скрипт конфигурации
KUMA_USERNAME=admin KUMA_PASSWORD="$KUMA_PASSWORD" \
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" \
bash scripts/configure-kuma-via-api.sh
```

Скрипт:
1. Создаёт первичную учётку через socket.io событие `setup`
2. Логинится тем же socket.io клиентом
3. Добавляет Telegram notification provider (token + chat_id)
4. (опционально) Создаёт первый «sentinel» monitor — пинг внешнего сайта раз в 5 минут

## Шаг 7: Конфигурация Beszel

Beszel Hub имеет интересную особенность — первичная учётка создаётся через UI, а не через
переменные окружения. Скрипт обходит это, вставляя bcrypt-хэш напрямую в SQLite.

```bash
BESZEL_USER_EMAIL="$BASIC_AUTH_USER@local" BESZEL_USER_PASS="$BASIC_AUTH_PASS" \
bash scripts/configure-beszel-pair.sh
```

Скрипт:
1. Останавливает hub, генерирует bcrypt-хэш пароля
2. UPDATE в `data.db` устанавливает первичного пользователя
3. Запускает hub обратно
4. Генерирует SSH-ключ для пары hub→agent
5. Регистрирует agent через API hub'а (или печатает инструкцию для UI, если API недоступен)

> **Важно:** Beszel hub работает в режиме `network_mode: host`, потому что в bridge-сети
> iptables блокирует порт agent'а (45876) — известная проблема. Изоляцию тогда даёт
> `ufw deny 8090/tcp`, а не сеть Docker. Разбор — `references/pitfalls.md`.

## Шаг 8: Telegram-интеграция (если COMPONENTS включает telegram)

- **Kuma:** notification provider добавлен скриптом из Шага 6.
- **Beszel:** apprise URL `tgram://${TELEGRAM_BOT_TOKEN}/${TELEGRAM_CHAT_ID}` через UI
  (Settings → Notifications) или прямой UPDATE в `user_settings.notificationURLs` в SQLite.
- **Diun:** настройка в `templates/diun-compose.yml` через переменные `DIUN_NOTIF_TELEGRAM_*`.

## Шаг 9: Smoke-test

Проверяем, что всё работает end-to-end:

```bash
# 1. Basic Auth работает
curl -I -u "$BASIC_AUTH_USER:$BASIC_AUTH_PASS" https://panel.$DOMAIN/
# Ожидаем 200 (или 301/302 если есть редирект)

# 2. Каждый поддомен / поддиректория откликается
for path in / /beszel /dozzle /dockge; do
  curl -s -o /dev/null -w "%{http_code} $path\n" -u "$BASIC_AUTH_USER:$BASIC_AUTH_PASS" \
    https://panel.$DOMAIN$path
done

# 3. Тестовый Telegram-алерт через Kuma
# (через UI: создать монитор HTTP, выключить — должен прийти алерт)
```

**Verify:** все коды 200, тестовый алерт доходит в Telegram-чат в течение 1 минуты.

## Шаг 10: Запись в inventory

В `inventory/services.md` добавляю по строке на каждый поднятый контейнер: имя, роль,
адрес и порт, путь в панели, образ **с фактической версией из своего compose-файла**.
Готовый образец таблицы — `references/pitfalls.md`, раздел «Что писать в inventory».

Версии не переписываю по памяти и не копирую из справки — беру из `templates/*.yml`,
которые реально применил (C.2).

# Bundled resources

| Файл | Что это и когда открывать |
|---|---|
| `references/component-tradeoffs.md` | **Что ставить**: RAM-бюджет по компонентам (фактические замеры), четыре готовые конфигурации от минимальной до полной, trade-off каждой. Открывать до Шага 1, когда решаешь состав `COMPONENTS` |
| `references/pitfalls.md` | **Когда шаг не сработал**: шесть граблей (Kuma 2.x и socket.io, Beszel в bridge, `:latest`, acme.sh без reloadcmd, htpasswd `-i`), случай приватной сети и образец записи в inventory |
| `templates/uptime-kuma-compose.yml` | Kuma + monitoring-default network |
| `templates/beszel-compose.yml` | Hub в host network mode |
| `templates/dozzle-compose.yml` | `DOZZLE_AUTH_PROVIDER=simple`, монтаж docker.sock |
| `templates/dockge-compose.yml` | монтаж `/opt/stacks` для compose-управления |
| `templates/diun-compose.yml` | file watch `/opt` + Telegram через apprise |
| `templates/nginx-monitoring-vhost.conf` | basic auth + TLS + reverse-proxy на все компоненты |
| `scripts/configure-kuma-via-api.sh` | Node.js socket.io клиент изнутри контейнера (Шаг 6) |
| `scripts/configure-beszel-pair.sh` | bcrypt + SQLite + сопряжение ключей (Шаг 7) |