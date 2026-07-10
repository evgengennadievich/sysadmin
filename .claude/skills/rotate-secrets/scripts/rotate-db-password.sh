#!/usr/bin/env bash
# rotate-db-password.sh — параметризованная ротация пароля БД (PG/MySQL/Redis).
#
# Использование (значения после `--` — ПРИМЕР, замените своими):
#   bash rotate-db-password.sh \
#       --type postgres \
#       --server <user>@<your-server> \
#       --container postgres \
#       --role myapp \
#       --env-files /opt/myapp/.env,/opt/shared-db/.env \
#       --consumer-dirs /opt/myapp,/opt/myapi \
#       --var-name POSTGRES_PASSWORD \
#       --secret-name postgres-myapp
#
# Логика:
#   1. Сгенерировать новый пароль
#   2. ALTER USER в БД
#   3. Подменить во всех .env файлах
#   4. docker compose restart всех потребителей
#   5. Verify: новый пароль работает, старый — нет
#
# 🔒 БЕЗОПАСНОСТЬ (D2): пароль НИГДЕ не печатается и НЕ попадает в argv команд:
#   - на сервер уходит через stdin (SQL-текст / IFS= read в удалённом шелле),
#     поэтому не виден ни в `ps` (локально и на сервере), ни в истории шелла;
#   - verify использует PGPASSWORD/MYSQL_PWD из окружения удалённого шелла,
#     прочитанного со stdin, а не из командной строки;
#   - вывод всех удалённых команд проходит redact_stream (общая библиотека
#     _lib/redact.sh — та же, что в inventory-scan): даже если БД эхо-нет
#     statement с паролем в сообщении об ошибке, в сессию он попадёт по маской;
#   - на выходе пароль кладётся в локальный файл с правами 0600 — для переноса
#     в менеджер паролей; в stdout печатается только ПУТЬ к файлу.

set -euo pipefail

# Единая библиотека маскировки (канон redaction v2.1) — переиспользуем, не копируем.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDACT_LIB="$SCRIPT_DIR/../../_lib/redact.sh"
if [ -f "$REDACT_LIB" ]; then
    # shellcheck source=/dev/null
    source "$REDACT_LIB"
else
    echo "ERROR: библиотека маскировки не найдена: $REDACT_LIB" >&2
    echo "Ротация без маскировки вывода запрещена (секрет может утечь в сессию)." >&2
    exit 2
fi

TYPE=""
SERVER=""
CONTAINER=""
ROLE=""
ENV_FILES=""
CONSUMER_DIRS=""
VAR_NAME=""
SECRET_NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --type) TYPE="$2"; shift 2 ;;
        --server) SERVER="$2"; shift 2 ;;
        --container) CONTAINER="$2"; shift 2 ;;
        --role) ROLE="$2"; shift 2 ;;
        --env-files) ENV_FILES="$2"; shift 2 ;;
        --consumer-dirs) CONSUMER_DIRS="$2"; shift 2 ;;
        --var-name) VAR_NAME="$2"; shift 2 ;;
        --secret-name) SECRET_NAME="$2"; shift 2 ;;
        --old) echo "ОТКЛОНЕНО: --old передаёт старый пароль через argv (виден в ps/истории)." >&2
               echo "Проверка отмирания старого пароля делается вручную после ротации:" >&2
               echo "  прочитай старый пароль из менеджера паролей и проверь подключение." >&2
               exit 2 ;;
        *) echo "Неизвестный аргумент: $1"; exit 2 ;;
    esac
done

for required in TYPE SERVER CONTAINER ROLE ENV_FILES CONSUMER_DIRS VAR_NAME SECRET_NAME; do
    if [ -z "${!required}" ]; then
        echo "Отсутствует --${required,,}"
        exit 2
    fi
done

# 1. Сгенерировать новый пароль (живёт только в памяти процесса)
NEW=$(openssl rand -base64 32 | tr -d '+/=' | head -c 32)
echo "[1/5] Сгенерирован новый пароль (длина: ${#NEW}; значение не печатается)"

# 2. ALTER USER — SQL уходит через stdin, пароль не попадает в argv ни локально,
#    ни на сервере (docker exec -i ... читает statement со stdin).
echo "[2/5] ALTER USER на $SERVER ($CONTAINER)..."
case "$TYPE" in
    postgres)
        printf "ALTER USER %s WITH PASSWORD '%s';\n" "$ROLE" "$NEW" \
            | ssh "$SERVER" "docker exec -i $CONTAINER psql -U postgres" 2>&1 \
            | redact_stream
        ;;
    mysql)
        printf "ALTER USER '%s'@'%%' IDENTIFIED BY '%s'; FLUSH PRIVILEGES;\n" "$ROLE" "$NEW" \
            | ssh "$SERVER" "docker exec -i $CONTAINER mysql -u root" 2>&1 \
            | redact_stream
        ;;
    redis)
        printf 'CONFIG SET requirepass %s\n' "$NEW" \
            | ssh "$SERVER" "docker exec -i $CONTAINER redis-cli" 2>&1 \
            | redact_stream
        ;;
    *)
        echo "Неизвестный тип: $TYPE (ожидаю postgres|mysql|redis)"
        exit 2
        ;;
esac

# 3. Обновить все .env файлы. Пароль и параметры идут через stdin удалённого
#    шелла (3 строки: пароль, имя переменной, список файлов) — argv чист.
#    awk берёт пароль из ENVIRON, поэтому он не светится и в argv awk.
echo "[3/5] Подменяем $VAR_NAME во всех .env..."
ENV_FILES_SPACE="${ENV_FILES//,/ }"
printf '%s\n%s\n%s\n' "$NEW" "$VAR_NAME" "$ENV_FILES_SPACE" | ssh "$SERVER" '
    IFS= read -r NEW_VALUE
    IFS= read -r VAR_NAME
    IFS= read -r FILES
    export NEW_VALUE
    for f in $FILES; do
        cp "$f" "$f.bak"
        awk -v var="$VAR_NAME" '\''
            BEGIN { nv = ENVIRON["NEW_VALUE"] }
            $0 ~ "^" var "=" { print var "=" nv; next }
            { print }
        '\'' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        echo "  ok: $f"
    done
' 2>&1 | redact_stream

# 4. Restart всех потребителей
echo "[4/5] Restart потребителей..."
IFS=',' read -ra DIRS <<< "$CONSUMER_DIRS"
for dir in "${DIRS[@]}"; do
    ssh "$SERVER" "cd '$dir' && docker compose restart" 2>&1 | redact_stream
    echo "  ✓ $dir restarted"
done

# Подождать прогрева (особенно важно для PG)
sleep 5

# 5. Verify — пароль уходит через stdin, удалённый шелл кладёт его в env;
#    в argv ssh и psql/mysql пароля нет.
echo "[5/5] Verify..."
case "$TYPE" in
    postgres)
        if printf '%s\n' "$NEW" | ssh "$SERVER" '
            IFS= read -r PGPASSWORD; export PGPASSWORD
            psql -h 127.0.0.1 -U '"$ROLE"' -d '"$ROLE"' -c "SELECT 1" >/dev/null 2>&1
        '; then
            echo "  ✓ Новый пароль работает"
        else
            echo "  ✗ Новый пароль НЕ работает — RUSH ROLLBACK (.env.bak на месте)"
            exit 3
        fi
        echo "  Проверка, что СТАРЫЙ пароль умер (пароль введи скрыто, из менеджера):"
        echo "    printf '%s\\n' \"<старый>\" | ssh $SERVER 'IFS= read -r PGPASSWORD; export PGPASSWORD; psql -h 127.0.0.1 -U $ROLE -d $ROLE -c \"SELECT 1\"'"
        echo "  Ожидаемый результат: ошибка аутентификации."
        ;;
    *)
        echo "  (verify для $TYPE — подключись с новым паролем тем же stdin-паттерном)"
        ;;
esac

# 6. Передача пароля оператору — файл 0600, НЕ stdout.
SECRET_OUT="${TMPDIR:-/tmp}/rotate-${SECRET_NAME}-$(date +%Y%m%d-%H%M%S).secret"
( umask 077; printf '%s\n' "$NEW" > "$SECRET_OUT" )
unset NEW

echo ""
echo "=== Ротация завершена ==="
echo "Новый пароль записан в файл (права 0600): $SECRET_OUT"
echo ""
echo "Следующие шаги вручную:"
echo "  1. Перенеси пароль в менеджер паролей под ключом ${SECRET_NAME}, например:"
echo "       Keychain: security add-generic-password -U -a infra -s ${SECRET_NAME} -w"
echo "                 (без значения после -w — спросит пароль скрыто; вставь из файла)"
echo "       pass:     pass insert -m infra/db/${SECRET_NAME} < $SECRET_OUT"
echo "  2. Сразу удали файл: rm $SECRET_OUT"
echo "  3. Старую запись держи с пометкой -old 24 часа (для отката), потом удали"
echo "  4. Обнови inventory/shared/access.md (последняя ротация = сегодня)"
echo "  5. Создай incidents/$(date +%Y-%m-%d)-rotate-${SECRET_NAME}.md"
