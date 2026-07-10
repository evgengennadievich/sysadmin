#!/usr/bin/env bash
# .claude/skills/inventory-scan/scripts/dump-snapshot.sh
#
# Bundled-копия v2 dump-скрипта инвентаризации сервера. Снимает read-only снимок
# состояния: контейнеры, compose-файлы, сети, тома, ресурсы хоста, cron, nginx,
# TLS-сертификаты, host-scripts, .env (redacted), systemd-юниты, доступные апдейты.
#
# БЕЗОПАСНОСТЬ (redaction v2): секреты в env контейнеров (docker inspect) и в
# .env-файлах хоста маскируются ДО записи на диск — KEY=value с секрет-именами
# и креды в URL (scheme://user:pass@host) заменяются на <REDACTED>. Имена
# переменных сохраняются для аудита. См. meta.txt (redaction_applied) и
# references/dump-snapshot-quirks.md.
#
# Использование:
#   bash dump-snapshot.sh <SERVER> [DATE] [INVENTORY_DIR]
#
# SERVER — обязательный параметр (защита от случайного захода на чужой сервер):
#   user@host  или  SSH-алиас из ~/.ssh/config  или  `local`.
#
# Примеры:
#   bash dump-snapshot.sh local                          # локальная машина (без SSH)
#   bash dump-snapshot.sh root@<your-server-ip>          # по IP
#   bash dump-snapshot.sh prod                           # SSH-алиас из ~/.ssh/config
#   bash dump-snapshot.sh root@10.0.0.1 2026-01-01       # произвольный сервер и дата
#   bash dump-snapshot.sh prod today /tmp/inv            # альтернативный INVENTORY_DIR
#
# Создаёт ~16 файлов в ${INVENTORY_DIR}/hosts/<HOST_DIR>/snapshots/<DATE>/
# (containers, networks, volumes, host-resources, crontab, nginx-sites, tls-certs,
#  host-scripts-list, host-scripts-content, host-env-redacted, cron-d-content,
#  systemd-enabled, systemd-timers, watchers, compose-files,
#  containers-inspect.json, meta.txt).

set -euo pipefail

# SERVER — обязательный аргумент. Без него — fail-fast с подсказкой,
# чтобы оператор случайно не пошёл на чужой сервер.
if [ "$#" -lt 1 ]; then
    echo "ERROR: SERVER не задан." >&2
    echo "Использование: bash dump-snapshot.sh <SERVER> [DATE] [INVENTORY_DIR]" >&2
    echo "  SERVER — user@host / SSH-алиас / 'local'." >&2
    exit 2
fi

SERVER="$1"
DATE="${2:-$(date +%Y-%m-%d)}"
INVENTORY_DIR="${3:-${INVENTORY_DIR:-inventory}}"

# === Определение имени хоста для пути ===
# Канон имени папки хоста — из infra-config.json servers[].alias; его передаёт
# SKILL через env HOST_DIR (Шаг 2). Без override выводим из SSH-target как
# fallback, НО это риск раздвоить inventory: алиас `selectel` дал бы `prod-selectel`,
# а записанный хост — `prod-82.148.28.22` (находка /retro 2026-06-14). Поэтому при
# расхождении канона и выведенного — громко предупреждаем и берём канон.
if [ "$SERVER" = "local" ]; then
    DERIVED_HOST_DIR="local-$(hostname -s)"
else
    # user@1.2.3.4 -> prod-1.2.3.4 | user@hostname -> prod-hostname | ssh-alias -> prod-ssh-alias
    DERIVED_HOST_DIR="prod-${SERVER#*@}"
fi
if [ -n "${HOST_DIR:-}" ]; then
    [ "$HOST_DIR" != "$DERIVED_HOST_DIR" ] && \
        echo "  [i] HOST_DIR из config='${HOST_DIR}' ≠ выведенного из SSH-target='${DERIVED_HOST_DIR}' — беру канон из config (не плодим второй каталог inventory)."
else
    HOST_DIR="$DERIVED_HOST_DIR"
fi

SNAPSHOT_DIR="${INVENTORY_DIR}/hosts/${HOST_DIR}/snapshots/${DATE}"

echo "======================================================"
echo "dump-snapshot.sh — снимок сервера (bundled v2)"
echo "Сервер:        ${SERVER}"
echo "Хост-dir:      ${HOST_DIR}"
echo "Inventory dir: ${INVENTORY_DIR}"
echo "Папка снимка:  ${SNAPSHOT_DIR}"
echo "======================================================"

# === Блок проверки предусловий ===
echo ""
echo "Проверка предусловий..."

if [ "$SERVER" = "local" ]; then
    # Локальный режим — без SSH
    if ! command -v docker &>/dev/null; then
        echo ""
        echo "ОШИБКА: Docker не найден на локальной машине."
        echo "Установи Docker: https://docs.docker.com/engine/install/"
        exit 1
    fi
    echo "  [OK] Docker доступен локально"
    echo "  [OK] Режим: локальный (без SSH)"
    run_cmd() { eval "$1"; }
else
    # Удалённый режим — через SSH

    # 1. Проверка SSH-доступа
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$SERVER" 'echo ok' >/dev/null 2>&1; then
        echo ""
        echo "ОШИБКА: Не удалось подключиться к ${SERVER} по SSH."
        echo ""
        echo "Проверь:"
        echo "  1. Сервер включён и доступен по сети"
        echo "  2. SSH-ключ настроен: ssh-copy-id ${SERVER}"
        echo "  3. Нет блокировки по firewall (порт 22 открыт)"
        echo "  4. Правильный пользователь в адресе (root@...)"
        exit 1
    fi
    echo "  [OK] SSH-доступ к ${SERVER} есть"

    # 2. Проверка Docker на сервере
    if ! ssh -o ConnectTimeout=10 "$SERVER" 'command -v docker' >/dev/null 2>&1; then
        echo ""
        echo "ОШИБКА: Docker не найден на сервере ${SERVER}."
        echo "Docker не установлен — снимок контейнеров невозможен."
        echo "Установи Docker: https://docs.docker.com/engine/install/"
        exit 1
    fi
    echo "  [OK] Docker найден на сервере"

    # 3. Проверка версии bash на сервере (мягкое предупреждение)
    REMOTE_BASH_VER=$(ssh -o ConnectTimeout=10 "$SERVER" \
        'bash --version 2>/dev/null | head -1 | grep -oE "version [0-9]+" | grep -oE "[0-9]+"' \
        2>/dev/null || echo "0")
    if [ "${REMOTE_BASH_VER:-0}" -lt 4 ] 2>/dev/null; then
        echo "  [WARN] bash < 4 на сервере (версия: ${REMOTE_BASH_VER}). Скрипт продолжит."
    else
        echo "  [OK] bash >= 4 на сервере"
    fi

    echo "  [OK] Предусловия пройдены. Режим: SSH"
    # Опции против засорения снимка stderr'ом самого ssh-клиента (баг до v1.4.3):
    #   LogLevel=ERROR   — глушит WARNING/INFO ssh-клиента (post-quantum warning,
    #                      «ControlSocket ... already exists», болтовню мультиплексора),
    #                      но пропускает ERROR/FATAL — реальные сбои соединения видны.
    #   ControlMaster=no — для этих коротких одноразовых команд не используем
    #                      мультиплексирование оператора (ControlMaster auto в его
    #                      ~/.ssh/config даёт «mux_client_request_session»,
    #                      «Connection reset by peer» в stderr на OpenSSH 9.x / Windows).
    # stderr самой удалённой команды это НЕ трогает — он отделяется в run_remote.
    run_cmd() { ssh -o ConnectTimeout=10 -o LogLevel=ERROR -o ControlMaster=no "$SERVER" "$1"; }
fi

# === Создаём папку снимка ===
mkdir -p "$SNAPSHOT_DIR"

# === Redaction секретов в снимке ===
# Любой dump может случайно уйти в коммит, bug-report или бэкап. Маскируем
# секреты ДО записи на диск — а не надеемся только на .gitignore (последний
# рубеж, не основная защита).
#
# Закрываем ДВА паттерна, оба зафиксированы в references/dump-snapshot-quirks.md:
#   1. KEY=value   — env-переменные вида OPENROUTER_API_KEY=sk-or-v1-...
#   2. url://user:pass@host — пароль внутри connection-string (postgres://, redis://, amqp://...)
#
# Без жёсткой зависимости от jq (его часто нет на macOS/Git-for-Windows у
# оператора, через которого проходит snapshot — см. инцидент Windows-портабельности).
# Если jq есть — используем его для structurally-aware redaction .Config.Env;
# если нет — построчный fallback на sed/grep, работающий везде. Защита не
# должна зависеть от того, что доустановил оператор.

REDACTION_VERSION="v2"

# Функции маскировки redact_stream / redact_json_with_jq живут в единой
# библиотеке _lib/redact.sh (канон redaction v2) — её же используют
# rotate-secrets и другие скиллы. Не дублируем код: при изменении паттернов
# правится ОДНО место. Если библиотека не найдена — fail-fast: молча писать
# снимок без маскировки нельзя (приоритет №1 — секреты не утекают).
DUMP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDACT_LIB="$DUMP_SCRIPT_DIR/../../_lib/redact.sh"
if [ -f "$REDACT_LIB" ]; then
    # shellcheck source=/dev/null
    source "$REDACT_LIB"
else
    echo "ERROR: библиотека маскировки не найдена: $REDACT_LIB" >&2
    echo "Снимок БЕЗ redaction создавать запрещено. Запускай скрипт из репо sysadmin/" >&2
    echo "(bash .claude/skills/inventory-scan/scripts/dump-snapshot.sh ...)." >&2
    exit 2
fi

if command -v jq &>/dev/null; then
    REDACTION_TOOL="jq"
else
    REDACTION_TOOL="sed-fallback"
fi

# === Вспомогательная функция записи секции ===
# run_remote <имя_файла> <команда>
#
# КАЖДАЯ секция проходит через redact_stream ДО записи на диск. Раньше
# redaction применялся только к containers-inspect.json и host-env-redacted.txt,
# а остальные секции (crontab, host-scripts-content, nginx-sites) писались
# сырыми — и секрет в query-string cron-задачи утекал открытым текстом
# (граблекейс selectel). Теперь redaction — общий рубеж для всех run_remote,
# а meta.txt:redaction_applied=true перестаёт вводить в заблуждение.
run_remote() {
    local label="$1"
    local cmd="$2"
    local outfile="${SNAPSHOT_DIR}/${label}"
    local errfile="${SNAPSHOT_DIR}/${label}.stderr.log"
    echo "  -> ${label}..."

    # Разделяем потоки (fix v1.4.3): stdout (данные команды) → файл снимка,
    # stderr (диагностика удалённой команды) → отдельный *.stderr.log рядом.
    # Раньше было `run_cmd ... 2>&1 | redact_stream`, и stderr самого ssh-клиента
    # (mux_client_request_session, post-quantum warning, ControlSocket...) попадал
    # ПРЯМО в файл снимка — ломая идемпотентность (следующий скан собирал его же).
    # Теперь ssh-шум заглушён в run_cmd (LogLevel/ControlMaster), а stderr — отделён.
    # ОБА потока проходят redact_stream: stderr тоже может содержать секреты
    # (например, ошибка с connection-string) — секреты маскируются везде (приоритет №1).
    local err_raw
    err_raw="$(mktemp)"
    if ! run_cmd "$cmd" 2>"$err_raw" | redact_stream > "$outfile"; then
        echo "     ПРЕДУПРЕЖДЕНИЕ: не удалось выполнить ${label}"
        echo "ERROR: ${cmd}" >> "$outfile"
    fi
    # stderr пишем рядом, но только если он непустой — не плодим мусорные файлы.
    if [ -s "$err_raw" ]; then
        redact_stream < "$err_raw" > "$errfile"
    fi
    rm -f "$err_raw"
}

# === Заголовочный файл meta.txt ===
echo "  -> meta.txt..."
cat > "${SNAPSHOT_DIR}/meta.txt" <<METATXT
snapshot_date: ${DATE}
snapshot_time: $(date -u +%Y-%m-%dT%H:%M:%SZ)
server: ${SERVER}
host_dir: ${HOST_DIR}
inventory_dir: ${INVENTORY_DIR}
taken_by: $(whoami)
script_version: bundled-v2
redaction_applied: true
redaction_version: ${REDACTION_VERSION}
redaction_tool: ${REDACTION_TOOL}
METATXT

# === 17 контентных файлов снимка (16 + health-flags.txt) ===

# 1. Список контейнеров
run_remote "containers.txt" \
    "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"

# 2. Полный inspect всех контейнеров (env, mounts, networks) — С REDACTION.
#    Сырой docker inspect содержит env-переменные контейнеров открытым текстом
#    (API-ключи, токены ботов, пароли БД). Маскируем секреты ДО записи на диск.
#    jq-путь (structurally-aware) с fallback на построчный sed.
echo "  -> containers-inspect.json (redacted: ${REDACTION_TOOL})..."
INSPECT_RAW=$(run_cmd "docker ps -a -q | xargs docker inspect 2>/dev/null || echo '[]'" 2>/dev/null || echo '[]')
if [ "$REDACTION_TOOL" = "jq" ]; then
    # Пробуем jq; если он не распарсил (битый JSON) — падаем в построчный fallback.
    if ! printf '%s' "$INSPECT_RAW" | redact_json_with_jq > "${SNAPSHOT_DIR}/containers-inspect.json" 2>/dev/null \
       || [ ! -s "${SNAPSHOT_DIR}/containers-inspect.json" ]; then
        printf '%s' "$INSPECT_RAW" | redact_stream > "${SNAPSHOT_DIR}/containers-inspect.json"
    fi
else
    printf '%s' "$INSPECT_RAW" | redact_stream > "${SNAPSHOT_DIR}/containers-inspect.json"
fi

# 3. Список compose-файлов на сервере
run_remote "compose-files.txt" \
    "find /opt -name 'docker-compose.yml' -o -name 'docker-compose.yaml' 2>/dev/null | sort"

# 4. Docker-сети
run_remote "networks.txt" \
    "docker network ls && echo '---' && docker network ls -q | xargs docker network inspect --format '{{.Name}}: {{.IPAM.Config}}' 2>/dev/null"

# 5. Docker-тома
run_remote "volumes.txt" \
    "docker volume ls && echo '---' && docker system df -v 2>/dev/null"

# 6. Ресурсы хоста (uptime, память, диск, порты, обновления APT)
run_remote "host-resources.txt" \
    "echo '=== uptime ===' && uptime && echo '=== память ===' && free -h && echo '=== диск ===' && df -h && echo '=== открытые порты ===' && (ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null || echo 'ss/netstat не найден') && echo '=== доступные обновления APT ===' && (apt list --upgradable 2>/dev/null | head -50 || echo 'apt не найден')"

# 7. Cron-задачи. Фикс 2026-07-10: раньше «crontab root» снимался БЕЗ sudo и
#    показывал crontab SSH-пользователя (root-crontab с acme.sh выглядел пустым).
#    Теперь: root через sudo -n (нет sudo → честная пометка), плюс crontab
#    самого SSH-пользователя отдельной секцией.
run_remote "crontab.txt" \
    "echo '=== crontab root (sudo) ===' && (sudo -n crontab -l 2>/dev/null || echo 'нет данных: sudo -n недоступен или crontab пуст') && echo \"=== crontab \$(whoami) ===\" && (crontab -l 2>/dev/null || echo 'пусто') && echo '=== /etc/cron.d/ ===' && (ls -la /etc/cron.d/ 2>/dev/null || echo 'пусто') && (cat /etc/cron.d/* 2>/dev/null || echo 'пусто')"

# 8. Nginx-конфигурация
run_remote "nginx-sites.txt" \
    "nginx -T 2>/dev/null || (echo '--- sites-enabled ---' && ls -la /etc/nginx/sites-enabled/ 2>/dev/null && cat /etc/nginx/sites-enabled/* 2>/dev/null) || echo 'nginx не найден'"

# 9. TLS-сертификаты и их СРОКИ ВАЛИДНОСТИ через openssl — и letsencrypt, и acme.sh.
#    Фикс /retro 2026-06-14: раньше openssl бежал только по /etc/letsencrypt/live, а
#    для acme.sh была лишь `ls -la` (даты ФАЙЛОВ, не сертификатов) — на acme.sh-хостах
#    срок истечения не считался вообще, хотя description обещает «даты валидности».
#    Теперь openssl x509 -enddate прогоняется по обоим источникам. set +e — против
#    спецсимволов в путях (фикс v2).
#    Фикс 2026-07-10 (грабля Bronto): сертификаты могут жить где угодно
#    (например /etc/nginx/ssl/), а acme.sh — у root. Главный источник теперь —
#    фактические пути ssl_certificate из nginx -T (это то, чем сервер реально
#    отвечает); letsencrypt/acme.sh (включая /root/.acme.sh через sudo -n) —
#    дополнительные.
run_remote "tls-certs.txt" \
    "set +e
     echo '=== ssl_certificate из nginx -T (фактические) ==='
     (sudo -n nginx -T 2>/dev/null || nginx -T 2>/dev/null) | grep -E '^\s*ssl_certificate\s' | awk '{print \$2}' | tr -d ';' | sort -u | while read f; do
       echo \"--- \$f ---\"; (sudo -n openssl x509 -in \"\$f\" -noout -subject -enddate 2>/dev/null || openssl x509 -in \"\$f\" -noout -subject -enddate 2>/dev/null || echo 'нет чтения'); done
     echo '=== letsencrypt (/etc/letsencrypt/live) ==='
     find /etc/letsencrypt/live -name 'cert.pem' 2>/dev/null | while read f; do echo \"--- \$f ---\"; openssl x509 -in \"\$f\" -noout -subject -dates 2>/dev/null; done
     echo '=== acme.sh (~/.acme.sh и /root/.acme.sh) ==='
     for f in ~/.acme.sh/*/fullchain.cer; do [ -f \"\$f\" ] || continue; echo \"--- \$f ---\"; openssl x509 -in \"\$f\" -noout -subject -enddate 2>/dev/null; done
     sudo -n sh -c 'for f in /root/.acme.sh/*/fullchain.cer; do [ -f \"\$f\" ] || continue; echo \"--- \$f ---\"; openssl x509 -in \"\$f\" -noout -subject -enddate 2>/dev/null; done' 2>/dev/null
     true"

# 10. Список хостовых скриптов (метаданные, без содержимого)
#     set +e + true: пустые glob'ы (/opt/*.yml, /root/bin/) дают ls ненулевой
#     код, и под set -o pipefail вся секция ложно помечалась как failed
#     (граблекейс selectel: данные собирались, но в конец файла дописывался
#     'ERROR: ...'). Honest-status: секция падает только при реальной ошибке.
#     Фикс 2026-07-10 (грабля Bronto): скрипты IaC-раскладки живут глубже
#     (/opt/infra/scripts/**), верхнеуровневый glob их не видел. Теперь find
#     до 4 уровней с исключением тяжёлых каталогов приложений.
run_remote "host-scripts-list.txt" \
    "set +e
     echo '=== /opt (до 4 уровней, без node_modules/venv/.git) ==='
     find /opt -maxdepth 4 \\( -name node_modules -o -name venv -o -name .git -o -name .cache \\) -prune -o -type f \\( -name '*.sh' -o -name '*.py' \\) -print 2>/dev/null | head -100 | xargs -r ls -la 2>/dev/null
     echo '=== /usr/local/{bin,sbin} и /root/bin ==='
     ls -la /usr/local/bin/*.sh /usr/local/sbin/*.sh 2>/dev/null
     ls -la /root/bin/ 2>/dev/null
     true"

# 11. Содержимое хостовых скриптов в /opt (.sh)
# shellcheck disable=SC2016
# (single-quoted heredoc намеренный — переменные раскрываются на стороне сервера)
run_remote "host-scripts-content.txt" \
    'for f in /opt/*.sh; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  echo "--- metadata ---"
  stat -c "%a %U:%G %s bytes modified %y" "$f"
  echo "--- content ---"
  cat "$f"
  echo ""
done'

# 12. Структура .env файлов на хосте (имена переменных, значения redacted)
# shellcheck disable=SC2016
run_remote "host-env-redacted.txt" \
    'for f in /opt/*.env; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  echo "--- metadata ---"
  stat -c "%a %U:%G %s bytes modified %y" "$f"
  echo "--- variable names (values redacted) ---"
  # Маскируем значение после = целиком. Дополнительно ловим креды в URL
  # (postgres://user:pass@host), если значение само по себе не было скрыто
  # выше — на случай многострочных значений или нестандартного синтаксиса.
  sed -E \
    -e "s/=.*/=<HIDDEN>/" \
    -e "s#(([A-Za-z][A-Za-z0-9+.-]*)://[^:@/[:space:]]+:)[^@/[:space:]]+@#\1<REDACTED>@#g" "$f"
  echo ""
done'

# 13. Содержимое /etc/cron.d/ и периодических директорий
# shellcheck disable=SC2016
run_remote "cron-d-content.txt" \
    'for f in /etc/cron.d/* /etc/cron.daily/* /etc/cron.hourly/* /etc/cron.weekly/* /etc/cron.monthly/*; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  cat "$f"
  echo ""
done'

# 14. Включённые systemd-юниты (без штатных system-юнитов)
run_remote "systemd-enabled.txt" \
    "systemctl list-unit-files --type=service --state=enabled 2>/dev/null | grep -vE '^(UNIT|[0-9]+ unit|systemd-|sys-|snap\\.)' | head -50"

# 14b. Хост-сервисы вне Docker (фикс 2026-07-10, кейс newsforge: systemd-сервис
#      с User= и venv был невидимкой — ни docker ps, ни compose его не знают).
#      Собираем нештатные юниты из /etc/systemd/system: Description, User,
#      ExecStart, состояние. Это источник секции «Хост-сервисы» в services.md.
# shellcheck disable=SC2016
run_remote "host-services.txt" \
    'set +e
echo "=== нештатные *.service в /etc/systemd/system ==="
for f in /etc/systemd/system/*.service; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  case "$base" in systemd-*|snap.*|sys-*|dbus-*|getty*|cloud-*) continue;; esac
  echo "--- $base ---"
  grep -E "^(Description|User|ExecStart)=" "$f" | head -5
  echo "state: $(systemctl is-enabled "$base" 2>/dev/null) / $(systemctl is-active "$base" 2>/dev/null)"
  echo ""
done
true'

# 15. systemd-таймеры (расписание наравне с cron на Ubuntu 24.04) — таблица
#     активных таймеров + содержимое *.timer-юнитов оператора (без штатной
#     системной обвязки). set +e: на хостах без systemd / с урезанным systemctl
#     вызов не должен ронять снимок (граблекейс tls-certs).
run_remote "systemd-timers.txt" \
    "set +e
     echo '=== list-timers (активные) ==='
     systemctl list-timers --all --no-pager 2>/dev/null || echo 'нет данных (systemctl недоступен)'
     echo
     echo '=== *.timer-юниты оператора (без штатных system-) ==='
     timers=\$(systemctl list-unit-files --type=timer --no-pager 2>/dev/null \\
       | awk '{print \$1}' \\
       | grep -E '\\.timer\$' \\
       | grep -vE '^(systemd-|sys-|snap\\.|snapd\\.|apt-|man-db|logrotate|fstrim|e2scrub|fwupd|motd|dpkg|plocate|update-notifier|anacron|chrony-|chronyd|mdadm-|mdcheck|mdmonitor|ua-timer|ua_|ubuntu-advantage|raid-check|btrfs|smartd)' )
     if [ -z \"\$timers\" ]; then
       echo 'пусто (нет таймеров оператора)'
     else
       for t in \$timers; do
         echo \"--- \$t ---\"
         systemctl cat \"\$t\" 2>/dev/null || echo '(не удалось прочитать юнит)'
         echo
       done
     fi
     true"

# 16. Скрипты-наблюдатели (watchers) — долгоживущие процессы, слушающие события
#     файловой системы (inotify/fswatch/python-watchdog), в отличие от запуска
#     по расписанию.
#     ВАЖНО (граблекейс selectel): НЕ ловим hardware watchdog (watchdogd,
#     /usr/sbin/watchdog) — это демон слежения за зависанием ядра, а не
#     наблюдатель за файлами; иначе на карте появляется фантомная «автоматизация».
#     Паттерн сужен до настоящих file-watcher'ов; голый 'watchdog' исключён,
#     оставлен 'watchmedo' (CLI python-watchdog) и второй grep отсекает
#     hardware-демон по полному пути.
#     set +e: ps/grep на пустом наборе возвращают ненулевой код — это не ошибка.
run_remote "watchers.txt" \
    "set +e
     echo '=== процессы-наблюдатели (event-driven, file-watch) ==='
     out=\$(ps -eo comm,args 2>/dev/null \\
       | grep -E 'inotifywait|inotifywatch|fswatch|watchmedo' \\
       | grep -vE 'grep|/usr/sbin/watchdog|\\bwatchdogd\\b')
     if [ -z \"\$out\" ]; then
       echo 'пусто (file-watcher'\\''ов не найдено)'
     else
       echo \"\$out\"
     fi
     true"

# 17. Health-flags — готовая сводка здоровья хоста (находка /retro 2026-06-14:
#     агент не должен грепать swap/disk/exited вручную из сырья). Агрегируем
#     на сервере в один проход; Шаг 7 SKILL презентует это как есть.
run_remote "health-flags.txt" \
    "set +e
     free | awk '/Swap:/{t=\$2;u=\$3; if(t>0) print \"swap_used_pct=\" int(u*100/t); else print \"swap_used_pct=0 (swap off)\"}'
     df -P / | awk 'NR==2{print \"root_used_pct=\" \$5}'
     uptime | grep -oE 'load average.*' | sed 's/load average://; s/^/loadavg=/'
     echo \"exited_containers=\$(docker ps -aq --filter status=exited 2>/dev/null | wc -l | tr -d ' ')\"
     echo \"oom137_containers=\$(docker ps -a --filter exited=137 --format '{{.Names}}' 2>/dev/null | tr '\\n' ' ')\"
     echo \"apt_upgradable=\$(apt list --upgradable 2>/dev/null | grep -c upgradable)\"
     echo \"apt_security=\$(apt list --upgradable 2>/dev/null | grep -ci security)\"
     true"

# === Итог ===
FILE_COUNT=$(find "$SNAPSHOT_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')
echo ""
echo "======================================================"
echo "Снимок сохранён в ${SNAPSHOT_DIR}"
echo "Файлов: ${FILE_COUNT}"
echo "======================================================"