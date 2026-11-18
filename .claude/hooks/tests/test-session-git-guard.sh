#!/usr/bin/env bash
# Тесты замка общей рабочей копии (ADR-0041). Прогон: bash .claude/hooks/tests/test-session-git-guard.sh
#
# Две «сессии» (А и Б) работают в ОДНОЙ рабочей копии, как сессии агента в папке infra.
# Воспроизводятся три ожога: push уносит чужие коммиты (09.11.2026), коммит забирает чужой
# индекс (27.10.2026), коммит забирает чужие строки общего файла (03.09.2026). Хук получает
# тот же stdin, что даёт Claude Code; каждая команда проходит PreToolUse и выполняется
# с полученным updatedInput, а её вызов пишется в транскрипт, как это делает движок.
# Фраза и пометка берутся из канона (references/trust-zones.md), а не из кода замка.

set -uo pipefail

# Обвязка печатает русский текст через python; хуку кодировку НЕ навязываем: он ставит её
# сам, а спорное условие (чужая кодовая страница) подаётся ему через env (правило 3д).
export PYTHONIOENCODING=utf-8
HOOK="$(cd "$(dirname "$0")/.." && pwd)/session-git-guard.sh"
PYCORE="$(cd "$(dirname "$0")/.." && pwd)/session-git-guard.py"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CANON="${ROOT}/.claude/agents/references/trust-zones.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE="${TMP}/папка с пробелом"
mkdir -p "$BASE"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2" | head -6; }

# ── каноны из источника ───────────────────────────────────────────────────────
PHRASE="$(python3 -c 'import re,sys; t=open(sys.argv[1],encoding="utf-8").read(); m=re.search(r"Фраза отправки с чужими коммитами: «([^»]+)»", t); print(m.group(1) if m else "")' "$CANON")"
ACK="$(python3 -c 'import re,sys; t=open(sys.argv[1],encoding="utf-8").read(); m=re.search(r"Пометка проверенных строк: `([^`]+)`", t); print(m.group(1) if m else "")' "$CANON")"
echo "[0] каноны из references/trust-zones.md"
[ -n "$PHRASE" ] && ok "фраза найдена: «${PHRASE}»" || bad "фраза в каноне не найдена (потерян источник)"
[ -n "$ACK" ] && ok "пометка найдена: ${ACK}" || bad "пометка в каноне не найдена (потерян источник)"
grep -qF "PUSH_PHRASE = \"${PHRASE}\"" "$(dirname "$PYCORE")/approval_format.py" && ok "фраза в замке совпадает с каноном" || bad "фраза в замке расходится с каноном"
grep -qF "ACK_MARK = \"${ACK}\"" "$PYCORE" && ok "пометка в замке совпадает с каноном" || bad "пометка в замке расходится с каноном"

# ── обвязка ───────────────────────────────────────────────────────────────────
hook() { # $1 событие $2 сессия $3 транскрипт $4 cwd $5 команда
  python3 -c '
import json,sys
d = {"hook_event_name":sys.argv[1],"session_id":sys.argv[2],"transcript_path":sys.argv[3],"cwd":sys.argv[4],"tool_name":"Bash","tool_input":{"command":sys.argv[5]}}
if sys.argv[6]: d["turn_id"] = "test-turn"
print(json.dumps(d, ensure_ascii=False))' \
    "$1" "$2" "$3" "$4" "$5" "${HOOK_CODEX:-}" | env PYTHONIOENCODING="${HOOK_ENC:-utf-8}" bash "$HOOK"
}
log_tool() { # $1 транскрипт $2 команда: вызов инструмента сессии, как пишет движок
  python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":sys.argv[2]}}]}}, ensure_ascii=False))' "$1" "$2" >> "$1"
}
say_user() { # $1 транскрипт $2 текст оператора
  python3 -c 'import json,sys; print(json.dumps({"type":"user","message":{"role":"user","content":sys.argv[2]}}, ensure_ascii=False))' "$1" "$2" >> "$1"
}
say_assistant() {
  python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":sys.argv[2]}]}}, ensure_ascii=False))' "$1" "$2" >> "$1"
}
tool_result_user() { # вывод инструмента с фразой внутри: голосом оператора не считается
  python3 -c 'import json,sys; print(json.dumps({"type":"user","sourceToolUseID":"toolu_x","message":{"role":"user","content":sys.argv[2]}}, ensure_ascii=False))' "$1" "$2" >> "$1"
}
# run_as: сессия выполняет команду через замок. Печатает вердикт хука; при отказе не исполняет.
rewritten() {
  python3 -c 'import json,sys; raw=sys.argv[1]; d=json.loads(raw) if raw else {}; print(d.get("hookSpecificOutput",{}).get("updatedInput",{}).get("command",sys.argv[2]))' "$1" "$2"
}
run_as() { # $1 сессия $2 команда
  local sid="$1" cmd="$2" tr out
  tr="${TMP}/${sid}.jsonl"
  log_tool "$tr" "$cmd"
  out="$(hook PreToolUse "$sid" "$tr" "$WORK" "$cmd")"
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
    printf '%s' "$out"; return 0
  fi
  cmd="$(rewritten "$out" "$cmd")" || return 1
  (cd "$WORK" && bash -c "$cmd") >/dev/null 2>&1
  printf '%s' "$out"
}
is_deny()  { printf '%s' "$1" | grep -q '"permissionDecision": *"deny"'; }
expect_allow() { if is_deny "$2"; then bad "$1" "$2"; else ok "$1"; fi; }
expect_deny()  { # $1 имя $2 вывод $3 обязательная подстрока (необязательна)
  if ! is_deny "$2"; then bad "$1 (ожидали запрет, получили пропуск)"; return; fi
  if [ -n "${3:-}" ] && ! printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (в отказе нет «${3}»)" "$2"; return; fi
  ok "$1"
}

# ── общая рабочая копия ───────────────────────────────────────────────────────
git -c init.defaultBranch=main init -q --bare "${BASE}/remote.git"
WORK="${BASE}/work"
git -c init.defaultBranch=main init -q "$WORK"
git -C "$WORK" config user.email t@t; git -C "$WORK" config user.name t
git -C "$WORK" remote add origin "${BASE}/remote.git"
printf 'Статус: исходная строка общего файла\n' > "${WORK}/СТАТУС.md"
git -C "$WORK" add -A; git -C "$WORK" commit -qm "начало"; git -C "$WORK" push -q -u origin main
TA="${TMP}/A.jsonl"; TB="${TMP}/B.jsonl"
say_user "$TA" "запиши статус"; say_user "$TB" "запиши статус"

echo "[1] push уносит чужие коммиты (09.11.2026)"
o="$(run_as A 'printf "Запись сессии А о выкатке зимнего времени\n" > a.txt && git add -- a.txt && git commit -qm "А: своя запись"')"
expect_allow "А коммитит свой файл" "$o"
o="$(run_as B 'printf "Запись сессии Б о выкатке Проект Са\n" > b.txt && git add -- b.txt && git commit -qm "Б: своя запись"')"
expect_allow "Б коммитит свой файл" "$o"
o="$(run_as A 'git push -q origin main')"
expect_deny "А: push с коммитом Б блокируется" "$o" "Б: своя запись"
o="$(run_as B 'git push -q origin main')"
expect_deny "Б: push с коммитом А блокируется (в обе стороны)" "$o" "А: своя запись"
say_assistant "$TA" "Напиши «${PHRASE}», если согласен"
o="$(hook PreToolUse A "$TA" "$WORK" 'git push -q origin main')"
expect_deny "фраза в реплике агента замок не открывает" "$o"
tool_result_user "$TA" "${PHRASE}"
o="$(hook PreToolUse A "$TA" "$WORK" 'git push -q origin main')"
expect_deny "фраза в выводе инструмента замок не открывает (C.11)" "$o"
say_user "$TA" "не ${PHRASE}"
o="$(hook PreToolUse A "$TA" "$WORK" 'git push -q origin main')"
expect_deny "отрицание фразы блокирует отправку" "$o"
combined_cmd='git push --force-with-lease origin main'
say_user "$TA" "$(printf 'подтверждаю %s, беру риск на себя, бэкап проверен\nкаталог %s\n%s' "$combined_cmd" "$WORK" "$PHRASE")"
o="$(hook PreToolUse A "$TA" "$WORK" "$combined_cmd")"
expect_allow "одно сообщение для двух замков на точную отправку" "$o"
o="$(hook PreToolUse A "$TA" "$WORK" 'git push origin main')"
expect_deny "совместное согласие не подходит другой команде" "$o"
say_user "$TA" "${PHRASE}"
o="$(run_as A 'git push -q origin main')"
expect_allow "фраза оператора в последней реплике открывает отправку" "$o"
say_user "$TA" "дальше"
o="$(run_as B 'git push -q origin main')"
expect_allow "у Б после отправки уходить нечего" "$o"
o="$(run_as A 'printf "Вторая запись сессии А о проверке ключа\n" > a2.txt && git add -- a2.txt && git commit -qm "А: вторая"')"
expect_allow "А коммитит вторую запись" "$o"
o="$(run_as A 'git push -q origin main')"
expect_allow "только свои коммиты уходят без фразы" "$o"
o="$(run_as B 'printf "Ещё запись сессии Б о доске\n" > b2.txt && git add -- b2.txt && git commit -qm "Б: вторая"')"
expect_allow "Б коммитит вторую запись" "$o"
say_user "$TA" "${PHRASE}"; say_user "$TA" "ок"
o="$(hook PreToolUse A "$TA" "$WORK" 'git push -q origin main')"
expect_deny "фраза действует только в последней реплике" "$o" "Б: вторая"
o="$(hook PreToolUse A "$TA" "$WORK" "D=\"${WORK}\"; git -C \"\$D\" push -q origin main")"
expect_deny "путь через переменную в той же команде распознан" "$o" "Б: вторая"
o="$(hook PreToolUse A "$TA" "$TMP" "git -C \"${WORK}\" push -q origin main")"
expect_deny "путь с пробелом и кириллицей через -C распознан" "$o" "Б: вторая"
o="$(hook PreToolUse A "$TA" "$TMP" 'git -C "$NOWHERE" push -q origin main')"
expect_deny "неопределимый репозиторий: запрет с советом" "$o" "git -C"
o="$(hook PreToolUse A "$TA" "$WORK" "ssh fixture-host'cd /srv/apps/x && git push -q origin main'")"
expect_allow "git push внутри ssh не проверяется" "$o"
echo "[1а] фикстура обхода: формы отправки, которых не было в исходных примерах"
o="$(hook PreToolUse A "$TA" "$WORK" 'git push')"
expect_deny "git push без аргументов (по upstream)" "$o" "Б: вторая"
o="$(hook PreToolUse A "$TA" "$WORK" 'git push origin HEAD:main')"
expect_deny "git push origin HEAD:main" "$o" "Б: вторая"
o="$(hook PreToolUse A "$TA" "$WORK" "$(command -v git) push -q origin main")"
expect_deny "git с полным путём" "$o" "Б: вторая"
o="$(hook PreToolUse A "$TA" "$WORK" "(cd \"${WORK}\" && git push -q)")"
expect_deny "git push в подоболочке после cd" "$o" "Б: вторая"
git -C "$WORK" branch -q side-b HEAD   # ветка с коммитом Б, текущая ветка при этом своя
git -C "$WORK" checkout -q -b mine-a origin/main
o="$(hook PreToolUse A "$TA" "$WORK" 'git push --all origin')"
expect_deny "git push --all уносит чужое из другой ветки" "$o" "Б: вторая"
git -C "$WORK" checkout -q main; git -C "$WORK" branch -q -D side-b mine-a
(cd "$WORK" && git push -q origin main)   # Б отправляет руками: дальше чистое состояние

echo "[2] коммит забирает чужой индекс (27.10.2026)"
o="$(run_as B 'printf "Файл, подготовленный сессией Б\n" > staged-b.txt && git add -- staged-b.txt')"
expect_allow "Б подготовила файл к коммиту" "$o"
o="$(run_as A 'printf "Третья запись сессии А про индекс\n" > a3.txt && git add -- a3.txt && git commit -qm "А: третья"')"
expect_deny "А: commit без путей при чужом файле в индексе блокируется" "$o" "staged-b.txt"
o="$(run_as A 'printf "Третья запись сессии А про индекс\n" > a3.txt && git add -- a3.txt && git commit -qm "А: третья" -- a3.txt')"
expect_allow "А: commit с явными путями проходит" "$o"
files="$(git -C "$WORK" show --name-only --format= HEAD)"
[ "$files" = "a3.txt" ] && ok "в коммите А только её файл" || bad "в коммите А лишнее" "$files"
git -C "$WORK" diff --cached --name-only | grep -qx 'staged-b.txt' && ok "файл Б остался в индексе нетронутым" || bad "файл Б пропал из индекса"
o="$(run_as A 'printf "Пятая запись сессии А, путь без двойного дефиса\n" > a5.txt && git add -- a5.txt && git commit -qm "А: пятая" a5.txt')"
expect_allow "commit с путём без -- проходит" "$o"
[ "$(git -C "$WORK" show --name-only --format= HEAD)" = "a5.txt" ] && ok "и берёт только этот путь" || bad "commit с путём без -- взял лишнее"
printf 'правка Б в общем файле\n' >> "${WORK}/СТАТУС.md"
o="$(hook PreToolUse A "$TA" "$WORK" 'git commit -qam "А: всё разом"')"
expect_deny "commit -a с чужими правками блокируется" "$o" "СТАТУС.md"
(cd "$WORK" && git checkout -q -- СТАТУС.md && git commit -qm "Б: свой файл" -- staged-b.txt)

echo "[3] коммит забирает чужие строки общего файла (03.09.2026)"
o="$(run_as B 'cat >> СТАТУС.md <<'"'"'EOF'"'"'
## Сессия Б: дневной разбор Проект Б и Проекта А
Незакоммиченный раздел соседней сессии, строка первая
EOF')"
expect_allow "Б дописала незакоммиченный раздел" "$o"
o="$(run_as A 'printf "Запись сессии А о переносе дампа в карантин\n" >> СТАТУС.md && git commit -qm "А: статус" -- СТАТУС.md')"
expect_deny "А: коммит с чужими строками останавливается" "$o" "дневной разбор Проект Б"
printf '%s' "$o" | grep -qF "переносе дампа в карантин" && bad "своя строка А помечена чужой" || ok "своя строка А чужой не помечена"
o="$(run_as A "${ACK} git commit -qm \"А: статус\" -- СТАТУС.md")"
expect_allow "повтор с пометкой проходит" "$o"
o="$(run_as A 'printf "Ещё одна строка сессии А в общем статусе\n" >> СТАТУС.md && git commit -qm "А: статус 2" -- СТАТУС.md')"
expect_allow "только свои строки проходят без пометки" "$o"
o="$(run_as A 'printf "Начало строки сессии А, середина старая, конец строки сессии А\n" > a6.txt')"
o="$(run_as A "python3 -c 'import sys; p=\"a6.txt\"; t=open(p).read().replace(\"середина старая\", \"середина новая и длинная\"); open(p,\"w\").write(t)'")"
o="$(run_as A 'git add -- a6.txt && git commit -qm "А: шестая" -- a6.txt')"
expect_allow "своя строка, склеенная частичной правкой, проходит" "$o"
printf '| Замки общего репозитория | исходный хвост строки, который давно лежит в истории и никем не переписан |\n' > "${WORK}/map.md"
(cd "$WORK" && git add -- map.md && git commit -qm "карта: исходная строка" -- map.md)
o="$(run_as A "python3 -c 'p=\"map.md\"; t=open(p).read().replace(\"| Замки общего репозитория |\", \"| Замки общего репозитория, чужое в коммите и отправке |\"); open(p,\"w\").write(t)'")"
o="$(run_as A 'git commit -qm "А: карта" -- map.md')"
expect_allow "правка начала закоммиченной строки со старым хвостом проходит" "$o"
printf '| Замки общего репозитория | исходный хвост строки, который давно лежит в истории, дописано соседом Б в середине недели |\n' > "${WORK}/map.md"
o="$(hook PreToolUse A "$TA" "$WORK" 'git commit -qm "А: карта 2" -- map.md')"
expect_deny "новые слова соседа в старой строке всё равно видны" "$o" "соседом Б"
(cd "$WORK" && git checkout -q -- map.md)
printf 'Новый файл, который оставила сессия Б и не добавила в git\n' > "${WORK}/forgotten-b.md"
o="$(hook PreToolUse A "$TA" "$WORK" 'git add -- forgotten-b.md && git commit -qm "А: заберу" -- forgotten-b.md')"
expect_deny "строки нового чужого файла тоже проверяются" "$o" "оставила сессия Б"
rm -f "${WORK}/forgotten-b.md"

echo "[4] --amend поверх чужого коммита"
o="$(run_as B 'printf "Четвёртая запись сессии Б\n" > b4.txt && git add -- b4.txt && git commit -qm "Б: четвёртая"')"
expect_allow "Б коммитит" "$o"
o="$(hook PreToolUse A "$TA" "$WORK" 'git commit --amend -qm "А: поправка"')"
expect_deny "А: amend поверх коммита Б блокируется" "$o" "Б: четвёртая"
o="$(hook PreToolUse B "$TB" "$WORK" 'git commit --amend -qm "Б: четвёртая, поправка"')"
expect_allow "Б: amend своего коммита проходит" "$o"

echo "[5] память сессии"
ha="$(git -C "$WORK" log --format=%H --grep='^А: своя запись$' | head -1)"
hb="$(git -C "$WORK" log --format=%H --grep='^Б: своя запись$' | head -1)"
owns() {
  python3 -B -c '
import runpy, sys
m = runpy.run_path(sys.argv[1])
sys.exit(0 if sys.argv[4] in m["my_commits"](sys.argv[2], sys.argv[3]) else 1)
' "$PYCORE" "$1" "$WORK" "$2"
}
owns A "$ha" && ok "коммит А записан за А" || bad "коммит А не записан"
owns A "$hb" && bad "коммит Б записан за А" || ok "коммит Б за А не записан"
o="$(hook PreToolUse A "$TA" "$WORK" 'ls -la && echo готово')"
[ -z "$o" ] && ok "команда без git проходит молча" || bad "команда без git дала вывод" "$o"

echo "[6] вердикт доходит и при чужой кодовой странице (правило 3д)"
o="$(HOOK_ENC=cp1252 hook PreToolUse A "$TA" "$WORK" 'git push -q origin main')"
if is_deny "$o" && printf '%s' "$o" | grep -qF "ЗАМОК"; then ok "при cp1252 отказ напечатан по-русски"; else bad "при cp1252 вердикт потерян" "$o"; fi

echo "[7] две сессии получили допуск до выполнения любой из команд"
ca='git commit -qm "одинаковое сообщение" --allow-empty'
cb="$ca"
pa="$(HOOK_CODEX=1 hook PreToolUse A "$TA" "$WORK" "$ca")"
pb="$(hook PreToolUse B "$TB" "$WORK" "$cb")"
printf '%s' "$pa" | grep -q '"permissionDecision": "allow"' && ok "Codex получил обновлённый вход" || bad "Codex не получил обновлённый вход"
printf '%s' "$pb" | grep -q '"permissionDecision"' && bad "для Claude отключена проверка разрешений" || ok "разрешения Claude остались в силе"
(cd "$WORK" && bash -c "$(rewritten "$pb" "$cb")") || bad "коммит Б не создался"
hb="$(git -C "$WORK" rev-parse HEAD)"
(cd "$WORK" && bash -c "$(rewritten "$pa" "$ca")") || bad "коммит А не создался"
ha="$(git -C "$WORK" rev-parse HEAD)"
[ "$ha" != "$hb" ] && owns A "$ha" && owns B "$hb" && ! owns A "$hb" && ! owns B "$ha" \
  && ok "даже коммиты с одинаковым сообщением принадлежат каждый своей сессии" || bad "коммиты перепутаны"
bad_ref="$(hook PreToolUse A "$TA" "$WORK" 'git push origin fixture-branch-not-present')"
expect_deny "неизвестный источник отправки блокируется" "$bad_ref" "не удалось определить"
o="$(python3 -B -c '
import runpy, sys
m = runpy.run_path(sys.argv[1])
check = m["check_push"]
real_git = m["git"]
def git_with_failed_rev_list(repo, *args):
    return None if args[0] == "rev-list" else real_git(repo, *args)
check.__globals__["git"] = git_with_failed_rev_list
check(sys.argv[2], ["origin", "main"], "A", sys.argv[3], "git push origin main", sys.argv[2])
' "$PYCORE" "$WORK" "$TA")"
expect_deny "сбой чтения списка коммитов блокирует отправку" "$o" "не удалось определить"
bad_mix="$(hook PreToolUse A "$TA" "$WORK" 'git commit --allow-empty -qm test && git push origin main')"
expect_deny "коммит и отправка в одной команде блокируются" "$bad_mix" "двумя разными вызовами"
literal='printf "%s\n" "git commit -m текст"'
o="$(hook PreToolUse A "$TA" "$WORK" "$literal")"
[ "$(rewritten "$o" "$literal")" = "$literal" ] && ok "цитата в команде сохранена" || bad "цитата изменена"
tagged="$(rewritten "$pb" "$cb")"
o="$(hook PreToolUse B "$TB" "$WORK" "$tagged")"
[ -z "$o" ] && ok "при повторном вызове метка не дублируется" || bad "метка добавлена повторно"

echo
echo "Итог: ${PASS} прошло, ${FAIL} провалено"
[ "$FAIL" -eq 0 ]
