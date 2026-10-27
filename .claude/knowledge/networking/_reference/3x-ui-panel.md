---
knowledge_domain: vpn
layer: reference
last_researched: 2026-10-27
ttl_days: 60
sources_checked:
  - https://github.com/MHSanaei/3x-ui
  - https://github.com/MHSanaei/3x-ui/releases
  - https://github.com/MHSanaei/3x-ui/issues
  - https://github.com/MHSanaei/3x-ui/wiki/Installation
  - https://github.com/MHSanaei/3x-ui/wiki/Configuration
  - https://github.com/MHSanaei/3x-ui/wiki/Common-questions-and-problems
  - https://github.com/MHSanaei/3x-ui/wiki/Advanced
  - https://deepwiki.com/MHSanaei/3x-ui/2.3-ssl-certificate-management
  - https://deepwiki.com/MHSanaei/3x-ui/5.2-telegram-bot-integration
  - https://xtls.github.io/en/config/routing.html
  - https://xtls.github.io/en/config/inbounds/socks.html
  - https://xtls.github.io/en/config/observatory.html
  - https://github.com/XTLS/Xray-core/blob/main/infra/conf/observatory.go
  - https://github.com/MHSanaei/3x-ui/releases/tag/v3.11.0
  - https://github.com/MHSanaei/3x-ui/releases/tag/v3.10.0
  - https://github.com/MHSanaei/3x-ui/releases/tag/v3.9.0
  - https://github.com/MHSanaei/3x-ui/releases/tag/v3.8.0
  - https://github.com/MHSanaei/3x-ui/releases/tag/v3.7.0
  - https://github.com/MHSanaei/3x-ui/releases/tag/v3.5.0
  - https://github.com/MHSanaei/3x-ui/releases/tag/v3.3.1
  - https://github.com/MHSanaei/3x-ui/blob/main/docs/public/openapi.json
  - https://github.com/MHSanaei/3x-ui/blob/main/docs/content/docs/en/guide/installation.mdx
  - https://github.com/MHSanaei/3x-ui/blob/main/docs/content/docs/en/guide/first-login.mdx
  - https://github.com/MHSanaei/3x-ui/blob/main/docs/content/docs/en/reference/env-vars.mdx
  - https://github.com/MHSanaei/3x-ui/blob/main/docs/content/docs/en/reference/database.mdx
  - https://github.com/MHSanaei/3x-ui/blob/main/x-ui.sh
  - https://github.com/MHSanaei/3x-ui/blob/main/frontend/src/schemas/observatory.ts
  - https://github.com/MHSanaei/3x-ui/blob/main/frontend/src/pages/xray/balancers/BalancerFormModal.tsx
  - https://github.com/MHSanaei/3x-ui/tree/v2.8.11
  - https://github.com/MHSanaei/3x-ui/tree/v2.9.4
  - https://github.com/MHSanaei/3x-ui/issues/4390
  - https://github.com/MHSanaei/3x-ui/issues/4406
  - https://github.com/MHSanaei/3x-ui/issues/4409
---

# 3X-UI: архитектура панели и операционные грабли

Этот документ — справочник по эталонной реализации 3X-UI (`MHSanaei/3x-ui`).
Покрывает архитектуру, файловую раскладку, CLI, TLS-выпуск, Telegram-бот,
известные подводные камни. Описание REST API — отдельно в `3x-ui-api.md`.

Читают: персона при ответах на вопросы про панель; скиллы `/setup-vpn-panel`,
`/configure-vpn-routing`, `/setup-server-proxy`, `/generate-client-config` при
любых операциях с панелью.

---

## 1. Архитектура: четыре сущности

### 1.1 Логическая модель

3X-UI — это веб-панель + REST API + Telegram-бот над ядром Xray-core. Сама
панель — Go-приложение, хранит конфигурацию в SQLite, перезаписывает конфиг
Xray и перезапускает процесс xray-ядра при изменениях.

Модель данных панели — четыре сущности:

| Сущность | Назначение | Аналогия |
|---|---|---|
| **Inbound** | Точка приёма трафика от клиентов | Входная дверь дома |
| **Outbound** | Точка отправки трафика наружу | Выходная дверь дома |
| **Routing rule** | Правило, какой inbound через какой outbound | Охранник, направляющий потоки |
| **Client** | Пользователь, имеющий доступ к inbound | Ключ от входной двери |

```mermaid
flowchart LR
    C1[Клиент 1<br/>iPhone] -->|VLESS UUID-1| IN1
    C2[Клиент 2<br/>Laptop] -->|VLESS UUID-2| IN1
    PROG[Программы<br/>на сервере] -->|SOCKS5 без auth| IN2

    subgraph Panel[3X-UI на VPS оператора]
      IN1[Inbound: vless-tcp<br/>:443, UUID-список]
      IN2[Inbound: mixed<br/>127.0.0.1:1080]
      ROUTING[Routing rules<br/>geosite:ru → direct<br/>остальное → upstream]
      OUT_D[Outbound: direct]
      OUT_U[Outbound: vless-upstream<br/>через провайдера / свой загр.VPS]
    end

    IN1 --> ROUTING
    IN2 --> ROUTING
    ROUTING -->|РФ-трафик| OUT_D
    ROUTING -->|зарубежный| OUT_U

    OUT_D --> INET_RU[Российский интернет]
    OUT_U --> INET_FOREIGN[Свободный интернет]
```

### 1.2 Несколько inbound и несколько outbound на одной панели

3X-UI поддерживает множество inbound и множество outbound одновременно.
Типовая боевая конфигурация:

- **Inbound 1** — VLESS-TCP на 443, для клиентов-устройств (Hiddify/Karing
  на iPhone, Hiddify/NekoBox на Android, sing-box/Hiddify на desktop).
  Множество clients (UUID на устройство-человека-роль).
- **Inbound 2** — mixed на 127.0.0.1:1080, для программ на этом же сервере.
- **Outbound 1** — direct (для РФ-трафика).
- **Outbound 2..N** — VLESS upstream (либо подписка провайдера, либо свой
  загр.VPS).
- **Balancer 1** — собирает Outbound 2..N через стратегию `leastPing`.

### 1.3 Балансировщики

Если outbound-ов несколько (несколько серверов в подписке провайдера,
несколько своих загр.VPS), они собираются в `balancer`:

```json
{
  "tag": "upstream-balancer",
  "selector": ["upstream"],
  "strategy": { "type": "leastPing" },
  "fallbackTag": "direct"
}
```

- `selector: ["upstream"]` — выбирает все outbound с tag, начинающимся на
  `upstream` (так удобно: `upstream-de`, `upstream-nl`).
- `strategy.type` — `random`, `roundRobin`, `leastPing`, `leastLoad`.
  `leastPing` и `leastLoad` требуют включённого `observatory` (модуль
  мониторинга outbound health).
- `fallbackTag` — куда уходит трафик, если все upstream-ы недоступны.
- С v3.5.0 `fallbackTag` может указывать на другой балансир.
- С v3.3.1 есть `POST /panel/api/xray/balancerOverride` (`tag`, `target`): действует сразу
  без рестарта, сбрасывается при рестарте Xray или удалении целевого outbound; с v3.10.0
  переживает перезагрузку маршрутизации.

> ⚠️ **Форма балансировщика в 3X-UI — только 4 поля** (подтверждено из исходника
> `frontend/src/pages/xray/balancers/BalancerFormModal.tsx`, перепроверено 2026-10-27; полей
> по-прежнему четыре):
> `tag`, `strategy`, `selector`, `fallbackTag`. **Настройки sticky-гистерезиса
> («держись за сервер, пока его пинг не станет хуже быстрейшего на N мс») в панели
> НЕТ** — ни в форме, ни в Observatory-редакторе. Такой порог-в-миллисекундах
> существует только на КЛИЕНТЕ (sing-box `urltest.tolerance`, дефолт 50ms), не на
> сервере. Не путать: «Latency»-порог в клиентских приложениях ≠ серверный балансир.
> `tolerance` у `leastLoad` означает допустимую долю отказов, а не порог в миллисекундах.
>
> **Как добиться предсказуемого (стабильного) выходного IP на сервере** — без
> несуществующего sticky-порога:
> 1. **selector из серверов ОДНОЙ страны** — тогда даже при failover страна не
>    меняется, и платформы не банят аккаунт за «прыжки по странам» (актуальная
>    угроза РФ-2026, см. `_live/frontline-ru.md`).
> 2. **`probeInterval: "5m"` вместо дефолтного `1m`/`30s`** — реже переоценка,
>    клиент дольше держится за один сервер, меньше «скачков» IP.
> 3. Для **абсолютно** неизменного IP — один outbound в selector (или вообще без
>    балансира). Минус: failover при падении только вручную.
>
> При этом `leastPing` на сервере = механизм **failover** (observatory исключает
> мёртвый сервер), а не «выбор быстрейшего на каждом соединении».
> `random`/`roundRobin` для предсказуемого IP не использовать — они специально
> размазывают трафик по серверам.

Маршрутизация ссылается на балансировщик через поле `balancerTag` (а не
`outboundTag`):

```json
{
  "type": "field",
  "balancerTag": "upstream-balancer",
  "inboundTag": ["vless-in", "mixed-in"]
}
```

### 1.4 Observatory (мониторинг outbound)

`observatory` — фоновой модуль Xray, который раз в N секунд пингует endpoint
от каждого outbound и помечает unhealthy. Конфиг:

```json
{
  "observatory": {
    "subjectSelector": ["upstream"],
    "probeUrl": "http://www.google.com/gen_204",
    "probeInterval": "5m"
  }
}
```

`leastPing` / `leastLoad` балансировщики используют его данные. Без
`observatory` не работают: по документации XTLS `leastPing` и `leastLoad` обязаны работать
в паре с observatory или burstObservatory. Если все outbound недоступны и `fallbackTag` не задан,
выбирается outbound по умолчанию.

> 💡 **`probeInterval`: 5m, не 30s/1m.** 3X-UI по умолчанию ставит `1m`. Чем
> чаще переоценка — тем чаще балансир может переключить клиента между близкими
> по пингу серверами («скачущий IP»). `5m` = клиент дольше держится за один
> сервер. Это главный серверный рычаг стабильности IP (вместе с «одна страна
> в selector»). Скилл `/configure-vpn-routing` ставит `5m` по умолчанию
> (`PROBE_INTERVAL`). Для `leastLoad`/burstObservatory есть ещё `sampling`
> (усреднение замеров; скилл поднимает с 2 до 4 — сглаживает всплески пинга).

> ⚠️ `pingConfig` не устаревшее имя, а подобъект `burstObservatory` (поля `destination`,
> `connectivity`, `interval`, `sampling`, `timeout`, `httpMethod`). У `observatory` поля
> `subjectSelector`, `probeURL`, `probeInterval`, `enableConcurrency`. В исходнике Xray имя
> `probeURL`, в документации `probeUrl`, панель пишет `probeURL`. Блоки не смешивать:
> `pingConfig` внутри `observatory` Xray молча пропустит (загрузчик не отвергает неизвестные
> поля), а `burstObservatory` без `pingConfig` не соберётся: ошибка "BurstObservatory requires
> a valid pingConfig".

---

## 2. Установка

### 2.1 Официальный установщик

Эталонный путь — однострочный скрипт от MHSanaei:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```

С фиксацией версии (рекомендуется в продакшне — против неожиданных
breaking changes):

```bash
VERSION=v3.11.0 && bash <(curl -Ls "https://raw.githubusercontent.com/mhsanaei/3x-ui/$VERSION/install.sh") $VERSION
```

Теги v3.0.0, v3.0.1 и v3.0.2 помечены на GitHub как pre-release. На 27.10.2026 стабильная
v3.11.0, шаг назад v3.10.2 (14.10). С v3.8.0 установщик сверяет архив с `<asset>.sha256` и берёт
`x-ui.sh` и юниты из того же тега.

### 2.2 Поддерживаемые ОС

Из `install.sh`:

- Ubuntu, Debian, Armbian
- CentOS 7+ (yum для 7, dnf для 8+)
- Fedora, RHEL, AlmaLinux, Rocky Linux, Oracle Linux
- Arch, Manjaro, Parch
- openSUSE Tumbleweed/Leap
- Alpine Linux (OpenRC вместо systemd)

**Архитектуры:** amd64, 386, arm64, armv7, armv6, armv5, s390x.

**Требование:** root (`[[ $EUID -ne 0 ]] && exit 1`).

### 2.3 Поведение установщика при первой установке

- Генерирует случайные креды:
  ```
  config_username=$(gen_random_string 10)
  config_password=$(gen_random_string 10)
  config_port=$(shuf -i 1024-62000 -n 1)
  ```
- **Интерактивный вопрос:** «Would you like to customize the Panel Port
  settings?».
- Неинтерактивный режим есть: `XUI_NONINTERACTIVE=1` или запуск без TTY. Установщик сам
  генерирует логин, пароль, порт, путь и API-токен и пишет их в `/etc/x-ui/install-result.env`
  (режим 600; ключи `XUI_USERNAME`, `XUI_PASSWORD`, `XUI_PANEL_PORT`, `XUI_WEB_BASE_PATH`,
  `XUI_ACCESS_URL`, `XUI_API_TOKEN`, `XUI_DB_TYPE`). В файле секреты, их нужно перенести в
  менеджер паролей.
- ENV vars, влияющие на установку:
  - `XUI_MAIN_FOLDER` — директория установки (default: `/usr/local/x-ui`).
  - `XUI_SERVICE` — путь для systemd (default: `/etc/systemd/system`).
- Установщик принимает **аргумент с версией**: `bash install.sh v3.0.2`.

### 2.4 Docker-образ

Дефолт панели: порт `2053`, путь `/`. Первый пользователь получает случайные креды; в Docker их
брать из логов контейнера или командой `docker exec -it <container> /app/x-ui setting -show true`
(документация пишет `x-ui setting -show`, но в образе `x-ui` это скрипт без ветки `setting`). Если
там `admin/admin`, сменить до создания inbound. Если ставится
Docker-вариант — **первая операция после установки** = смена логина и пароля
через CLI или API.

### 2.5 Что делает скилл сисадмина при установке

`/setup-vpn-panel` поверх официального установщика:
1. Запускает установщик с фиксацией версии.
2. **Сразу после первого запуска** через бинарник `/usr/local/x-ui/x-ui setting` (в скрипте
   `x-ui` ветки `setting` нет, §4.1) меняет:
   - `-username` на сгенерированный 8-символьный (не `admin`).
   - `-password` на сгенерированный 32-символьный.
   - `-port` на нестандартный из переданного параметра.
   - `-webBasePath` на случайный 10-символьный (например, `/abc123xyz0/`)
     для защиты от сканеров.
3. Записывает все четыре значения в менеджер паролей оператора.
4. Настраивает TLS (см. §4).

---

## 3. Файловая раскладка

Из `config/config.go`:

| Путь | Назначение | Переменная для override |
|---|---|---|
| `/etc/x-ui/x-ui.db` | SQLite база панели (inbounds, outbounds, clients, settings) | `XUI_DB_FOLDER` |
| `/var/log/x-ui/` | Логи панели | `XUI_LOG_FOLDER` |
| `/usr/local/x-ui/` | Бинарник + скрипты | `XUI_MAIN_FOLDER` |
| `/usr/local/x-ui/x-ui` | Основной бинарник (Go) | — |
| `/usr/local/x-ui/x-ui.sh` | Bash-обёртка с CLI-командами | — |
| `/usr/local/x-ui/bin/xray-linux-amd64` | Ядро Xray (запускается панелью) | `XUI_BIN_FOLDER` |
| `/etc/systemd/system/x-ui.service` | systemd unit | — |
| `/root/cert/{domain}/` | Сертификаты Let's Encrypt по умолчанию | — |

Изменения раскладки в свежих версиях (сверено 2026-10-27):
- с v3.8.0 права на базу: каталог 0700, файлы базы и `-wal`/`-shm` 0600;
- есть PostgreSQL: `XUI_DB_TYPE=postgres` и `XUI_DB_DSN` в `/etc/default/x-ui`;
- с v3.10.0 служба запускается в песочнице systemd: `/usr`, `/boot`, `/etc`, `/home`, `/root`
  доступны ей только на чтение, кроме собственных каталогов; дополнительные пути добавлять через
  `ReadWritePaths=` в `x-ui.service.d/20-local.conf`, а `10-xui-sandbox.conf` перегенерируется при
  каждом install и update;
- Xray 26.10.x проверяет TLS outbound по встроенным корням Mozilla, для частного центра
  сертификации нужна опция «Use system CA»;
- исходники Go переехали в `internal/`.

> **🔴 Живой лог Xray определяй по fd процесса, НЕ по пути в конфиге и НЕ по наличию файла.**
> Ядро Xray пишет `access.log`/`error.log` в **`/var/log/x-ui/`** (не `/var/log/xray/`). После
> обновления/рестарта/смены `log.access` в конфиге старый каталог логов (`/var/log/xray/`) может
> остаться **мёртвым реликтом**: файл существует, но mtime заморожен на момент прошлого рестарта,
> живой процесс в него НЕ пишет. Диагностика по такому реликту даёт **ложные выводы** (реальный
> инцидент 2026-07-02: read-only агент прочитал реликт `/var/log/xray/access.log` и заявил, что
> дефект маршрутизации «не воспроизводится», хотя живой лог показывал обратное).
>
> **Как найти ЖИВОЙ лог гарантированно** — по файловым дескрипторам работающего процесса:
> ```bash
> ls -l /proc/$(pgrep -f 'xray-linux-amd64 -c')/fd | grep -i log
> # покажет реальные пути, в которые xray пишет ПРЯМО СЕЙЧАС (fd → /var/log/x-ui/*.log)
> ```
> Правило: для диагностики маршрутизации/трафика читай лог, подтверждённый через fd, а не первый
> подходящий по имени. Реликт-каталог с замороженным mtime — кандидат на снос (после `lsof +D`).

### 3.1 SQLite база

`/etc/x-ui/x-ui.db` — единственный персистентный артефакт. Структура (по
исходникам `database/model/model.go`):

- **`inbounds`** — все inbound с параметрами (включая stream settings,
  reality settings, sniffing).
- **`outbound_traffics`** — статистика трафика по outbound.
- **`client_traffics`** — статистика по клиентам.
- **`users`** — admin-пользователи панели (логин/хеш пароля).
- **`settings`** — глобальные настройки (порт, webBasePath, webDomain,
  TLS-пути и т.д.).
- **`xray.json` (виртуально)** — итоговый конфиг Xray, генерируется на лету
  из inbounds + outbounds + routing rules + balancers и записывается
  в `bin/config.json` Xray.

### 3.2 Бэкап SQLite перед правкой

При любой fallback-операции через прямую правку SQLite — **сначала**:

```bash
cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.backup.$(date +%Y%m%d-%H%M%S)
```

Если что-то сломалось — откат:

```bash
systemctl stop x-ui
cp /etc/x-ui/x-ui.db.backup.<timestamp> /etc/x-ui/x-ui.db
systemctl start x-ui
```

---

## 4. CLI команды

Из `x-ui.sh`:

| Команда | Назначение |
|---|---|
| `x-ui start` | Запустить панель |
| `x-ui stop` | Остановить |
| `x-ui restart` | Перезапустить панель + ядро (жёстко, рвёт веб-панель и sub-порты) |
| `x-ui restart-xray` | **Мягкий рестарт ТОЛЬКО ядра Xray** (= `systemctl reload x-ui` → USR1; панель не трогается). Дефолт для правок конфига и cron-скриптов — см. §7.8 |
| `x-ui status` | Текущее состояние (active/inactive) |
| `x-ui enable` | Включить автозагрузку через systemd |
| `x-ui disable` | Выключить автозагрузку |
| `x-ui log` | Хвост логов |
| `x-ui update` | Обновление панели до последней версии |
| `x-ui install` | Запуск установки (вызывается изнутри установщика) |
| `x-ui uninstall` | Полное удаление |
| `/usr/local/x-ui/x-ui setting` | Управление настройками; это ветка бинарника, в скрипте `x-ui` её нет (см. §4.1) |

В `x-ui.sh` (ветка main, сверено 2026-10-27) есть также команды `banlog`, `setup-fail2ban`,
`update-dev`, `legacy`, `update-all-geofiles`, `pgclient`; их назначение здесь не расписано.

### 4.1 Флаги `/usr/local/x-ui/x-ui setting`

Флаги относятся к бинарнику `/usr/local/x-ui/x-ui`; у скрипта-обёртки `x-ui` ветки `setting` нет.

| Флаг | Назначение |
|---|---|
| `-getApiToken -tokenName <имя> [-tokenScope <scope>]` | API-токен с именем и scope (scope см. `3x-ui-api.md` §2.4) |
| `-username "..."` | Изменить логин админа |
| `-password "..."` | Изменить пароль |
| `-port N` | Изменить порт панели |
| `-webBasePath "..."` | Изменить webBasePath (например, `/abc123/`) |
| `-reset` | Сброс настроек |
| `-show true` | Показать текущие значения |
| `-getCert true` | Получить путь до сертификата |
| `-resetTwoFactor true/false` | Сброс 2FA |

### 4.2 Команды миграции БД

Миграции схемы автоматические; с v3.10.0 update прогоняет их до запуска службы (v3.7.0
требует бэкап перед обновлением). Команда `x-ui migrateDB [file.db|file.dump] [output]` схему не
мигрирует, а конвертирует `.db` в `.dump` и обратно.

---

## 5. TLS-выпуск для панели

### 5.1 Три типа сертификатов

Из встроенной интеграции с acme.sh (см. Wiki Configuration):

1. **Domain Cert** — 90 дней, Let's Encrypt. Стандартный путь.
2. **IP Cert** — 6 дней, Let's Encrypt shortlived profile. Для сертификатов
   на IP (без домена). Редкий сценарий.
3. **Custom Cert** — пользовательский путь к существующему сертификату.

### 5.2 Способы выпуска

**Способ A: standalone HTTP-01 через acme.sh внутри панели.**
- Использует `--standalone`. Временно занимает порт 80.
- Скилл `/setup-vpn-panel`:
  1. Открывает порт 80 в UFW на время выпуска.
  2. Останавливает любые сервисы на 80 (если есть).
  3. Запускает выпуск через CLI 3X-UI или прямую правку настроек.
  4. После успешного выпуска — закрывает 80 (если он не нужен для других целей).

**Способ B: Cloudflare DNS-01.**
- Встроенная опция в `x-ui.sh` (поле email + Cloudflare Global API Key).
- Не требует освобождения порта 80.
- Работает только если домен делегирован на Cloudflare.

**Способ C: certbot standalone снаружи панели.**
- Альтернатива, если встроенный acme не работает или нужна гибкость.
- Сертификаты выпускаются в `/etc/letsencrypt/live/{domain}/`.
- Прописываются в настройках панели через `webCertFile` и `webKeyFile`
  (см. SQLite таблица `settings`).

### 5.3 DNS-01 кроме Cloudflare

В публичной документации Wiki Configuration / DeepWiki SSL — упоминается
**только Cloudflare** как встроенный DNS-провайдер. Другие DNS-провайдеры
(Yandex DNS, Route53, hosting.ru) — **не поддержаны встроенным механизмом**.

Решение: использовать `acme.sh` напрямую (он умеет десятки DNS-провайдеров),
выпустить вне панели, потом прописать `webCertFile`/`webKeyFile`. Это
способ C из §5.2.

---

## 6. Telegram-бот (опционально)

Из Wiki Advanced + DeepWiki Telegram Integration:

- Создаётся через BotFather, токен и chat ID вводятся в настройки панели.
- Уведомления, которые умеет посылать:
  - Daily traffic per inbound / per client.
  - Panel login (когда кто-то авторизовался).
  - Database backup (резервная копия БД).
  - System status (CPU/RAM/Disk).
  - Client info (по запросу `/usage <UUID>` боту).
- Резервная копия БД отправляется в Telegram через API endpoint
  `/panel/api/backuptotgbot` (см. `3x-ui-api.md`).
- Расписание уведомлений — cron syntax внутри панели.

### 6.1 Безопасность Telegram-бота

- chat ID должен быть **личный** (твой ID или приватная группа), не публичный канал.
- Токен бота — в менеджере паролей оператора.
- Бот должен быть **только для уведомлений**, не для управления (3X-UI не
  предоставляет команды управления через бота — это и хорошо, меньше attack
  surface).

---

## 7. Известные подводные камни

### 7.1 Issue #4390: ssl_cert_issue_main infinite-loops на closed stdin (закрыт 29.05.2026, GitHub: completed)

Версия с исправлением в issue не указана, живьём не проверено, обходной путь пока сохранять.

При автоматизации через cron / Ansible (где stdin закрыт) встроенный вызов
acme.sh попадает в бесконечный цикл → `systemctl restart storm`.

**Workaround:** не вызывать `x-ui` команды для выпуска cert через скрипты
с закрытым stdin. Использовать способ C (certbot снаружи) или способ B
(Cloudflare DNS — не требует stdin).

### 7.2 Issue #4406: VLESS+XHTTP outbound парсится неправильно (закрыт 19.05.2026, GitHub: completed)

Версия с исправлением в issue не указана, живьём не проверено, обходной путь пока сохранять.

Баг парсера XHTTP-конфигов в outbound. **Workaround:** не использовать XHTTP
transport в outbound. Использовать стандартные TCP / WS / gRPC transport.

### 7.3 Issue #4409: Cannot login after manual install on Ubuntu (закрыт 15.05.2026, GitHub: completed)

Версия с исправлением в issue не указана, живьём не проверено, обходной путь пока сохранять.

После ручной установки (не через официальный install.sh) логин не работает.
**Workaround:** использовать только официальный install.sh, не «ставить руками».

### 7.4 Database locking errors

Под нагрузкой SQLite может ловить database lock (особенно при массовом
добавлении клиентов через API). **Workaround:** паузы 100-200мс между
массовыми запросами (см. `3x-ui-api.md`).

### 7.5 Reverse-proxy и nginx (issue #3669, #3651)

Проблемы при попытке поставить 3X-UI за nginx proxy manager в Docker.
**Workaround:** ставить 3X-UI на хост (не в Docker), или использовать
прямой nginx vhost без Proxy Manager.

### 7.6 CPU/Disk overload при росте числа клиентов

При >50 активных клиентов SQLite начинает тормозить, CPU вырастает.
**Workaround:** сама 3X-UI поддерживает PostgreSQL (в релизах с v3.1.0); документация рекомендует
его при большом числе клиентов и для нескольких узлов. Перенос из SQLite:
`/usr/local/x-ui/x-ui migrate-db --dsn "<DSN>"` (в меню `x-ui`: Migrate SQLite -> PostgreSQL) или,
с v3.5.0, восстановлением `.db` в панели на PostgreSQL. Порог в 50 клиентов источником не
подтверждён.
Для домашних сценариев (1-20 клиентов) — несущественно.

### 7.7 Самонаезд через `/etc/environment` (self-loop)

**Критический подводный камень для сценария серверного прокси.**

3X-UI написан на Go. Go стандартная библиотека `net/http` уважает
`HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` через функцию
`httpproxy.FromEnvironment`.

Если в `/etc/environment` или systemd-юните стоит
`HTTPS_PROXY=socks5h://127.0.0.1:1080`, любой Go-процесс (включая x-ui
и xray) при HTTPS-запросах пытается ходить через эту проксю. Получается
петля: x-ui → http_proxy → mixed inbound (тот же x-ui) → x-ui → ...
Результат — падение с `INVALIDARGUMENT`.

**Решение:** systemd drop-in override:

```bash
systemctl edit x-ui
```

Содержание:

```
[Service]
Environment="HTTP_PROXY="
Environment="HTTPS_PROXY="
Environment="NO_PROXY=*"
```

Затем:

```bash
systemctl daemon-reload
systemctl restart x-ui
```

Это очищает переменные **только для этого юнита**, оставляя `/etc/environment`
глобальным для пользовательских сессий и других программ.

**Применяется автоматически скиллом `/setup-server-proxy`** как первый шаг,
до записи `/etc/environment`. Без него — сценарий серверного прокси
не работает.

### 7.8 Сохранение и перезапуск Xray после изменений

В UI после любого изменения (новый inbound, новый клиент, изменение
маршрутизации) нужно нажать «Сохранить» **И** «Перезапуск Xray». Без этого
изменения остаются только в SQLite, но не в работающем процессе Xray.

В REST API — то же самое: после CRUD-операций нужен явный вызов
`POST /panel/api/server/restartXrayService` (тот же путь на 2.8-2.9, проверено по коду тегов
v2.8.11 и v2.9.4; см. `3x-ui-api.md` §15). Скиллы
сисадмина это знают и вызывают автоматически.

**Рестарт ядра из скрипта/cron (от root, без API и без веб-панели) — `x-ui restart-xray`.**
Это самый надёжный путь, когда правишь `xrayTemplateConfig` в `x-ui.db` напрямую (fallback
мимо REST) или из крон-скрипта:
- `x-ui restart-xray` = `systemctl reload x-ui` → юнит имеет `ExecReload=/bin/kill -USR1 $MAINPID`
  → панель получает **USR1** и **мягко перезапускает ТОЛЬКО xray-core**. Процесс панели и
  веб/sub-порты (2053/2096) НЕ падают.
- **Не зависит от CSRF/логина/бота** (в отличие от REST API-пути `restartXrayService`, который
  требует авторизации и ломается на CSRF-middleware v3.0+ — рефлекс §3.8.11). Поэтому для
  cron-скриптов от root это дефолт, а НЕ `restartXrayService` и НЕ `systemctl restart x-ui`
  (последний рвёт и панель — обрывает всё).
- Канонический порядок fallback-правки: бэкап `x-ui.db` (§3.2) → правка `xrayTemplateConfig` →
  собрать candidate `config.json` и `xray -test` **до** записи → запись в БД → `x-ui restart-xray`.

> **Грабля: рестарт-hook на docker-bridge и ложная тревога HTTP 000.** Некоторые инсталляции
> держат самописный HTTP-хук (напр. `172.18.0.1:8381` → выполняет `x-ui restart-xray`) для вызова
> рестарта из контейнеров. Для скрипта на **хосте** он лишнее звено — зови `x-ui restart-xray`
> напрямую. Если всё же дёргаешь hook через `curl` и получил **HTTP 000** — это чаще всего НЕ
> провал рестарта, а обрыв соединения по короткому `--max-time`: сам `x-ui restart-xray` (reload
> → USR1 → `sleep` → показ статуса) идёт дольше твоего таймаута, curl закрывает сокет раньше
> ответа (у hook — BrokenPipe), но **рестарт по факту проходит**. Проверяй результат по смене PID
> ядра (`pgrep -f 'xray-linux-amd64 -c'`), а не по коду curl. Инцидент 2026-07-02.

---

## 8. Отказ от форков

Существует множество форков 3X-UI с собственными изменениями (свои наборы
эндпоинтов API, своя структура БД, свои дефолты безопасности). Скиллы
сисадмина работают **только с эталонной реализацией `MHSanaei/3x-ui`**.

**Проверка реализации** при работе со скиллами:

```bash
# через CLI
x-ui --help | grep -i "MHSanaei" || echo "NOT_MHSANAEI"

# через web UI
curl -s "https://$DOMAIN:$PORT$WEBPATH/" | grep -i "3X-UI" | head -3
```

Если реализация **не** mhsanaei — скилл отказывает с явным сообщением:

> Установлен форк 3X-UI, отличный от эталонной реализации MHSanaei/3x-ui.
> Я работаю только с эталонной реализацией, потому что состав API эндпоинтов,
> структура БД и поведение в форках непредсказуемы. Решения:
> 1. Установить эталонную версию (требует миграции данных).
> 2. Работать с форком вручную через его документацию (без меня).

Это **не аррогантность**, а защита от молчаливых поломок: скилл, пытающийся
дёргать API форка, может попасть в эндпоинт с другой семантикой и сделать
не то, что ожидалось.

---

## 9. Связь с другими документами

- `vpn-protocols.md` — какие протоколы поддерживает Xray (ядро под капотом
  3X-UI), что выбирать под задачу.
- `3x-ui-api.md` — REST API панели, эндпоинты, паттерны вызова через curl.
- `client-apps.md` — клиентские приложения, какие принимают подписки
  с этой панели.

---

*Документ обновляется планово раз в 6 месяцев. Триггеры внеплановой ревизии:
release с breaking changes в `MHSanaei/3x-ui` (миграция БД, переименование
эндпоинтов, новые типы inbound), смена встроенного механизма acme.sh,
изменения в Telegram bot API панели.*
