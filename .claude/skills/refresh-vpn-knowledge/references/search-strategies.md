# Стратегии поиска для разных knowledge-файлов

Этот документ — карта запросов, которые скилл `/refresh-vpn-knowledge`
формулирует под каждый файл. Цель — переиспользуемые поисковые формулы,
которые не нужно сочинять заново каждый раз.

Открывать на **Шаге 2** процедуры (WebSearch-обход): взять отсюда готовые формулы
под тот файл, который актуализируешь.

---

# Куда смотреть по слоям (карта источников)

Общая раскладка «файл → источники». Развёрнутые формулы запросов — ниже по документу.

## Слой `_live/` — ежедневное состояние блокировок

| Файл | Источники |
|---|---|
| `frontline-ru.md` | `site:ntc.party 2026 Russia VPN` + `site:gfw.report Russia` + `site:blog.cloudflare.com Russia` + Mediazona / Meduza / Moscow Times за последние недели |
| `frontline-cn.md` | `site:gfw.report 2026` + net4people/bbs + GreatFire + issues Xray-core / sing-box + USENIX. **Читается при каждом прогоне `live` (Шаг 2а), а не только по TTL**; формулы ниже |
| `frontline-ir.md` | arxiv preprints + Iran censorship reports 2026 |
| `frontline-by.md` | Carnegie + RFE/RL + CSO Meter Belarus 2026 |
| `timeline.md` | добавляются новые события из всех `frontline-*` |

## Слой `_reference/` — устройство мира, меняется реже

| Файл | Источники |
|---|---|
| `vpn-protocols.md` | `XTLS/Xray-core releases` + `SagerNet/sing-box releases` + `MHSanaei/3x-ui releases` |
| `transports.md` | новые transport-фичи в release notes XTLS / sing-box |
| `fronting-strategies.md` | Cloudflare blog + новые CDN-fronting туториалы |
| `client-apps.md` | `sing-box iOS client release` + `Hiddify release notes` + `Karing release` + удаления из App Store |
| `3x-ui-panel.md`, `3x-ui-api.md` | MHSanaei/3x-ui issues и releases |

## Слой `_meta/` — стабильное, обновляется по запросу

| Файл | Когда трогаем |
|---|---|
| `sources-registry.md` | добавление или удаление источника по факту |
| `glossary.md` | новые термины (XHTTP, AnyTLS и т.п.) |
| `conflicts.md` | разрешение старых конфликтов |

---

# Формулы запросов по файлам

## vpn-protocols.md

**Что отслеживаем:** Reality status в РФ, новые VPN-протоколы вытесняющие VLESS,
блокировки на уровне TSPU.

**WebSearch-запросы (быстрый скан, бесплатно):**
- `Russia VPN blocks 2026 Reality protocol`
- `TSPU DPI VLESS-Reality bypass site:ntc.party`
- `XTLS Xray-core release notes 2026`
- `AmneziaWG Russia status 2026`

**Tavily research (по подтверждению WebSearch):**
- `Что изменилось в блокировках Russia VPN с <last_researched>? Особенно
   интересуют: Reality fingerprint, TSPU сигнатуры, новые сценарии активного
   зондирования (active probing).`

**Что искать в первую очередь:**
1. Изменился ли список «работающих в РФ» protocol+transport комбинаций.
2. Новые рекомендации по `serverName` для Reality (если cloudflare.com сломался).
3. Появились ли новые transport-слои (например, ShadowQuic).

## client-apps.md

**Что отслеживаем:** новые релизы клиентов sing-box/Hiddify/Karing, удаления
из App Store, новые версии sing-box-core.

**WebSearch-запросы:**
- `sing-box iOS App Store 2026 removed`
- `Hiddify release notes 2026`
- `sing-box-vt iOS update 2026`
- `Karing v<X> changelog`
- `v2rayNG Android release 2026`

**Tavily research:**
- `Какие VPN-клиенты на iOS/Android/desktop наиболее актуальны для подключения
   к VLESS-Reality серверу из РФ в 2026? Что было удалено/добавлено в App Store
   с <last_researched>?`

**Что искать в первую очередь:**
1. Минимальная версия sing-box-core по платформам (нижняя планка совместимости).
2. iOS-клиенты — какой сейчас «эталонный» (sing-box-vt vs Karing vs Streisand vs Happ).
3. Android — есть ли альтернатива sing-box-for-android.

## 3x-ui-panel.md

**Что отслеживаем:** релизы 3X-UI, breaking changes в установщике, новые issues.

**WebSearch-запросы:**
- `MHSanaei 3x-ui release notes 2026`
- `3x-ui breaking changes 2026 install`
- `3x-ui issues open site:github.com`

**Tavily research:**
- `Какие breaking changes произошли в 3X-UI с <last_researched>? Изменился ли
   install.sh, web-base-path, structure config.json?`

**Что искать в первую очередь:**
1. Новая минимальная версия для production (рекомендуемая стабильная).
2. Изменения в формате SQLite БД (миграции между версиями).
3. Новые операционные грабли (telegram-bot integration, TLS quirks).

## 3x-ui-api.md

**Что отслеживаем:** breaking changes в REST API.

**WebSearch-запросы:**
- `3x-ui REST API breaking changes 2026`
- `3x-ui API new endpoints 2026`

**Tavily research:**
- `Изменился ли REST API 3X-UI с <last_researched>? Если да — какие endpoints
   удалены/добавлены, изменён ли формат cookie-аутентификации?`

**Что искать в первую очередь:**
1. Endpoint'ы которые скилл `/configure-vpn-routing` использует (`/panel/api/inbounds/list`,
   `/panel/api/inbounds/add`, `/panel/api/inbounds/update`).
2. Изменения в формате client-объекта (UUID, flow, security fields).
3. Новые методы (если что-то добавили — обязательно зафиксировать).

## frontline-cn.md (GFW как предвестник для РФ)

**Зачем отдельно:** GFW опережает ТСПУ на 6-12 месяцев (ADR-0006). Файл
проверяется при каждом прогоне `LAYER=live` по Шагу 2а `SKILL.md`, а не только по
своему TTL. Цель не «знать про Китай», а получить прогноз: что из нашего стека
под ударом следующим.

**Что отслеживаем:** новые техники детекции GFW (сигнатуры, поведенческий анализ,
active probing, работа с UDP и TLS-отпечатками), удары по Xray / Reality / XHTTP /
sing-box / Hysteria2 / TUIC, контрмеры сообщества (новые транспорты, патчи ядра).

**WebSearch-запросы (быстрый скан, бесплатно):**
- `site:gfw.report <год>`
- `site:github.com/net4people/bbs GFW <год>`
- `GFW blocking Reality XHTTP <год>`
- `GFW active probing new detection <год>`
- `site:github.com/XTLS/Xray-core GFW blocked` (issues и discussions)
- `site:github.com/SagerNet/sing-box GFW`
- `Great Firewall <год> new censorship technique USENIX FOCI`
- `site:greatfire.org <год>`

**Tavily research (по подтверждению WebSearch):**
- `Какие новые техники блокировки и детекции применяет GFW с <last_researched>?
   Особенно: Reality, XHTTP, sing-box, Hysteria2/TUIC, TLS-fingerprint, active
   probing, UDP. Что из этого уже повторил ТСПУ в России?`

**Что искать в первую очередь:**
1. Техника, бьющая по нашему стеку (VLESS+Reality, XHTTP, sing-box у клиентов).
2. Ответ разработчиков: релиз или обсуждение в Xray-core / sing-box со словами
   GFW, blocked, 被墙 (китайское «за стеной», так помечают issues о блокировке).
3. Признаки, что ТСПУ уже повторяет приём: перекрёстный поиск по ntc.party и
   РФ-источникам с тем же названием техники.

**Перевод находки в прогноз для РФ** (форма записи в Шаге 2а `SKILL.md`): что в
Китае / что у нас под ударом / горизонт 6-12 мес / что готовить / статус ПРОГНОЗ.
Горизонт короче только при источнике по РФ, показывающем начало повтора.

**Веса источников по `_meta/sources-registry.md`:** gfw.report, net4people/bbs,
Xray-core, sing-box это HIGH; GreatFire это MEDIUM; форумы и Telegram LOW.
Академические работы (USENIX, FOCI) в реестре пока не описаны: при первом
использовании добавить в `sources-registry.md` §6 с весом и обоснованием.

# Общие правила

- **WebSearch — это «есть ли вообще что-то новое?»** Если поиск возвращает только
  результаты до `last_researched` — файл свежий, Tavily не нужен.
- **Tavily — для синтеза**, когда WebSearch выявил что-то новое.
- **Никогда не доверяй одному источнику** — для критичных утверждений ищи
  подтверждение в 2+ независимых местах.
- **Сохраняй URL'ы**, на которые опирался — они идут в `sources_checked` нового
  knowledge-файла (это аудит-trail для следующего refresh).
