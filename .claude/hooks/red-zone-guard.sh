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

# Вывод хука читает движок, а не терминал: печатаем UTF-8 независимо от кодовой страницы
# консоли. Без этого на Windows (cp1252) python падает на первом же не-ASCII символе, а
# сообщения здесь русские — хук не печатает НИЧЕГО и выходит с кодом 0, что движок читает
# как «разрешаю»: замок молча пропускает то, ради чего поставлен (поймано 26.08.2026,
# 16 случаев теста из 16). Разбор — building-enforcement.md, правило «немой замок».
export PYTHONIOENCODING=utf-8

RAW="$(cat)"

# ── Паттерны красной зоны (§6.3 CLAUDE.md) ────────────────────────────────────
# Расширенные regex, регистронезависимо. Ловим и обёртки вида ssh host "…".
RED_PATTERNS=(
  'rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*[fF]|-[a-zA-Z]*[fF][a-zA-Z]*[rR])'
  'drop[[:space:]]+(database|table|schema)'
  # Группа обязательна: без неё ловилась ЛЮБАЯ команда со словом truncate —
  # `truncate -s 0 /var/log/app.log` (штатная ротация) и даже `grep truncate`.
  'truncate[[:space:]]+(table|only)'
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
#
# Имя переменной пишем СТРОЧНЫМИ: сравнение идёт по команде, приведённой к нижнему
# регистру (LOWER ниже), поэтому шаблон `TMPDIR` заглавными не совпадал никогда —
# уборка агентом собственного временного каталога через `$TMPDIR` ложно уходила в
# красную зону и дёргала оператора ритуалом (ADR-0038 говорит обратное).
#
# Windows-ветка: временный каталог агента там — `…/AppData/Local/Temp/…`, а не /tmp,
# поэтому на Windows исключение не срабатывало вовсе. Ловим обе формы записи пути:
# нативную `C:\Users\…` и msys-форму `/c/users/…`.
#
# Ограничитель прежний и главный — PROD_PATH_RE ниже: упомянут боевой каталог в том же
# сегменте, и исключение не действует, каким бы временным путём команда ни начиналась.
#
# Знак $ перед именем переменной ОБЯЗАТЕЛЕН. С необязательным `\$?` шаблон разрешал и
# голое слово: `rm -rf temp` в текущем каталоге — то есть чей угодно рабочий каталог
# с таким именем — проходил как «уборка временного». Найдено пробой 19.08.2026.
SAFE_RM_RE='rm[[:space:]]+-[a-zA-Z]+[[:space:]]+("?(/private)?/(tmp|var/tmp)/|"?\$\{?(tmpdir|temp|tmp)\b|"?([a-z]:|/[a-z])[\\/]+users[\\/]+[^\\/[:space:]]+[\\/]+appdata[\\/]+local[\\/]+temp)'
# Выход вверх по дереву (`..`) отменяет исключение целиком: путь начинается во временном
# каталоге, а заканчивается где угодно. Снос домашнего каталога через `/tmp/../Users/...`
# замок пропускал ещё ДО PR #11 — дыра жила в ветке /tmp с самого начала и вскрылась
# только на пробе противоположными случаями 19.08.2026. Список боевых каталогов её не
# закрывает: домашние каталоги, рабочие папки и диск Windows в него не входят.
TRAVERSAL_RE='(^|[[:space:]"/\\])\.\.([/\\]|$)'
# Боевые каталоги: встретился в ТОМ ЖЕ сегменте — исключение не действует
# (кейс `rm -rf /tmp/x /opt/prod`). Проверяется посегментно, см. цикл ниже.
#
# Начало пути обязано быть настоящим началом: перед ним не буква, не цифра, не дефис и не
# подчёркивание. Без этой границы `/tmp/data-dump` читался как боевой `/data`, а `/tmp/../opt`
# — наоборот, проскакивал бы, если бы границу задали только пробелом и кавычкой.
PROD_PATH_RE='(^|[^a-zA-Z0-9_-])(/opt|/etc|/var/lib|/var/www|/home|/root|/srv|/data|/usr)'

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
# Команда разбирается ПО СЕГМЕНТАМ (`;` `&&` `||` `|` перевод строки), и сегменты,
# начинающиеся с read-only утилиты, пропускаются целиком: их аргументы — данные, а не
# команды. Без этого `grep -rn "rm -rf" scripts/` и `grep truncate nginx.conf` блокировались
# как красная зона — три холостых срабатывания за день (разбор сессии 2026-07-24, F4/F4+).
#
# ВАЖНО: пропускаем ТОЛЬКО read-only лидеров. Сегмент `ssh host "rm -rf /opt"` начинается с
# ssh — не read-only, поэтому опасное содержимое кавычек по-прежнему ловится (это главный
# способ, которым агент трогает сервер).
READONLY_LEAD='^(grep|egrep|fgrep|rg|ag|echo|printf|cat|bat|less|more|head|tail|wc|jq|yq|sort|uniq|column|diff|comm|man|which|type|file|stat|basename|dirname)([[:space:]]|$)'
# Git-подкоманды, чьи аргументы — текст, а не операция: сообщение коммита или тега
# запросто содержит «rm -rf» как цитату (поймало на четвёртом холостом срабатывании
# в самой сессии разбора). Опасные подкоманды сюда НЕ входят: `git push --force`,
# `git reset --hard` остаются в RED_PATTERNS. Цепочка проверяется посегментно, поэтому
# `git commit -m "…" && rm -rf /opt` всё равно блокируется вторым сегментом.
SAFE_GIT_LEAD='^git[[:space:]]+(commit|add|status|log|show|diff|tag|fetch|remote|branch|stash[[:space:]]+list|config)([[:space:]]|$)'

LOWER="$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')"
HIT=""
while IFS= read -r seg; do
    # Срезаем префиксы, не меняющие сути сегмента: пробелы, sudo, env-присваивания.
    probe="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*//; s/^sudo[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*//; s/^([a-z_][a-z0-9_]*=[^[:space:]]*[[:space:]]+)+//')"
    [ -z "$probe" ] && continue
    printf '%s' "$probe" | grep -Eq "$READONLY_LEAD" && continue   # чтение — не красная зона
    printf '%s' "$probe" | grep -Eq "$SAFE_GIT_LEAD" && continue   # git-текст, не операция
    for re in "${RED_PATTERNS[@]}"; do
        if printf '%s' "$probe" | grep -Eq "$re"; then
            # Исключение «уборка временного» действует В ГРАНИЦАХ ЭТОГО СЕГМЕНТА, не всей
            # строки. Раньше оно проверялось глобально и стоило двух ошибок сразу:
            #   ложный блок — `ls /opt/apps; rm -rf /tmp/x` рвался из-за чтения по соседству;
            #   ложный пропуск — `rm -rf /tmp/x && docker volume rm pgdata` проходил ЦЕЛИКОМ,
            #   потому что первый же сегмент объявлял безопасной всю команду.
            # Прощается только сам сегмент; остальные проверяются дальше как обычно.
            if printf '%s' "$probe" | grep -Eq "$SAFE_RM_RE" \
               && ! printf '%s' "$probe" | grep -Eq "$TRAVERSAL_RE" \
               && ! printf '%s' "$probe" | grep -Eq "$PROD_PATH_RE"; then
                continue 2
            fi
            HIT="$re"; break 2
        fi
    done
done <<EOF
$(printf '%s' "$LOWER" | sed -E 's/(\|\||&&|;|\||\n)/\n/g')
EOF

[ -z "$HIT" ] && exit 0

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
  # Codex (ADR-0042): записи лежат в $CODEX_HOME/sessions/ГГГГ/ММ/ДД/rollout-*<id>.jsonl.
  if [ ! -f "$TRANSCRIPT" ] && command -v python3 >/dev/null 2>&1; then
    CX="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import codex_transcript as c; print(c.find_transcript(sys.argv[2]))' \
          "$(cd "$(dirname "$0")" && pwd)" "${SESSION_ID:-}" 2>/dev/null)" || CX=""
    [ -n "$CX" ] && TRANSCRIPT="$CX"
  fi
fi

if [ -f "$TRANSCRIPT" ] && command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$RAW" | python3 -I "$(dirname "$0")/red-zone-approval.py" "$TRANSCRIPT"; then
    exit 0
  fi
fi

deny "🔴 КРАСНАЯ ЗОНА. Требуется отдельное подтверждение этой команды (§6.3, ADR-0043).
Покажи оператору цель, последствия, сведения о копии, точную команду и рабочий каталог.
Оператор сам заполняет две строки одним сообщением:

подтверждаю <точная команда>, беру риск на себя, бэкап проверен
каталог <абсолютный путь>

Согласие действует один раз. Более поздняя реплика оператора отменяет его."
