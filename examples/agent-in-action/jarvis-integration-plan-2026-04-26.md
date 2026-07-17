# Хендофф: план интеграции внешнего сервиса в инвентарь инфры

**Дата разбора:** 2026-04-26
**Тип:** хендофф GSD → агент через реальную операционную задачу
**Сервис:** `<external-tunnel-service>` (FRP server, snowdreamtech/frps:0.66)
**Контейнер:** `<external-tunnel>-frps`
**Зона работы (этот разбор):** 🟢 Зелёная — read-only аудит и план
**Зона работы (само встраивание):** 🟡 Жёлтая — изменения compose, перенос TLS, добавление в backup-сценарий

> **Этот документ — публичный пример работы агента-сисадмина.** Все имена сервисов,
> доменов, IP-адресов и секретов обезличены и заменены на плейсхолдеры. Принципы
> операции (зоны доверия, 4-шаговая процедура, type-to-confirm, чек-лист аудита) —
> те же, что в реальной работе. Меняется только конкретика, не методология.

---

## Контекст хендоффа

К концу milestone v1 (этап 8 проекта `infra`) нужно было провести **формальный
переход** GSD-фреймворка в роль «архивный фоновый процесс», а агента `@sysadmin` —
в роль «повседневный оператор». Условие хендоффа: первая операционная задача проводится
агентом без GSD-фреймворка, через свою персону + скиллы + чек-листы.

Реальный сценарий, попавший под хендофф: на сервере оператора **появился новый
сервис**, созданный из другого проекта (не через скиллы агента). Сервис не отражён
в текущем `inventory/`, последний snapshot датирован 2026-04-17 (за 9 дней до разбора).
Внешние «глаза» инфры (мониторинг, dashboard) не «видят» новый сервис — он живёт сам по
себе.

Задача агента: **проинвентаризировать новый сервис, найти расхождения с конвенциями
инфры, написать план интеграции** (НЕ само встраивание — только план; реальная
интеграция — следующая задача после закрытия этапа 8 по правилу CLAUDE.md «никаких
прямых действий до завершения этапа 8»).

Это идеальный кейс для хендоффа: задача realistic, требует применения регламента
жизни (Cold Start → читать актуальный snapshot), скилла `cleanup-existing-server`
(чек-лист аудита), скилла `audit-security` (проверка безопасности), Trust Zone-логики
(аудит — Green; план встраивания — Yellow).

---

## Шаг 1: Что обнаружено

### Факт находки

В свежем snapshot сервера (`<server>:/snapshots/2026-04-26/containers.txt`) обнаружен
ранее не задокументированный контейнер:

```
NAMES               IMAGE                          STATUS
<external-tunnel>-frps    snowdreamtech/frps:0.66        Up 33 hours
```

Контейнер запущен **2026-04-24 17:36 UTC** — за ~33 часа до разбора. До этого момента
в `inventory/services.md` он не присутствовал.

### Что это за сервис

**FRP** (Fast Reverse Proxy) — open-source инструмент для туннелирования трафика с
машин за NAT через публичный сервер. Архитектура «клиент-сервер»:

- **frps** (server) — на публичном сервере с открытым портом 7000/tcp; принимает
  подключения от клиентов
- **frpc** (client) — на машине за NAT; устанавливает long-lived TCP-соединение с frps
  и регистрирует туннели

В нашем случае на сервере крутится только серверная часть (frps). Клиент (frpc) живёт
на машине оператора (не на сервере) — это видно из логов: входящие подключения с
удалённых hostname `pool-<masked>.bstnma.fios.verizon.net`.

### Технические факты из инспекции

| Параметр | Значение |
|----------|----------|
| Image | `snowdreamtech/frps:0.66` (pinned tag, не `latest`) ✓ |
| Container name | `<external-tunnel>-frps` (соответствует паттерну `<project>-<service>`) ✓ |
| Network mode | `host` (не Docker bridge) |
| User | `65534:65534` (nobody:nogroup, не root) ✓ |
| Read-only rootfs | Да ✓ |
| Capabilities | Drop ALL ✓ |
| `no-new-privileges` | Да ✓ |
| Restart policy | `unless-stopped` ✓ |
| Volumes | `/opt/<external-tunnel>/frps.toml:/etc/frp/frps.toml:ro` (только read-only) ✓ |
| Logging | json-file, max-size 10m, max-file 3 ✓ |
| Memory limit | НЕ установлен (`Memory: 0`) ⚠ |
| Compose project | `<external-tunnel>` (`/opt/<external-tunnel>/docker-compose.yml`) ✓ |
| Compose-managed | Да ✓ |

### Открытые порты

```
tcp   LISTEN  *:7000        (frps control plane — token-protected)
tcp   LISTEN  127.0.0.1:7080  (frps vhostHTTPPort — за nginx)
tcp   LISTEN  127.0.0.1:7500  (frps webServer admin — за SSH/local)
```

UFW содержит правило:

```
[16] 7000/tcp  ALLOW IN  Anywhere  # frp control plane (token-protected, host-network)
```

Порты 7080 и 7500 — только на `127.0.0.1`, наружу не торчат ✓.

### Конфиг (с маскировкой)

`/opt/<external-tunnel>/frps.toml`:

```toml
bindAddr = "0.0.0.0"
bindPort = 7000              # control plane (с UFW ALLOW)
proxyBindAddr = "127.0.0.1"
vhostHTTPPort = 7080         # 127.0.0.1 only (nginx -> здесь)

auth.method = "token"
auth.token = <REDACTED>      # mode 0640 root:nogroup ✓

webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "admin"
webServer.password = <REDACTED>

log.to = "console"           # Docker подхватывает через json-file driver
log.level = "info"

allowPorts = [
  { start = 7080, end = 7080 }
]

transport.maxPoolCount = 1
```

Конфиг **аккуратный**: явный allowPorts whitelist (один порт), token-auth, admin-веб
только на 127.0.0.1, лог в stdout (Docker управляет ротацией).

### Nginx-vhost

`/etc/nginx/sites-enabled/<external-tunnel>.<base-domain>.conf`:

- HTTP → HTTPS redirect ✓
- TLS termination, SSE/WebSocket поддержка (long timeouts 310s) ✓
- Strict-Transport-Security, X-Frame-Options, X-Content-Type-Options, Referrer-Policy ✓
- proxy_pass на `127.0.0.1:7080` (frps vhostHTTPPort) ✓

Конфиг **корректный** для FRP: проксирует HTTP с сохранением `Host` header (frp роутит
по Host).

### Данные мониторинга (из snapshot)

- Uptime ≈ 33 часа, RestartCount = 0 (стабилен)
- Memory usage: **6 МБ** (процесс крошечный)
- CPU usage: 0.00%
- Логи: регулярные client login/logout (~каждые 5-10 мин — клиент с iPhone/Mac)
- Никаких ERROR / WARNING в логах за последние 24 часа

---

## Шаг 2: Источник

**Известно:**

- Сервис создан **из другого проекта оператора** (информация от оператора устно;
  репозиторий-источник проекта, использующего frpc, не отражён в `inventory/`).
- Имя contained-проекта `<external-tunnel>` соответствует названию проекта-носителя.
- TLS-сертификат для `<external-tunnel>.<base-domain>` выпущен через `acme.sh`
  (директория `/root/.acme.sh/<external-tunnel>.<base-domain>_ecc/` существует),
  но **сертификат лежит в нестандартном месте** (см. Шаг 3, расхождение #1).

**Неизвестно (требует уточнения оператором):**

- В каком репозитории живёт frpc-клиент?
- Есть ли документация по сервису (README, runbook)?
- Кто зависит от этого сервиса (PWA + Brain — что это за приложения)?
- Планируется ли долгосрочное использование или это временный туннель для отладки?

> **Принцип агента:** «source неизвестен» — это валидный статус. Я не выдумываю
> историю, фиксирую факт и оставляю поле для уточнения. До получения ответа от
> оператора план интеграции опирается только на факты из snapshot и compose-файла.

---

## Шаг 3: Аудит против конвенций инфры (чек-лист `cleanup-existing-server`)

| Проверка | Результат | Комментарий |
|----------|-----------|-------------|
| Имя контейнера соответствует `<project>-<service>` | ✓ PASS | `<external-tunnel>-frps` корректно |
| Контейнер запущен через `docker compose up -d` | ✓ PASS | `com.docker.compose.project = <external-tunnel>` в labels |
| Compose-файл в стандартном пути `/opt/<service>/` | ✓ PASS | `/opt/<external-tunnel>/docker-compose.yml` |
| `.env` файл существует и mode 0600 | ⚠ N/A | `.env` отсутствует — секреты прямо в `frps.toml` (mode 0640 root:nogroup) |
| Образ pinned (не `latest`) | ✓ PASS | `snowdreamtech/frps:0.66` |
| Restart policy установлен | ✓ PASS | `unless-stopped` |
| Memory limit установлен | ❌ FAIL | `Memory: 0` (нет лимита) — **расхождение #2** |
| Логирование с ротацией | ✓ PASS | json-file, 10m × 3 |
| Healthcheck в compose | ⚠ WARN | Нет healthcheck — frps не предоставляет HTTP /health, можно добавить TCP-check на 7080 |
| Сеть — существующая или новая? | ⚠ WARN | `network_mode: host` — обоснованно для FRP (нужна привязка к 0.0.0.0:7000), но **не использует Docker network segmentation** (этап 6 ADR 0012) |
| Volumes — bind-mount или named | ✓ PASS | bind-mount только на конфиг (read-only) |
| Запущен под non-root user | ✓ PASS | `65534:65534` (nobody) |
| Read-only rootfs | ✓ PASS | Да |
| Capabilities drop ALL | ✓ PASS | Да |
| `no-new-privileges` | ✓ PASS | Да |
| Labels с владельцем/проектом | ❌ FAIL | Нет `com.infra.owner=<external-tunnel>` — **расхождение #3** (см. READ-10) |

### Расхождения с конвенциями (3 штуки)

#### Расхождение #1 (Yellow): TLS-сертификат в нестандартном пути

**Что найдено:**
- `nginx vhost` указывает на `/etc/ssl/<external-tunnel>.crt` и `/etc/ssl/<external-tunnel>.key`
- В то время как все остальные домены проекта используют `/etc/nginx/ssl/<domain>/` —
  паттерн установлен в этапе 5 при переходе на acme.sh per-domain reload (ADR 0008)
- При этом `acme.sh` **знает про домен** (директория `<external-tunnel>.<base-domain>_ecc/` есть)
- Это значит: при автообновлении сертификата `acme.sh` положит новый файл в свой
  стандартный путь, а nginx будет читать **старый** файл из `/etc/ssl/` — TLS перестанет
  обновляться, через ~80 дней домен умрёт по протуханию

**Почему это критично:**
- Это типичная мина: всё работает 80 дней, потом резко перестаёт. Без проактивной
  проверки (Kuma SSL-monitor) узнаем по жалобе пользователя.
- Kuma SSL-мониторинг настроен (MON-08), но не для нового домена
  `<external-tunnel>.<base-domain>` — мы про него ещё не знали.

**Зона:** Yellow — нужно перенести сертификат и переписать nginx vhost. Без потери
TLS-связности (atomic switch через symlink или `nginx -s reload`).

#### Расхождение #2 (Yellow): Memory limit не установлен

**Что найдено:** `docker inspect <external-tunnel>-frps` → `HostConfig.Memory = 0`

**Почему это критично:**
- Этап 5 проекта установил policy: каждый контейнер должен иметь лимит памяти,
  выставленный после замеров (READ-04 / READ-05 / ADR 0009).
- Сумма всех лимитов держится ниже 3.2 ГБ (запас 800 МБ хосту и всплескам).
- Без лимита FRP процесс может теоретически расти без ограничения. Хотя сейчас он
  ест 6 МБ — при атаке (массовое подключение клиентов) может вырасти до 100+ МБ.

**Что предлагается:** установить лимит `64m` (10× от текущего usage). FRP документация
не даёт точного числа, but 64 МБ запас для FRP server с парой клиентов — щедрый.

**Зона:** Yellow — правка `docker-compose.yml`, перезапуск контейнера.

#### Расхождение #3 (Green): Нет labels с owner

**Что найдено:** В `docker inspect` отсутствует label `com.infra.owner`.

**Почему это критично:** Конвенция этапа 5 (READ-10) — все контейнеры имеют label с
владельцем для группировки в дашбордах (custom dashboard этапа 7).

**Зона:** Green — правка только compose-файла, без перезапуска контейнера (label
применяется на следующем `docker compose up -d`).

---

## Шаг 4: Аудит безопасности (чек-лист `audit-security`)

| Категория | Проверка | Результат | Комментарий |
|-----------|----------|-----------|-------------|
| **Host firewall** | Открытый наружу порт в UFW есть | ✓ PASS | `7000/tcp ALLOW IN` с комментарием |
| **Host firewall** | UFW-правило задокументировано | ✓ PASS | Комментарий «frp control plane (token-protected, host-network)» |
| **Auth on exposed port** | Контроль доступа на 7000 есть | ✓ PASS | `auth.method = "token"`, токен длинный random |
| **Internal UI** | Admin-вебсервер 127.0.0.1 | ✓ PASS | `webServer.addr = "127.0.0.1"`, не наружу |
| **TLS** | Если есть домен — TLS настроен | ✓ PASS | nginx vhost с TLSv1.2/1.3, HSTS |
| **TLS** | Сертификат валиден и автообновляется | ❌ FAIL | См. расхождение #1 — сертификат не в acme.sh-управляемом пути |
| **Secrets in env-files** | Plain-text секретов нет | ⚠ WARN | Секреты прямо в `frps.toml` (не в `.env`). Файл mode 0640 root:nogroup — приемлемо, но отличается от паттерна `.env` 0600 root:root |
| **Container isolation** | Non-root, drop caps, read-only rootfs | ✓ PASS | Все три ✓ |
| **Image source** | Образ из доверенного источника | ⚠ WARN | `snowdreamtech/frps` — community-maintained, не official. Это норма для FRP (official нет), но стоит знать |
| **Image pinning** | Pinned tag, не `latest` | ✓ PASS | `:0.66` |
| **Diun monitoring** | Сервис в Diun watch-list | ⚠ N/A | Diun сейчас не следит за `<external-tunnel>-frps` — нужно добавить (см. план интеграции) |
| **Logs rotation** | Логи ротируются | ✓ PASS | json-file 10m × 3 |
| **Inventory/git** | Сервис в `inventory/services.md` | ❌ FAIL | Нет — это и есть основная задача интеграции |
| **Compose в git** | `docker-compose.yml` в репо | ❌ FAIL | Нет — `/opt/<external-tunnel>/docker-compose.yml` живёт только на сервере |

### Сводка безопасности

**Сильные стороны:**
- Hardening контейнера на хорошем уровне (non-root, read-only, drop caps,
  no-new-privileges) — лучше многих сервисов проекта
- Token-auth на единственный exposed порт
- Admin-интерфейс закрыт от внешнего мира

**Слабые места:**
- TLS-сертификат вне acme.sh-управления (мина на 80 дней)
- Нет Diun-наблюдения за обновлениями `:0.66`
- Compose не в git (drift с этапа 7 IaC-моделью)

---

## Шаг 5: Зависимости

### Что зависит от FRP

Из логов видно: один FRP-клиент с прокси-туннелем `<service-tunnel>` для приложений
`PWA + Brain` (хост `<masked-mac-hostname>`). То есть на удалённой машине оператора
живут два приложения, которые публикуются наружу через этот туннель.

Это **не критическое для проекта `infra` зависимое приложение** — если FRP упадёт,
ничего из 14 контейнеров проекта не сломается. Сломается только удалённый PWA-сервис
оператора.

### От чего зависит FRP

- **nginx** — TLS termination (если nginx упадёт, домен `<external-tunnel>.<base-domain>`
  станет недоступным; сам frps-контейнер выживет)
- **acme.sh** — продление TLS-сертификата (сейчас сломанная связь — см. расхождение #1)
- **Docker daemon** — стандартно
- **Хост-сеть (порт 7000)** — UFW

### Сети

`network_mode: host` — FRP не использует Docker network segmentation. Это **обосновано
архитектурно**: frps должен слушать `0.0.0.0:7000` для входящих TCP от удалённых
клиентов, и host-network — самый простой способ это обеспечить без NAT-прыжков.
Альтернатива (bridge + publish ports) работала бы тоже, но даёт лишний overhead.

---

## Шаг 6: Зона доверия для интеграции

### Этот разбор (документация)

**Зона: 🟢 Зелёная.** Только чтение snapshot, чтение compose-файла, чтение nginx-vhost,
запись публичного артефакта. Никаких изменений на сервере. Не нужно подтверждение
оператора.

### План встраивания (следующая задача)

**Зона: 🟡 Жёлтая.** Правки compose, переписывание nginx vhost, перенос TLS-сертификата,
коммит compose в `infra`-репо, запись в inventory, добавление в Diun, добавление в
backup-сценарий (если применимо), добавление в Kuma SSL-monitor.

**Брифинг 6 пунктов** (по протоколу Yellow Zone):

1. **Что я хочу сделать** — интегрировать `<external-tunnel>-frps` в инфра-репо как
   полноценный observable сервис (compose в git, inventory, monitoring, TLS под
   контролем acme.sh)
2. **Почему это безопасно** — все шаги не затрагивают running контейнер, кроме одной
   правки `docker-compose.yml` (memory limit + labels) → `docker compose up -d` пересоздаст
   контейнер с downtime ~3-5 сек
3. **Что станет доступно** — сервис в дашборде, мониторинг TLS, Diun-уведомления о
   новых версиях, backup-стратегия (если нужна)
4. **План отката на каждом шаге** — symlink на старый сертификат, держать backup
   nginx-vhost (`.bak.YYYYMMDD-HHMMSS`), git revert compose-коммита
5. **Ожидаемое время простоя** — ~5 секунд (один docker recreate); reload nginx без
   простоя
6. **Тишина = нет.** Если оператор не отвечает, не выполняем.

### Если бы понадобились stateful-данные

**Зона: 🔴 Красная** — но в случае FRP это не применимо. У сервиса нет state'а: токен
в конфиге, нет БД, нет volumes с данными. Поэтому встраивание не требует Red Zone
4-шаговой процедуры (ASSESS → PROPOSE → EXECUTE → VERIFY с type-to-confirm).

---

## Шаг 7: План интеграции (пошагово, с rollback)

> **Важно:** этот план — **рекомендация**. Реальное встраивание — отдельная задача
> после закрытия этапа 8 проекта `infra` (правило CLAUDE.md «никаких прямых действий
> до завершения этапа 8»). Сейчас агент **только пишет план**, не выполняет.

### Шаг 7.1: Перенести compose-файл в git (Green Zone)

```bash
# На маке оператора
mkdir -p <INFRA_DIR>/services/<external-tunnel>
scp <server>:/opt/<external-tunnel>/docker-compose.yml \
    <INFRA_DIR>/services/<external-tunnel>/docker-compose.yml
```

В compose внести 2 правки **до коммита**:
- Добавить `mem_limit: 64m` (или эквивалент через `deploy.resources.limits.memory: 64M`)
- Добавить `labels: { com.infra.owner: "<external-tunnel>" }`

Создать `services/<external-tunnel>/.env.example`:

```env
# FRP server config secrets
# Реальные значения — в Keychain (или другом менеджере паролей оператора)
# Имена записей: <external-tunnel>-frps-token, <external-tunnel>-frps-admin-password
```

Закоммитить:

```bash
git add services/<external-tunnel>/
git commit -m "feat(<external-tunnel>): добавлен compose в инфра-репо (расхождение #3 закрыто)"
```

**Rollback:** `git revert HEAD`. Файлы на сервере не тронуты — продолжают жить
независимо.

### Шаг 7.2: Перенести TLS-сертификат под acme.sh-управление (Yellow Zone)

**Вариант А (рекомендую):** Symlink-подход. Создать симлинки в стандартном пути,
указывающие на acme.sh-файлы:

```bash
# Брифинг + согласие оператора
ssh <server> 'sudo mkdir -p /etc/nginx/ssl/<external-tunnel>.<base-domain>'
ssh <server> 'sudo /root/.acme.sh/acme.sh --install-cert -d <external-tunnel>.<base-domain> \
  --ecc \
  --key-file       /etc/nginx/ssl/<external-tunnel>.<base-domain>/key.pem \
  --fullchain-file /etc/nginx/ssl/<external-tunnel>.<base-domain>/fullchain.pem \
  --reloadcmd      "/opt/scripts/cert-reload-smart.sh <external-tunnel>.<base-domain>"'
```

Это переинициализирует acme.sh deploy для домена — теперь при автопродлении файлы
обновятся в правильном пути.

Затем переписать nginx vhost:

```bash
# Backup vhost
ssh <server> 'cp /etc/nginx/sites-enabled/<external-tunnel>.<base-domain>.conf \
  /etc/nginx/sites-available/<external-tunnel>.<base-domain>.conf.bak.$(date +%Y%m%d-%H%M%S)'

# Замена путей
ssh <server> 'sed -i \
  "s|/etc/ssl/<external-tunnel>.crt|/etc/nginx/ssl/<external-tunnel>.<base-domain>/fullchain.pem|; \
   s|/etc/ssl/<external-tunnel>.key|/etc/nginx/ssl/<external-tunnel>.<base-domain>/key.pem|" \
  /etc/nginx/sites-available/<external-tunnel>.<base-domain>.conf'

# Test + reload
ssh <server> 'nginx -t && nginx -s reload'

# Удалить старые файлы (после проверки работоспособности)
# (НЕ сразу — оставить на 1-2 дня в /etc/ssl/<external-tunnel>.{crt,key} для отката)
```

**Verify:**
```bash
curl -vI https://<external-tunnel>.<base-domain>/ 2>&1 | grep -E "subject:|expire date|HTTP/"
```

Должен вернуть HTTP/2 200 (или то, что отдаёт PWA), даты валидности сертификата
актуальные.

**Rollback (если nginx test fails):**
```bash
ssh <server> 'mv /etc/nginx/sites-available/<external-tunnel>.<base-domain>.conf.bak.<TIMESTAMP> \
  /etc/nginx/sites-enabled/<external-tunnel>.<base-domain>.conf'
ssh <server> 'nginx -s reload'
```

**Rollback (если acme.sh-конфиг сломал автообновление):**
- Старые файлы `/etc/ssl/<external-tunnel>.{crt,key}` ещё на месте
- В nginx переключить пути обратно через тот же sed
- `acme.sh --remove -d <external-tunnel>.<base-domain> --ecc` (отменить новый deploy)

### Шаг 7.3: Применить лимит памяти и labels (Yellow Zone)

После Шага 7.1 compose уже в git с правками. На сервере:

```bash
# Деплой через стандартный pipeline (если используется push-to-pull, ADR 0015)
./scripts/deploy/deploy-remote.sh

# ИЛИ вручную (если pipeline ещё не настроен для нового сервиса):
ssh <server> 'cd /opt/infra/services/<external-tunnel> && docker compose up -d'
```

**Ожидаемый downtime:** 3-5 секунд (recreate контейнера).

**Verify:**
```bash
ssh <server> 'docker inspect <external-tunnel>-frps --format "Memory: {{.HostConfig.Memory}}"'
# Ожидаем: 67108864 (= 64 МБ)

ssh <server> 'docker inspect <external-tunnel>-frps --format "{{.Config.Labels}}"'
# Ожидаем: содержит com.infra.owner:<external-tunnel>
```

**Rollback:** `git revert` коммита из Шага 7.1 + повторный `up -d`.

### Шаг 7.4: Записать в inventory (Green Zone)

Добавить запись в `inventory/services.md`:

```markdown
### <external-tunnel>-frps

- **Назначение:** FRP server — туннелирование PWA-приложений с удалённой машины оператора
- **Контейнер:** `<external-tunnel>-frps`
- **Образ:** `snowdreamtech/frps:0.66` (pinned)
- **Compose:** `services/<external-tunnel>/docker-compose.yml` (в git с 2026-04-XX)
- **Сеть:** host-network (обоснованно для FRP — нужен 0.0.0.0:7000)
- **Открытые порты:**
  - `7000/tcp` (наружу, UFW ALLOW, token-auth)
  - `127.0.0.1:7080` (vhostHTTPPort, за nginx)
  - `127.0.0.1:7500` (admin webServer)
- **Домен:** `<external-tunnel>.<base-domain>` (TLS via acme.sh, HSTS)
- **Зависит от:** nginx, acme.sh
- **От чего зависят:** удалённый PWA-сервис оператора (не критичный для проекта)
- **Memory limit:** 64m
- **Last verified:** 2026-04-XX
```

Также добавить в `inventory/networks.md`:

```markdown
> **Примечание:** `<external-tunnel>-frps` использует `network_mode: host` —
> единственный сервис проекта, не подключённый к сегментированным сетям этапа 6.
> Обоснование: FRP server должен слушать на 0.0.0.0:7000 для входящих TCP от удалённых
> клиентов; host-network — самый простой способ.
```

И в `inventory/domains.md`:

```markdown
| <external-tunnel>.<base-domain> | A → <server-ip> | TLS acme.sh | новый, 2026-04-24 |
```

**Rollback:** `git revert` коммита.

### Шаг 7.5: Подключить к мониторингу (Green Zone)

#### Kuma — uptime + TLS

Добавить два монитора:

1. **HTTP monitor:** `https://<external-tunnel>.<base-domain>/` (если PWA отдаёт что-то
   на корне — настроить под реальный health endpoint)
2. **TLS monitor:** SSL certificate expiry для того же домена (Kuma встроенная
   функциональность; алерт за 14 дней до истечения, как для остальных доменов)

Через UI Kuma или через API (если настроено).

#### Diun — обновления образа

Добавить контейнер в Diun watch-list. Если Diun сейчас watch'ит только Docker daemon
labels — это произойдёт автоматически при добавлении label:

```yaml
labels:
  diun.enable: "true"
  diun.watch_repo: "true"  # следить за всем репозиторием snowdreamtech/frps
```

Эти labels уже добавятся в compose в Шаге 7.1.

**Verify:** Перезапустить Diun (`docker restart diun`), проверить логи
`docker logs diun --tail 50` — должен появиться `<external-tunnel>-frps` в watched-list.

**Rollback:** убрать labels из compose, перезапустить Diun.

### Шаг 7.6: Бэкап (если применимо)

FRP не имеет state'а — нет БД, нет user uploads. Бэкапить нужно только:

- `/opt/<external-tunnel>/frps.toml` (один файл с токеном) — versioned in `git` если оператор
  захочет (но тогда нужно хранить через SOPS/age, секреты в открытом виде в git нельзя)
- nginx-vhost (`/etc/nginx/sites-available/<external-tunnel>.<base-domain>.conf`) — после
  Шага 7.1 будет в git как часть `services/<external-tunnel>/`

**Рекомендация:** держать `frps.toml` **только на сервере**, mode 0640. В Keychain
оператора — отдельная запись с токеном (`<external-tunnel>-frps-token`) для DR-сценария.

В DR-runbook (`runbooks/disaster-recovery.md`) добавить шаг:
> «При восстановлении FRP server — взять токен из Keychain (запись
> `<external-tunnel>-frps-token`), создать `/opt/<external-tunnel>/frps.toml` по шаблону из
> `services/<external-tunnel>/frps.toml.example`».

Создать `services/<external-tunnel>/frps.toml.example` (без секретов, с плейсхолдерами).

### Шаг 7.7: Финальная верификация (Green Zone)

```bash
# Все проверки за один проход
ssh <server> '
docker ps --filter "name=<external-tunnel>" --format "{{.Names}}: {{.Status}}";
docker inspect <external-tunnel>-frps --format "Memory: {{.HostConfig.Memory}} | Labels: {{.Config.Labels}}";
ls -la /etc/nginx/ssl/<external-tunnel>.<base-domain>/;
nginx -t;
curl -sI https://<external-tunnel>.<base-domain>/ | head -3;
ufw status numbered | grep 7000
'
```

Ожидаемые результаты — все ✓.

Потом проверить:
- В Kuma — оба монитора зелёные (uptime + TLS)
- В Diun — следующее уведомление при выходе snowdreamtech/frps:0.67 придёт в Telegram
- В дашборде — `<external-tunnel>-frps` появился в списке сервисов с владельцем
  `<external-tunnel>`

---

## Сводка плана

| Шаг | Зона | Время | Downtime | Rollback |
|-----|------|-------|----------|----------|
| 7.1 Compose в git + правки | 🟢 | 5 мин | нет | git revert |
| 7.2 TLS под acme.sh | 🟡 | 10 мин | нет | symlink/sed back |
| 7.3 Memory limit + labels | 🟡 | 2 мин | ~5 сек | git revert + up -d |
| 7.4 Inventory | 🟢 | 5 мин | нет | git revert |
| 7.5 Kuma + Diun | 🟢 | 10 мин | нет | удалить мониторы |
| 7.6 Backup-стратегия | 🟢 | 5 мин | нет | git revert |
| 7.7 Финальная верификация | 🟢 | 5 мин | нет | — |

**Итого:** ~45 мин человеко-времени, ~5 сек простоя сервиса.

---

## Что НЕ делается этим разбором

- Реальные правки на сервере (план только) — будет следующая задача после закрытия
  этапа 8 проекта `infra`
- Аудит самого FRP-протокола (security analysis) — оператор отвечает за выбор FRP как
  инструмента; агент только проверяет, что implementation на сервере правильная
- Решение «нужен ли вообще этот сервис» — это product decision оператора

## Подтверждение оператора (для следующего шага — встраивания)

⬜ Принимаю план интеграции, готов запланировать Yellow Zone задачу после закрытия
этапа 8

⬜ Уточняю источник сервиса (репо frpc, документация, владелец)

⬜ Хочу другой подход — обсудим альтернативы

---

**Артефакт записан:** `examples/agent-in-action/jarvis-integration-plan-2026-04-26.md`
**Связанные документы:**
- `inventory/hosts/prod-<server>/snapshots/2026-04-26/` — snapshot на момент разбора
- `.claude/skills/cleanup-existing-server/` — чек-лист аудита, использован в Шаге 3
- `.claude/skills/audit-security/` — чек-лист безопасности, использован в Шаге 4
- `.claude/skills/inventory-scan/` — скрипт `dump-snapshot.sh`, использован для свежего
  снимка
- `decisions/0008-acme-per-domain-reload.md` — паттерн TLS-управления
- `decisions/0011-two-stage-container-rename.md` — паттерн безопасного rename (применимо
  при будущих изменениях)
- `decisions/0015-iac-deploy-model.md` — push-to-pull pipeline для деплоя

**Last verified:** не применимо до выполнения плана. После выполнения добавить дату.

---

> **О хендоффе:** этот разбор — первая операционная задача агента-сисадмина `@sysadmin`
> в проекте `<infra-project>`, проведённая БЕЗ GSD-фреймворка. Она использует:
>
> - Регламент жизни (Cold Start → читать актуальный snapshot)
> - Скиллы (`inventory-scan`, `cleanup-existing-server`, `audit-security`)
> - Trust Zone-логику (Green для аудита, Yellow для встраивания)
> - Принцип «не делать, а планировать» при недостатке полномочий (CLAUDE.md
>   ограничение)
> - Honest unknown (источник сервиса — uncertain, фиксируем без выдумывания)
>
> Если этот разбор — то, что ученик ожидает от агента, хендофф состоялся: дальше
> повседневная работа идёт через `@sysadmin`, не через GSD. GSD остаётся для крупных
> структурных изменений (новые этапы milestone v1.x+).
