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
echo "[5] Текущее состояние репозитория"
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
