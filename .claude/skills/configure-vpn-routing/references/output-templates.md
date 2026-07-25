# Образцы записей и финального отчёта

Справка к скиллу `/configure-vpn-routing`. Открывать на **Шаге 9** (что писать в inventory
и в конфиг) и на **Шаге 10** (как выглядит финальный отчёт и smoke-check оператору).

Образцы формы: значения подставляются фактические, переписывать отсюда страны, порты
и количества нельзя (C.2).

---

# Шаг 9. Записи в inventory и конфиг

Inventory — в `inventory/hosts/$SERVER_ALIAS/networks.md` добавляется раздел
`## VPN routing` с подразделами:

- **Inbound** — `inbound-$INBOUND_PORT` (vless-`$INBOUND_PROTOCOL`); клиенты + ссылка
  на UUID в `vpn-clients/*.md`.
- **Outbound** — страна выхода `$EXIT_COUNTRY`, пресет `$OUTBOUND_PRESET`; теги
  `upstream-*` (от провайдера ИЛИ свой загр.VPS); файл серверов подписки в
  `shared/vpn-subscriptions/<provider>.json`.
- **Balancer** — `upstream-balancer` (leastPing, observatory probeInterval=5m);
  при пресете `single` балансира нет, один фиксированный outbound.
- **Routing** — модель «золотая середина», 7 правил (перечень — в `<goals>` / Шаг 6).

`infra-config.json` — `vpn.upstream_kind` обновляется (`subscription` /
`self-foreign` / `mixed`).

---

# Шаг 10. Финальный отчёт

```
✓ Inbound создан/использован: id=$INBOUND_ID, port=$INBOUND_PORT, protocol=$INBOUND_PROTOCOL
✓ Сервера подписки сохранены: $INFRA/inventory/shared/vpn-subscriptions/$PROVIDER_SLUG.json
✓ Страна выхода: $EXIT_COUNTRY, пресет: $OUTBOUND_PRESET
✓ Outbounds: $UPSTREAM_COUNT штук (только страны $EXIT_COUNTRY), kind=$OUTBOUND_KIND
✓ Balancer: $BALANCER_STRATEGY, probeInterval=$PROBE_INTERVAL (если пресет country-failover)
✓ Routing: 7 правил (private→direct, реклама/bittorrent→block, geoip:ru + category-ru + regex→direct, остальное→upstream)
✓ Клиентов: $CLIENT_COUNT
✓ Inventory обновлён: $INFRA/inventory/hosts/$SERVER_ALIAS/networks.md
✓ Config обновлён: vpn.upstream_kind=$OUTBOUND_KIND

🔍 Smoke check: открой панель $PANEL_URL (видны новые inbound/outbound/clients) →
  выпусти ссылку клиента через /generate-client-config → импортируй в Happ/Hiddify →
  проверь на 2ip.ru (РФ-сайты → твой РФ-IP, зарубежные → IP upstream; реклама режется).

➡️  Следующий шаг (опционально): `/generate-client-config` для генерации
    QR-кодов и sing-box JSON для клиентских устройств.
```

