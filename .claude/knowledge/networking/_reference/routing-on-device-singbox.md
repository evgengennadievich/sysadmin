---
knowledge_domain: vpn
layer: reference
last_researched: 2026-10-27
ttl_days: 60
sources_checked:
  - https://sing-box.sagernet.org/configuration/route/
  - https://sing-box.sagernet.org/clients/
  - https://github.com/SagerNet/sing-box/releases
  - https://github.com/GUI-for-Cores/GUI.for.SingBox
  - https://apps.apple.com/app/id6673731168
  - https://sing-box.sagernet.org/changelog/
  - https://sing-box.sagernet.org/deprecated/
  - https://itunes.apple.com/lookup?id=6785326793&country=ru
  - https://sing-box.sagernet.org/migration/
  - https://sing-box.sagernet.org/clients/apple/
  - https://github.com/throneproj/Throne/releases
  - https://itunes.apple.com/lookup?id=6673731168&country=ru
---

# Гибкая маршрутизация НА УСТРОЙСТВЕ через sing-box — для энтузиастов

Этот документ — **альтернативный, НЕ дефолтный** способ. Split (РФ → direct,
foreign → proxy, реклама → block) делается **на устройстве** в клиенте на ядре
sing-box, а не на сервере. Дефолт — серверная маршрутизация
(`routing-server-3xui.md`); этот путь выбирают, только если осознанно хотят
прямой выход РФ-трафика и готовы погрузиться в настройку.

Читают: персона при запросе «хочу маршрутизацию прямо на телефоне/компе»;
скилл `/generate-client-config` при `platform=*` с on-device routing.

Связан с:
- `routing-server-3xui.md` (дефолтный путь — split на сервере)
- `routing-on-device-xray.md` (то же, но на ядре Xray в терминале)
- `client-apps.md` (карта клиентов, версии ядер, форматы импорта)
- `vpn-consultation-flow.md` (сценарий консультации, TUN, hub)

---

## §0 Зачем и почему НЕ дефолт

**Зачем on-device split:** РФ-трафик выходит **напрямую** с устройства, минуя
РФ-сервер: `устройство → (direct) → РФ-сайт`. Экономит один hop (~10-20 мс),
РФ-сайт видит реальный домашний IP, сервер не грузится РФ-трафиком.

**Почему НЕ дефолт (по опыту оператора):**

1. **Выигрыш 10-20 мс не оправдывает сложность.** Для типового пользователя
   разница незаметна. Серверный split (`routing-server-3xui.md`) даёт то же
   разделение РФ/foreign без единой настройки на устройстве.
2. **Единственное ядро, которое честно исполняет произвольный raw route на
   устройстве — sing-box.** Hiddify не даёт править сырой route руками (строит
   из подписки сам, см. `client-apps.md`). То есть выбора клиентов мало.
3. **Состояние sing-box-клиентов на 2026-05-22 неровное** (см. §3): на iOS —
   свежее ядро снова в App Store (sing-box MT, ветка 1.14, с 31.08.2026), ядро 1.11 осталось только
   в старых копиях VT; на десктопе и Android ядро свежее, но требует
   разобраться с raw JSON.
4. **Раскол формата ядра 1.11↔1.12** (см. §2) — главная засада «одного конфига
   на все устройства».

Вывод для агента: предлагать этот путь только пользователю, который сам просит
прямой выход РФ-трафика и готов работать с raw JSON. Иначе — серверный split.

---

## §1 Механика: split исполняет ядро sing-box, не приложение

«Гибкая маршрутизация» — это **route-правила ядра sing-box**, а не фича
конкретного приложения. Приложение (SFA, GUI.for.SingBox) — лишь оболочка,
которая подаёт ядру JSON-конфиг. Поэтому:

- логика split привязана к **ядру sing-box**, не к бренду клиента;
- любой клиент на чистом sing-box-ядре исполнит одинаковый route;
- Hiddify — тоже на форке sing-box, но не даёт писать произвольный route руками,
  поэтому для on-device split не годится.

Структура route в sing-box JSON:

```json
"route": {
  "rules": [
    { "ip_is_private": true, "outbound": "direct" },
    { "rule_set": "geosite-category-ads-all", "action": "reject" },
    { "rule_set": ["geoip-ru", "geosite-ru"], "outbound": "direct" },
    { "domain_suffix": [".ru", ".su"], "outbound": "direct" }
  ],
  "final": "proxy",
  "rule_set": [ "...определения geoip-ru, geosite-ru, ads..." ]
}
```

> Это **sing-box-синтаксис**, НЕ Xray. Серверные правила из
> `routing-server-3xui.md` (формат `{"type":"field","outboundTag":...}`) сюда не
> ложатся as is.

---

## §2 Раскол формата ядра 1.11 ↔ 1.12 — главная засада

Последняя stable ядра sing-box: **1.14.4 (24.10.2026)**; 1.14.0 вышел 31.08.2026, ветка 1.15 в alpha (1.15.0-alpha.13). Но клиенты сидят на
разных версиях, и между 1.11 и 1.12 сломался формат конфига. Ключевые рубежи:

| Версия | Что сломалось в формате |
|---|---|
| 1.11.0 (2025-01-30) | rule actions: `type:"block"`/`type:"dns"` → `action:"reject"`/`"hijack-dns"` |
| **1.12.0 (2025-08-04)** | **Формат DNS:** старое `dns.servers[].address` (строка-URL) → новое `{type, server}`. WireGuard outbound → endpoints |
| 1.13.0 (2026-02-28) | legacy special outbounds (`block`/`dns`) удалены; legacy DNS-форматы помечены deprecated ещё в 1.12.0, удаление в 1.14.0 |
| **1.14.0 (2026-08-31)** | legacy-формат DNS-серверов удалён; legacy special outbounds (`block`/`dns`) удалены ещё в 1.13.0. Помечены устаревшими с удалением в 1.16.0: `download_detour` у remote rule-set (замена `http_client`), неявный HTTP-клиент для remote rule-set (задать `http_clients` и `route.default_http_client` явно), legacy `strategy` в DNS rule action, `independent_cache`, `store_rdrc`, legacy address filter fields в DNS-правилах. Уточнена семантика ссылки на rule-set: слитное сопоставление только для rule-set из одного `default`-правила без `invert`, остальные сопоставляются как отдельное поле |
| 1.15.0 (alpha) | TUN-опция `stack` deprecated, удаление в 1.17.0 (свой TCP/IP-стек sing-tun) |

**Практическое следствие: два DNS-профиля.** «Один конфиг на все устройства»
не работает, если в парке осталась старая копия sing-box VT на 1.11 (см. §3):

- **legacy-профиль** (DNS строкой `"address":"https://1.1.1.1/dns-query"`,
  `"address":"local"`): только для старых копий VT на ядре 1.11 и, возможно, Hiddify;
- **modern-профиль** (`{"type":"https","server":"1.1.1.1"}`): для всех остальных,
  включая iOS (sing-box MT), Android и desktop на ядре 1.12+.

Legacy-формат принимают только ядра 1.12-1.13 (с deprecation-warning); на 1.14+ (SFA 1.14.x, SFM,
sing-box MT, CLI) конфиг с ним не загрузится. Стратегия «один legacy-конфиг на всех» закрыта:
legacy-профиль нужен только старым копиям VT 1.11 (и, возможно, Hiddify, версия ядра внутри не
проверена), всем остальным modern-профиль.

Полная карта «какая фича с какой версии» — `client-apps.md` §9.2.

---

## §3 Состояние sing-box-клиентов на 2026-05-22

Подробные ссылки и версии — `client-apps.md`. Сводка под on-device routing:

| Платформа | Клиент | Ядро | Raw JSON руками? | Заметка |
|---|---|---|---|---|
| **iOS** | sing-box MT (= SFI, офиц.) | ветка 1.14 (приложение v1.14.8 от 24.10.2026, версия ядра внутри не сверена) | да, полностью (локальный или удалённый конфиг) | App Store, есть и в RU; TestFlight-бета по-прежнему только спонсорам |
| **iOS** | sing-box VT | **1.11.4 (заморожен)** | да, полностью | **Удалён из App Store во всех регионах** (API 26.08.2026); живут только установленные копии, для них legacy-формат |
| **iOS** | Karing | модиф. sing-box | модель «подписка», не подтверждено | App Store, активный |
| **Android** | SFA (офиц.) | **апстрим 1.14.x** | да, полностью | эталон стабильности, GitHub APK |
| **Android** | NekoBox | форк 1.12.x | **максимум** (3 слоя инъекции JSON) | краши в фоне, редкие апдейты |
| **Android** | husi | форк | модель NekoBox | живее NekoBox, Codeberg |
| **Desktop** | GUI.for.SingBox | **версия выбирается вручную** | да (Script-хук) | главный выбор для десктопа |
| **Desktop** | SFM (офиц., macOS) | апстрим 1.14.x | да (внешний редактор) | только standalone: `brew install --cask sfm` или GitHub |
| **Desktop** | Throne | 1.3.2 (29.09.2026), версия ядра не проверена | да, прямой доступ | форк nekoray, Qt |
| **Desktop (Win/Linux)** | sing-box for Desktop (офиц., с 1.14.0) | апстрим 1.14.x | не проверено | GitHub Releases SagerNet |

**iOS (обновлено 2026-10-27):** боль снята. Официальный клиент вернулся в App Store как sing-box MT
(новый аккаунт разработчика, sing-box 1.14.0 от 31.08.2026), он есть и в RU App Store. VT застрял на
1.11.4 и снят из стора; его пользователям ставить MT. Нижняя планка общего конфига теперь 1.12
(modern DNS `{type, server}`): legacy DNS удалён в 1.14.0, и на клиентах 1.14+ legacy-конфиг не загрузится.

---

## §4 Ограничения по платформам (из офиц. доки sing-box)

| Опция / правило | iOS | macOS | Android | Linux/Win |
|---|---|---|---|---|
| `strict_route` | ❌ not impl. | ✅ | ✅ | ✅ |
| `process_name` / `process_path` | ❌ no perm | ❌ no perm | — | ✅ |
| per-app по `package_name` | ❌ | ❌ | ✅ **только Android** | — |
| `wifi_ssid` / `wifi_bssid` | ✅ **только iOS** | ❌ | ❌ | ❌ |
| TUN | через NetworkExtension (unprivileged) | NE | VpnService | root/CAP_NET_ADMIN |

Следствия:
- **per-app routing** (направить конкретное приложение через/мимо VPN) — реально
  только на **Android** через `package_name`. На iOS/macOS этого нет.
- **`wifi_ssid`** — iOS-эксклюзив: удобно «дома direct, в чужой сети → VPN».
- Лимит памяти Network Extension на iOS **~50 МБ** → jetsam-краши на speedtest
  100+ Мбит/с. Общая боль всех sing-box-клиентов на iOS, не зависит от приложения.

Для `/generate-client-config` при `platform=ios`: не использовать
`strict_route`, `process_name`; DNS писать в modern-формате `{type, server}` (sing-box MT, 1.12+),
legacy-формат (ядро 1.11) только по явному запросу для старой копии VT;
маршрутизация только через rule_set + ip_cidr + domain_*.

---

## §5 Ссылки на установку (проверено 2026-05-22)

Полный список с версиями — итог сегодняшнего исследования. Кратко:

**iOS:**
- sing-box MT (офиц. SFI, App Store, есть в RU): https://apps.apple.com/app/sing-box-mt/id6785326793; TestFlight-бета только спонсорам (Telegram @yet_another_sponsor_bot)
- sing-box VT: https://apps.apple.com/app/id6673731168 (ядро 1.11.4; в App Store RU, US, KZ нет по API 27.10.2026, новых установок нет)
- Karing: https://apps.apple.com/us/app/karing/id6472431552

**Android:**
- SFA (офиц., v1.14.4): https://github.com/SagerNet/sing-box/releases (брать с GitHub SagerNet; в Google Play издатель указан как Metamerism)
- NekoBox (v1.4.2): https://github.com/MatsuriDayo/NekoBoxForAndroid/releases
- husi (v1.2.0): https://codeberg.org/xchacha20-poly1305/husi/releases (GitHub-зеркало заморожено на 1.0.2 — брать с Codeberg)

**Desktop (главный выбор — GUI.for.SingBox):**
- GUI.for.SingBox (v1.28.1 от 21.10.2026): https://github.com/GUI-for-Cores/GUI.for.SingBox/releases; версия ядра выбирается внутри приложения (вкладка Kernel)
- SFM (офиц., macOS, 1.14.4): `brew install --cask sfm` или https://github.com/SagerNet/sing-box/releases/latest; в Mac App Store больше нет
- Throne (1.3.2 от 29.09.2026; 1.4.0-beta.x): https://github.com/throneproj/Throne/releases
- sing-box CLI: `brew install sing-box` ✅ / Linux пакеты на https://sing-box.sagernet.org/installation/package-manager/

Не подтверждено (проверять вручную): точный TestFlight-URL беты sing-box MT (SFI);
Homebrew cask для GUI.for.SingBox/Throne/Karing.

---

## §6 Рекомендация по выбору клиента под on-device split

| Платформа | Бери | Почему |
|---|---|---|
| macOS | GUI.for.SingBox (+ SFM для отладки) | сам выбираешь версию ядра, Script-хук = полный контроль route |
| Windows/Linux | GUI.for.SingBox | одна кодовая база, raw route через Script |
| Android | SFA (стабильность) или NekoBox (правка JSON в приложении) | SFA = чистое 1.14; NekoBox = глубже, но краши в фоне |
| iOS | sing-box MT (App Store, в том числе RU) | официальный клиент, свежее ядро, локальный или удалённый raw-конфиг |

---

## §7 Связи

- **Дефолтный путь (split на сервере):** `routing-server-3xui.md`
- **On-device через Xray (терминал):** `routing-on-device-xray.md`
- **Карта клиентов, версии ядер, форматы:** `client-apps.md`
- **Сценарий консультации, TUN, hub:** `vpn-consultation-flow.md`
- **Теория протоколов:** `vpn-protocols.md`
- **Транспорты:** `transports.md`
- **Фронт блокировок:** `_live/frontline-ru.md`
- **Скилл:** `/generate-client-config`
