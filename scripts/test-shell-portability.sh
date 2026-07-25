#!/usr/bin/env bash
# test-shell-portability.sh — тест линтера переносимости.
#
# ПОЧЕМУ ТЕСТ УСТРОЕН ИМЕННО ТАК. Грабля 2026-07-24 (замок красной зоны): двадцать четыре
# зелёных теста проверяли хук против ВЫДУМАННОЙ фразы, а не против канона — и не заметили,
# что замок не открылся бы никогда. Поэтому здесь секция [1] берёт строки не из головы
# автора, а **из истории git** — из тех самых версий файлов, где баг реально жил.
# Если линтер их не ловит, он бесполезен, как бы красиво ни проходили синтетические тесты.
#
# Запуск: bash scripts/test-shell-portability.sh

set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINTER="$ROOT/scripts/check-shell-portability.sh"
PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -f "$WORK"/* 2>/dev/null; rmdir "$WORK" 2>/dev/null' EXIT

ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }

# Кладёт переданные строки в md-файл внутри ```bash-блока.
fixture() {  # $1 = имя файла, далее строки кода
    local name="$1"; shift
    { echo "# фикстура"; echo; echo '```bash'; printf '%s\n' "$@"; echo '```'; } > "$WORK/$name"
    echo "$WORK/$name"
}

echo "── тест линтера переносимости ──────────────────────────"
echo

# ═══════════════════════════════════════════════════════════════════════════
echo "[1] Реальные баги из истории git — линтер обязан их ловить"
# ═══════════════════════════════════════════════════════════════════════════
# Коммит 544ecc8 — состояние до этапа 2, там оба цикла ещё со строкой.
HIST_REF="544ecc8"
if git -C "$ROOT" cat-file -e "$HIST_REF^{commit}" 2>/dev/null; then
    for spec in \
        ".claude/skills/inventory-scan/SKILL.md|for f in \$KEY_FILES" \
        ".claude/skills/rotate-secrets/SKILL.md|for compose_dir in \$CONSUMER_DIRS"
    do
        path="${spec%%|*}"; needle="${spec#*|}"
        line="$(git -C "$ROOT" show "$HIST_REF:$path" 2>/dev/null | grep -F "$needle" | head -1)"
        if [ -z "$line" ]; then
            bad "строка «$needle» не найдена в $HIST_REF:$path — тест потерял источник"
            continue
        fi
        f="$(fixture "hist-$(basename "$(dirname "$path")").md" "$line")"
        if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
            bad "НЕ поймал реальный баг из $HIST_REF:$path → $line"
        else
            ok "поймал реальный баг из истории: $(basename "$(dirname "$path")") → ${line# }"
        fi
    done
else
    bad "коммит $HIST_REF недоступен — секция [1] не проверена (тест без источника не считается)"
fi
echo

# ═══════════════════════════════════════════════════════════════════════════
echo "[2] Каждое правило срабатывает"
# ═══════════════════════════════════════════════════════════════════════════
i=0
for probe in \
    'for f in $FILES; do echo "$f"; done' \
    'for f in ${FILES}; do echo "$f"; done' \
    'echo "${arr[0]}"' \
    'read -a parts <<< "$line"' \
    'shopt -s nullglob' \
    'echo "${PIPESTATUS[0]}"' \
    'mapfile -t lines < file.txt' \
    '[ -z "$BASH_VERSION" ] && exit 1'
do
    i=$((i+1))
    f="$(fixture "probe-$i.md" "$probe")"
    if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
        bad "правило не сработало: $probe"
    else
        ok "поймано: $probe"
    fi
done
echo

# ═══════════════════════════════════════════════════════════════════════════
echo "[3] Ложных срабатываний нет — корректный код проходит"
# ═══════════════════════════════════════════════════════════════════════════
i=0
for probe in \
    'for f in "${KEY_FILES[@]}"; do echo "$f"; done' \
    'for f in *.txt; do echo "$f"; done' \
    'for f in $(ls); do echo "$f"; done' \
    'for i in 1 2 3; do echo "$i"; done' \
    'echo "${arr[1]}"' \
    'echo "${arr[@]}"' \
    'read -r line' \
    'read -rp "вопрос: " ans'
do
    i=$((i+1))
    f="$(fixture "clean-$i.md" "$probe")"
    if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
        ok "пропущено как корректное: $probe"
    else
        bad "ЛОЖНОЕ срабатывание на корректном коде: $probe"
    fi
done
echo

# ═══════════════════════════════════════════════════════════════════════════
echo "[4] Границы: не-shell блоки и комментарии не проверяются"
# ═══════════════════════════════════════════════════════════════════════════
{ echo '```json'; echo 'for f in $FILES; do'; echo '```'; } > "$WORK/json.md"
if bash "$LINTER" --root "$WORK" "$WORK/json.md" >/dev/null 2>&1; then
    ok 'блок ```json не проверяется'
else
    bad 'полез в блок ```json'
fi

{ echo '```bash'; echo '# for f in $FILES; do  — это комментарий, не код'; echo '```'; } > "$WORK/comment.md"
if bash "$LINTER" --root "$WORK" "$WORK/comment.md" >/dev/null 2>&1; then
    ok "комментарий внутри shell-блока не считается кодом"
else
    bad "сработал на комментарии"
fi

{ echo 'просто текст, где упомянут for f in $FILES'; } > "$WORK/prose.md"
if bash "$LINTER" --root "$WORK" "$WORK/prose.md" >/dev/null 2>&1; then
    ok "проза вне блока не проверяется"
else
    bad "сработал на прозе вне блока"
fi
echo

# ═══════════════════════════════════════════════════════════════════════════
echo "[5] Обход замка: конструкции, найденные проверщиком 25.07.2026"
# ═══════════════════════════════════════════════════════════════════════════
# Первая версия линтера ловила 2 конструкции из 26 — независимый проверщик написал
# фикстуру обхода. Каждая строка ниже проверена живым запуском в zsh 5.9: она
# действительно ведёт себя не так, как в bash. Секция держит покрытие от отката.
i=0
for probe in \
    'systemctl restart $SERVICES' \
    'docker compose -f $COMPOSE_FILES up -d' \
    'cd $CONSUMER_DIRS' \
    'set -- $DIRS' \
    'for d in $A $B; do echo x; done' \
    'echo "${#parts[0]}"' \
    'echo "${parts[0]:-нет}"' \
    'echo "${parts[ 0 ]}"' \
    'echo "$parts[0]"' \
    'arr[0]="первый"' \
    'echo "${v^^}"' \
    'echo "${v,,}"' \
    'echo "${!name}"' \
    'echo "${BASH_REMATCH[1]}"' \
    '[ -n "$BASH_VERSION" ] && echo bash' \
    'echo "${BASH_SOURCE[0]}"' \
    "read -d '' -a parts <<< \"\$line\""
do
    i=$((i+1))
    f="$(fixture "evade-$i.md" "$probe")"
    if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
        bad "ОБХОД: не поймано → $probe"
    else
        ok "поймано: $probe"
    fi
done

# Разметка: забор в другом регистре и тильда-забор скрывали блок целиком
{ echo '```BASH'; echo 'for f in $KEY_FILES; do echo "$f"; done'; echo '```'; } > "$WORK/case.md"
if bash "$LINTER" --root "$WORK" "$WORK/case.md" >/dev/null 2>&1; then
    bad 'ОБХОД: забор ```BASH в верхнем регистре скрывает блок'
else
    ok 'забор ```BASH (верхний регистр) проверяется'
fi
{ echo '~~~bash'; echo 'shopt -s nullglob'; echo '~~~'; } > "$WORK/tilde.md"
if bash "$LINTER" --root "$WORK" "$WORK/tilde.md" >/dev/null 2>&1; then
    bad 'ОБХОД: тильда-забор ~~~bash скрывает блок'
else
    ok 'тильда-забор ~~~bash проверяется'
fi
echo

# ═══════════════════════════════════════════════════════════════════════════
echo "[6] Ложные срабатывания на чужой оболочке: heredoc и ssh"
# ═══════════════════════════════════════════════════════════════════════════
# Код внутри heredoc уходит в файл с шебангом bash или на сервер — там bash-конструкции
# законны. Репозиторий сисадмина полон таких мест, и блокировать их нельзя.
{ echo '```bash'; echo "cat > /tmp/run.sh <<'SCRIPT'"; echo 'for f in $KEY_FILES; do echo "$f"; done';
  echo 'SCRIPT'; echo '```'; } > "$WORK/heredoc-file.md"
if bash "$LINTER" --root "$WORK" "$WORK/heredoc-file.md" >/dev/null 2>&1; then
    ok 'heredoc в файл с шебангом bash — не блокируется'
else
    bad 'ЛОЖНОЕ: заблокирован heredoc, уходящий в bash-скрипт'
fi

{ echo '```bash'; echo "ssh host bash <<'REMOTE'"; echo 'shopt -s nullglob'; echo 'REMOTE'; echo '```'; } > "$WORK/heredoc-ssh.md"
if bash "$LINTER" --root "$WORK" "$WORK/heredoc-ssh.md" >/dev/null 2>&1; then
    ok 'heredoc на удалённый bash — не блокируется'
else
    bad 'ЛОЖНОЕ: заблокирован heredoc, уходящий на сервер'
fi

{ echo '```bash'; echo 'ssh "$SERVER" "cd $compose_dir && docker compose restart"'; echo '```'; } > "$WORK/ssh-inline.md"
if bash "$LINTER" --root "$WORK" "$WORK/ssh-inline.md" >/dev/null 2>&1; then
    ok 'команда в кавычках для чужой оболочки — не блокируется'
else
    bad 'ЛОЖНОЕ: заблокирована удалённая команда в кавычках'
fi

for probe in \
    'cd "$INFRA_DIR" && git status' \
    'systemctl restart "$UNIT"' \
    'docker compose -f "$FILE" up -d'
do
    i=$((i+1))
    f="$(fixture "quoted-$i.md" "$probe")"
    if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
        ok "квотированная переменная пропущена: $probe"
    else
        bad "ЛОЖНОЕ срабатывание на корректном коде: $probe"
    fi
done
echo

# ═══════════════════════════════════════════════════════════════════════════
echo "[7] Пустой список файлов не роняет линтер"
# ═══════════════════════════════════════════════════════════════════════════
# bash 3.2 (штатный на macOS) + set -u: "${FILES[@]}" на пустом массиве — фатальная
# ошибка, маскирующаяся под «найдены нарушения» (тот же код возврата 1).
EMPTY="$(mktemp -d)"
if out="$(bash "$LINTER" --root "$EMPTY" 2>&1)" && [ "${out#*unbound}" = "$out" ]; then
    ok "дерево без скиллов: выход 0, без unbound variable"
else
    bad "падение на пустом списке файлов: $out"
fi
rmdir "$EMPTY" 2>/dev/null
echo

# ═══════════════════════════════════════════════════════════════════════════
echo "[8] Текущее состояние репозитория"
# ═══════════════════════════════════════════════════════════════════════════
if bash "$LINTER" --root "$ROOT" >/dev/null 2>&1; then
    ok "репозиторий чист"
else
    bad "в репозитории есть непереносимые конструкции (см. bash $LINTER)"
fi
echo

echo "────────────────────────────────────────────────────────"
printf 'PASS: %s   FAIL: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
