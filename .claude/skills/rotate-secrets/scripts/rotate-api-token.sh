#!/usr/bin/env bash
# rotate-api-token.sh — общий шаблон ротации API token.
#
# Поскольку каждый провайдер выдаёт токены через свой UI/API, скрипт автоматизирует
# только серверную часть (подмена в .env + restart + verify). Создание нового
# токена и отзыв старого — оператор делает в провайдерской панели вручную.
#
# Использование:
#   bash rotate-api-token.sh \
#       --server <user>@<your-server> \
#       --env-file /opt/<service>/.env \
#       --var-name TELEGRAM_BOT_TOKEN \
#       --consumer-dir /opt/<service> \
#       --verify-cmd 'printf "url = \"https://api.telegram.org/bot%s/getMe\"\n" "$TOKEN" | curl -sS --config - | jq -e .ok'
#
# 🔒 БЕЗОПАСНОСТЬ (D2): токен НЕ передаётся аргументом командной строки.
#   - Скрипт запрашивает его скрытым вводом (read -rs) — токен не попадает
#     ни в argv (ps), ни в историю шелла. Альтернатива для автоматизации:
#     --new-token-file <путь> (файл с правами 0600, после — удалить).
#   - На сервер токен уходит через stdin удалённого шелла, argv чист.
#   - verify-cmd получает токен в env-переменной TOKEN; рекомендованный паттерн
#     для curl — URL через `--config -` (stdin), чтобы токен не светился
#     в argv локального curl (см. пример выше).
#   - Вывод удалённых команд проходит redact_stream (_lib/redact.sh).

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

SERVER=""
ENV_FILE=""
VAR_NAME=""
NEW=""
NEW_TOKEN_FILE=""
CONSUMER_DIR=""
VERIFY_CMD=""

while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER="$2"; shift 2 ;;
        --env-file) ENV_FILE="$2"; shift 2 ;;
        --var-name) VAR_NAME="$2"; shift 2 ;;
        --new-token) echo "ОТКЛОНЕНО: --new-token светит токен в ps и истории шелла." >&2
                     echo "Запусти без этого флага (скрытый ввод) или используй --new-token-file." >&2
                     exit 2 ;;
        --new-token-file) NEW_TOKEN_FILE="$2"; shift 2 ;;
        --consumer-dir) CONSUMER_DIR="$2"; shift 2 ;;
        --verify-cmd) VERIFY_CMD="$2"; shift 2 ;;
        *) echo "Неизвестный аргумент: $1"; exit 2 ;;
    esac
done

for required in SERVER ENV_FILE VAR_NAME CONSUMER_DIR; do
    if [ -z "${!required}" ]; then
        echo "Отсутствует --${required,,}"
        exit 2
    fi
done

# Получение токена: файл (0600) или скрытый интерактивный ввод.
if [ -n "$NEW_TOKEN_FILE" ]; then
    if [ ! -f "$NEW_TOKEN_FILE" ]; then
        echo "Файл с токеном не найден: $NEW_TOKEN_FILE"
        exit 2
    fi
    NEW="$(head -n1 "$NEW_TOKEN_FILE")"
else
    printf 'Вставь новый токен (ввод скрыт): '
    read -rs NEW
    echo ""
fi
if [ -z "$NEW" ]; then
    echo "Токен пуст — отмена."
    exit 2
fi

echo "=== Ротация API token: $VAR_NAME ==="

# 1. Подмена в .env (с .bak страховкой). Токен и параметры — через stdin
#    удалённого шелла; awk берёт значение из ENVIRON. Argv чист с обеих сторон.
echo "[1/3] Подменяем в $ENV_FILE..."
printf '%s\n%s\n%s\n' "$NEW" "$VAR_NAME" "$ENV_FILE" | ssh "$SERVER" '
    IFS= read -r NEW_VALUE
    IFS= read -r VAR_NAME
    IFS= read -r ENV_FILE
    export NEW_VALUE
    cp "$ENV_FILE" "$ENV_FILE.bak"
    awk -v var="$VAR_NAME" '\''
        BEGIN { nv = ENVIRON["NEW_VALUE"] }
        $0 ~ "^" var "=" { print var "=" nv; next }
        { print }
    '\'' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
    echo "  ok: $ENV_FILE"
' 2>&1 | redact_stream

# 2. Restart сервиса
echo "[2/3] Restart $CONSUMER_DIR..."
ssh "$SERVER" "cd '$CONSUMER_DIR' && docker compose restart" 2>&1 | redact_stream
sleep 3

# 3. Verify. Токен передаётся verify-команде через ENV (не интерполируется в
#    строку!): в ps видна литеральная строка с "$TOKEN", а не значение.
if [ -n "$VERIFY_CMD" ]; then
    echo "[3/3] Verify через test API call..."
    if TOKEN="$NEW" bash -c "$VERIFY_CMD"; then
        echo "  ✓ Новый токен работает"
    else
        echo "  ✗ Verify FAILED — откати на старый из ${ENV_FILE}.bak"
        exit 3
    fi
else
    echo "[3/3] Verify пропущен (--verify-cmd не задан)"
    echo "  Проверь вручную, что сервис работает: docker logs --tail 20"
fi

unset NEW

echo ""
echo "=== Готово ==="
echo "Следующие шаги вручную:"
echo "  1. Revoke старого токена в провайдерской панели"
echo "  2. Обнови inventory/shared/access.md"
if [ -n "$NEW_TOKEN_FILE" ]; then
    echo "  3. Удали файл с токеном: rm $NEW_TOKEN_FILE"
    echo "  4. Создай incidents/$(date +%Y-%m-%d)-rotate-${VAR_NAME}.md"
else
    echo "  3. Создай incidents/$(date +%Y-%m-%d)-rotate-${VAR_NAME}.md"
fi
