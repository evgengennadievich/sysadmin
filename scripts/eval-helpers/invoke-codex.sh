#!/usr/bin/env bash
# invoke-codex.sh — один вызов `codex exec` для определения подходящего скилла (ADR-0004, ADR-0042).
#
# Аналог invoke-claude.sh для Codex. Тот же вывод (stdout, одна строка):
#   <skill-name>|<cost-usd>|<duration-ms>
# Стоимость у Codex в долларах не отдаётся (подписка, лимиты по окнам), поэтому cost = 0;
# расход смотреть `bash scripts/token-usage.sh codex`.
#
# Запуск из корня sysadmin/. Сессия эфемерная, только чтение, без запросов
# расширения разрешений. Модель классифицирует текст без вызова инструментов.

set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 \"<phrase>\"" >&2; exit 2; }
phrase="$1"

command -v codex >/dev/null 2>&1 || { echo "error: codex CLI not in PATH" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILLS_DIR="$REPO_ROOT/.agents/skills"
declare -a _skill_names=()
for _d in "$SKILLS_DIR"/*/; do
    [[ -f "${_d}SKILL.md" ]] || continue
    _skill_names+=("$(basename "$_d")")
done
[[ ${#_skill_names[@]} -gt 0 ]] || { echo "error: нет SKILL.md в $SKILLS_DIR" >&2; exit 1; }
IFS=$'\n' _skill_names=($(printf '%s\n' "${_skill_names[@]}" | sort)); unset IFS
skill_list="$(printf '%s, ' "${_skill_names[@]}")"
skill_list="${skill_list%, }"

prompt="Ты диспетчер скиллов агента-сисадмина. Доступные скиллы (выбирай ТОЛЬКО из этого закрытого списка, имя копируй дословно): ${skill_list}. Фраза оператора: «${phrase}». Выбери ровно один скилл, который должен быть активирован; если ни один не подходит, ответь SKILL: none. Ничего не выполняй, инструменты не вызывай, не объясняй. Ответ строго одной строкой: SKILL: <имя> (или SKILL: none). Без Markdown."

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
start=$(python3 -c 'import time; print(int(time.time()*1000))')
codex -a never exec --ephemeral -s read-only \
    -C "$REPO_ROOT" -o "$OUT" "$prompt" </dev/null >/dev/null 2>&1 || {
    echo "error: codex exec failed for phrase: $phrase" >&2; exit 1; }
end=$(python3 -c 'import time; print(int(time.time()*1000))')

answer="$(cat "$OUT")"
if [[ ! "$answer" =~ ^SKILL:[[:blank:]]*([a-zA-Z0-9_-]+)$ ]]; then
    echo "error: codex did not return exactly one SKILL line" >&2
    exit 1
fi
skill="${BASH_REMATCH[1]}"
if [[ "$skill" != "none" && ! -f "$SKILLS_DIR/$skill/SKILL.md" ]]; then
    echo "error: codex returned an unknown skill" >&2
    exit 1
fi
echo "$skill|0|$((end - start))"
