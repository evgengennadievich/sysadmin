#!/usr/bin/env bash
# host-digest.sh — приносит дайджест состояния инфры для живой подстановки в скилл.
#
# ЗАЧЕМ. Скилл диагностики может приходить уже со снимком состояния внутри вместо
# инструкции «сначала посмотри» (ADR-0029). Но команда в подстановке идёт МИМО слоя
# разрешений: ни промпта, ни зоны доверия, ни PreToolUse-хука. Поэтому серверный
# снимок берётся не произвольной командой, а ровно одной — той, что оператор сам
# объявил в своей карте инфры полем `state.digest_cmd` (ADR-0013). Хардкода адреса,
# пути и имени сервера здесь нет и быть не может (C.4).
#
# ГРАНИЦЫ. Скрипт только читает. Он не решает, что запускать, — решает конфиг
# оператора. Если поля нет, он честно печатает «НЕ СОБРАНО» и не импровизирует (C.9).
#
# ВЫХОД ВСЕГДА 0. Ненулевой код в подстановке молча убивает весь ответ агента —
# ни ошибки, ни предупреждения, пустой вывод (ожог 2026-07-27, ADR-0029, правило 16
# линтера переносимости). Поэтому любая неудача здесь превращается в текст, а не в код.
#
# Использование:
#   bash .claude/skills/_lib/host-digest.sh [--lines N] [--timeout SEC] [--config ПУТЬ]
#
# В теле скилла (обязательно со страховкой на конце):
#   !`bash "$(git rev-parse --show-toplevel)/.claude/skills/_lib/host-digest.sh" || true`

set -u

LINES=60
TMO=8
CONFIG_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --lines)   LINES="${2:-60}"; shift 2 ;;
        --timeout) TMO="${2:-8}";    shift 2 ;;
        --config)  CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) shift ;;
    esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT="$(pwd)"

# Печатает причину, по которой снимка нет, и как получить то же руками.
# Гадать по отсутствующему снимку агенту запрещено — он обязан увидеть слово НЕ СОБРАНО.
not_collected() {
    printf 'НЕ СОБРАНО: %s\n' "$1"
    printf 'Как получить вручную: %s\n' "${2:-открой карту инфры и выполни state.digest_cmd сам}"
    exit 0
}

# ─── 1. Находим карту инфры активного проекта ────────────────────────────────
if [ -n "$CONFIG_OVERRIDE" ]; then
    INFRA_CONFIG="$CONFIG_OVERRIDE"
else
    AGENT_CONFIG="$ROOT/agent-config.json"
    [ -f "$AGENT_CONFIG" ] || not_collected \
        "мозг агента не настроен (нет $AGENT_CONFIG)" "запусти /sysadmin-init"

    command -v python3 >/dev/null 2>&1 || not_collected \
        "на машине нет python3 — разобрать конфиг нечем" \
        "прочитай state.digest_cmd из карты инфры глазами и выполни сам"

    INFRA_CONFIG="$(python3 - "$AGENT_CONFIG" <<'PY' 2>/dev/null
import json, os, sys
try:
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
projects = cfg.get("projects") or []
# Активный проект: помеченный active, иначе единственный. Двусмысленность — не угадываем.
active = [p for p in projects if p.get("active")] or (projects if len(projects) == 1 else [])
if len(active) != 1:
    sys.exit(0)
root = (active[0].get("infra_root") or "").strip()
if not root:
    sys.exit(0)
# Относительный путь резолвится от каталога конфига — канон ADR-0008.
if not os.path.isabs(root):
    root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), root))
print(os.path.join(root, "infra-config.json"))
PY
)"
    [ -n "$INFRA_CONFIG" ] || not_collected \
        "в мозге не найден один активный проект с infra_root" "запусти /sysadmin-init --reconfigure"
fi

[ -f "$INFRA_CONFIG" ] || not_collected \
    "карта инфры не найдена ($INFRA_CONFIG)" "запусти /sysadmin-init"

# ─── 2. Берём команду дайджеста из паспорта состояния ────────────────────────
DIGEST_CMD="$(python3 - "$INFRA_CONFIG" <<'PY' 2>/dev/null
import json, sys
try:
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
print(((cfg.get("state") or {}).get("digest_cmd") or "").strip())
PY
)"

[ -n "$DIGEST_CMD" ] || not_collected \
    "в карте инфры не объявлено state.digest_cmd" \
    "объяви его через /sysadmin-init --reconfigure либо собери состояние скиллом /inventory-scan"

# ─── 3. Выполняем — с ограничением по времени ────────────────────────────────
# Сторож нужен, потому что подстановка исполняется ДО того, как агент начнёт ход:
# зависший ssh к недоступному серверу заморозил бы загрузку скилла целиком.
# Утилиты `timeout` на macOS нет (проверено), поэтому сторож свой.
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE" 2>/dev/null' EXIT

eval "$DIGEST_CMD" >"$OUT_FILE" 2>&1 &
CMD_PID=$!
( sleep "$TMO"; kill -TERM "$CMD_PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCH_PID=$!
wait "$CMD_PID" 2>/dev/null
RC=$?
kill "$WATCH_PID" 2>/dev/null
wait "$WATCH_PID" 2>/dev/null

FETCHED="$(date '+%Y-%m-%d %H:%M')"

# Ненулевой код = дайджеста нет, ЧТО БЫ ни лежало в выводе. Тест поймал ровно этот
# случай: несуществующая команда пишет «command not found» в тот же поток, вывод
# оказывается непустым — и сообщение об ошибке уезжает агенту под видом снимка
# состояния. Ошибка, выданная за данные, хуже отсутствия данных (C.2).
if [ "$RC" -ne 0 ]; then
    printf 'НЕ СОБРАНО: команда дайджеста вернула код %s (лимит %sс)\n' "$RC" "$TMO"
    printf 'Команда: %s\n' "$DIGEST_CMD"
    if [ -s "$OUT_FILE" ]; then
        printf 'Что она сказала (это НЕ дайджест, а диагностика):\n'
        head -n 5 < "$OUT_FILE"
    fi
    printf 'Как получить вручную: выполни команду сам и посмотри на ошибку\n'
    exit 0
fi

# ─── 4. Маскировка секретов и печать ─────────────────────────────────────────
# Вывод инструмента — такой же носитель, как файл: транскрипт переживает сессию (§6.1).
if [ -f "$ROOT/.claude/skills/_lib/redact.sh" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/.claude/skills/_lib/redact.sh"
fi

printf 'ДАЙДЖЕСТ СОСТОЯНИЯ ИНФРЫ — снят %s, командой из карты инфры\n' "$FETCHED"
printf 'Снимок сделан ОДИН раз при загрузке скилла и дальше не обновляется.\n'
printf 'Дайджест собирается на сервере по расписанию — его собственная дата ниже,\n'
printf 'и она может отставать. Дата сборки важнее даты съёмки (§4.6).\n'
printf -- '---\n'

if command -v redact_stream >/dev/null 2>&1; then
    redact_stream < "$OUT_FILE" | head -n "$LINES"
else
    head -n "$LINES" < "$OUT_FILE"
fi

TOTAL="$(wc -l < "$OUT_FILE" | tr -d ' ')"
if [ "$TOTAL" -gt "$LINES" ]; then
    printf -- '--- показано %s строк из %s; остальное — точечно из полного снимка ---\n' "$LINES" "$TOTAL"
fi

exit 0
