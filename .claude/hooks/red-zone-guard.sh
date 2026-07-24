#!/usr/bin/env bash
# .claude/hooks/red-zone-guard.sh — PreToolUse-хук: замок красной зоны (ADR-0022).
#
# ЗАЧЕМ. Конституция §6.3/C.3 требует type-to-confirm перед необратимой операцией.
# До этого хука правило держалось ТОЛЬКО на добросовестности агента: проза в CLAUDE.md —
# табличка «не входить», а не замок. Хук превращает её в принуждение: команда красной
# зоны не выполнится, пока ОПЕРАТОР не написал фразу подтверждения своими руками.
#
# ПОЧЕМУ ЭТО НЕЛЬЗЯ ОБОЙТИ АГЕНТУ. Подтверждение ищется в сообщениях роли `user`
# реального транскрипта сессии. Агент пишет только сообщения роли `assistant` —
# сочинить себе разрешение он физически не может.
#
# ПОВЕДЕНИЕ:
#   команда не из красной зоны        → тихо пропускаем (exit 0)
#   красная зона + фраза оператора    → пропускаем
#   красная зона без фразы            → deny + инструкция, что написать
#   не смогли проверить транскрипт    → deny (fail-closed: молчаливый пропуск опаснее)
#
# Настраивается в .claude/settings.json (event PreToolUse, matcher Bash).
# Ручная проверка: bash .claude/hooks/tests/test-red-zone-guard.sh

set -uo pipefail

RAW="$(cat)"

# ── Фраза подтверждения (канон C.3) ───────────────────────────────────────────
# Ищем скелет: «беру риск на себя» + «бэкап проверен» (е/ё и регистр — свободно).
# Полная форма: «подтверждаю <операция>, беру риск на себя, бэкап проверен».
CONFIRM_RE='беру риск на себя'
CONFIRM_RE2='б[эеёЭЕЁ]кап проверен'
# Окно свежести: подтверждение действительно N последних реплик оператора,
# иначе одна фраза открывала бы дверь до конца сессии.
CONFIRM_WINDOW=10

# ── Паттерны красной зоны (§6.3 CLAUDE.md) ────────────────────────────────────
# Расширенные regex, регистронезависимо. Ловим и обёртки вида ssh host "…".
RED_PATTERNS=(
  'rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*[fF]|-[a-zA-Z]*[fF][a-zA-Z]*[rR])'
  'drop[[:space:]]+(database|table|schema)'
  'truncate[[:space:]]+(table|only)?'
  'docker[[:space:]]+volume[[:space:]]+(rm|prune)'
  'docker[[:space:]]+system[[:space:]]+prune'
  'git[[:space:]]+push[[:space:]].*(--force|-f[[:space:]]|-f$)'
  'git[[:space:]]+reset[[:space:]]+--hard'
  '(userdel|deluser)[[:space:]]'
  'ufw[[:space:]]+(reset|disable)'
  'mkfs(\.[a-z0-9]+)?[[:space:]]'
  'dd[[:space:]]+.*of=/dev/'
  '>[[:space:]]*/etc/ssh/sshd_config'
  'sed[[:space:]]+-i.*sshd_config'
)

# Исключения: временные каталоги — снос там обратим по смыслу и не трогает прод.
SAFE_RM_RE='rm[[:space:]]+-[a-zA-Z]+[[:space:]]+("?(/private)?/(tmp|var/tmp)/|"?\$?\{?TMPDIR)'
# Боевые каталоги: встретился ЛЮБОЙ — исключение не действует (кейс `rm -rf /tmp/x /opt/prod`).
PROD_PATH_RE='(/opt|/etc|/var/lib|/var/www|/home|/root|/srv|/data|/usr)'

# ── Извлечение команды из stdin ───────────────────────────────────────────────
# python3 → jq → грубый фолбэк по сырому тексту (Windows без jq — реальный кейс).
json_get() { # $1 = путь вида tool_input.command
  local path="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$RAW" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
cur = d
for k in sys.argv[1].split("."):
    if not isinstance(cur, dict) or k not in cur:
        sys.exit(1)
    cur = cur[k]
print(cur if isinstance(cur, str) else json.dumps(cur))
' "$path" 2>/dev/null && return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$RAW" | jq -er ".${path} // empty" 2>/dev/null && return 0
  fi
  return 1
}

deny() { # $1 = причина для агента и оператора
  local reason="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys, json
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": sys.argv[1],
  }
}, ensure_ascii=False))
' "$reason"
  else
    # Без python3 — экранируем минимально (кавычки и переводы строк).
    local esc
    esc="$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}1')"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
  fi
  exit 0
}

CMD="$(json_get tool_input.command || true)"
if [ -z "${CMD:-}" ]; then
  # Команду прочитать не удалось — ищем опасные паттерны прямо в сыром stdin.
  # Ложное срабатывание безопаснее пропуска необратимой операции.
  CMD="$RAW"
fi

# ── Красная зона? ─────────────────────────────────────────────────────────────
LOWER="$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')"
HIT=""
for re in "${RED_PATTERNS[@]}"; do
  if printf '%s' "$LOWER" | grep -Eq "$re"; then HIT="$re"; break; fi
done
[ -z "$HIT" ] && exit 0

# rm -rf строго во временных каталогах — не красная зона.
# Условие строгое: команда начинается с rm по временному пути И нигде в ней не упомянут
# боевой каталог (иначе `rm -rf /tmp/x /opt/prod` проскочил бы по первому аргументу).
if printf '%s' "$LOWER" | grep -Eq "$SAFE_RM_RE" && ! printf '%s' "$LOWER" | grep -Eq "$PROD_PATH_RE"; then
  exit 0
fi

# ── Ищем подтверждение оператора в транскрипте сессии ─────────────────────────
SESSION_ID="$(json_get session_id || true)"
CWD="$(json_get cwd || true)"
[ -z "${CWD:-}" ] && CWD="$PWD"

TRANSCRIPT="$(json_get transcript_path || true)"
if [ -z "${TRANSCRIPT:-}" ] || [ ! -f "${TRANSCRIPT:-}" ]; then
  # Собираем путь сами: ~/.claude/projects/<slug>/<session>.jsonl,
  # slug = cwd с заменой не-буквенно-цифровых символов на «-» (канон Claude Code).
  SLUG="$(printf '%s' "$CWD" | sed 's/[^a-zA-Z0-9]/-/g')"
  TRANSCRIPT="$HOME/.claude/projects/$SLUG/${SESSION_ID:-}.jsonl"
fi

DENY_MSG="🔴 КРАСНАЯ ЗОНА — операция заблокирована замком (ADR-0022, конституция C.3).

Команда: ${CMD}

Необратимая операция выполняется только после явного подтверждения оператора.
Агент: пройди процедуру §6.3 (ASSESS → PROPOSE с «⚠️ ЧТО ТЕРЯЕМ» и «⚠️ КОПИЯ» →
EXECUTE → VERIFY) и попроси оператора написать СВОИМИ РУКАМИ:

подтверждаю <что именно делаем>, беру риск на себя, бэкап проверен

Пока этой фразы нет в сообщениях оператора — команда не выполнится.
Обойти нельзя: фраза ищется в репликах оператора, агент их не пишет."

if [ ! -f "$TRANSCRIPT" ]; then
  deny "$DENY_MSG

(Транскрипт сессии не найден: $TRANSCRIPT — подтверждение проверить нечем, поэтому блокирую.)"
fi

# Достаём последние CONFIRM_WINDOW реплик оператора и ищем в них фразу.
FOUND=""
if command -v python3 >/dev/null 2>&1; then
  FOUND="$(python3 -c '
import sys, json, re
path, window, re1, re2 = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
msgs = []
try:
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") != "user":
                continue
            # Отсекаем ВСЁ, что лишь выглядит репликой оператора (иначе фраза
            # подтверждения, лежащая в файле/скилле/выводе команды, открыла бы замок —
            # prompt injection, конституция C.11). Проверено на реальном транскрипте:
            #   isMeta:true        — вставки движка (тексты скиллов, caveat-блоки)
            #   sourceToolUseID    — контент, порождённый вызовом инструмента
            #   isSidechain:true   — реплики внутри субагента, не оператор
            if rec.get("isMeta") or rec.get("sourceToolUseID") or rec.get("isSidechain"):
                continue
            m = rec.get("message") or {}
            if m.get("role") != "user":
                continue
            c = m.get("content")
            if isinstance(c, list):
                # Реплика оператора — только текстовые блоки; tool_result сюда не считаем,
                # иначе вывод команды мог бы «подтвердить» сам себя.
                if any(b.get("type") == "tool_result" for b in c if isinstance(b, dict)):
                    continue
                c = " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
            if not isinstance(c, str) or not c.strip():
                continue
            # Служебные обёртки слэш-команд и их вывод — тоже не голос оператора.
            if c.lstrip().startswith(("<command-name>", "<local-command-", "<command-message>",
                                      "<system-reminder>", "Base directory for this skill")):
                continue
            msgs.append(c)
except Exception:
    sys.exit(2)
for text in msgs[-window:]:
    low = text.lower()
    if re.search(re1, low) and re.search(re2, low):
        print("yes")
        break
' "$TRANSCRIPT" "$CONFIRM_WINDOW" "$CONFIRM_RE" "$CONFIRM_RE2" 2>/dev/null)" || FOUND=""
else
  # Без python3 — грубее: хвост файла, отбросив вставки движка и вывод инструментов.
  TAIL="$(grep '"role":"user"' "$TRANSCRIPT" 2>/dev/null \
          | grep -v '"tool_result"' | grep -v '"isMeta":true' \
          | grep -v '"sourceToolUseID"' | grep -v '"isSidechain":true' \
          | tail -n "$CONFIRM_WINDOW")"
  if printf '%s' "$TAIL" | grep -iq "$CONFIRM_RE" && printf '%s' "$TAIL" | grep -iq "$CONFIRM_RE2"; then
    FOUND="yes"
  fi
fi

[ "$FOUND" = "yes" ] && exit 0
deny "$DENY_MSG"
