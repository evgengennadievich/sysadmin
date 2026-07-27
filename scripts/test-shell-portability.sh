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

# Кладёт строки в md-файл КАК ЕСТЬ, без ```bash-блока: живая подстановка `` !`…` ``
# стоит в обычном тексте, и если линтер смотрит только внутрь блоков — он её не увидит.
fixture_plain() {  # $1 = имя файла, далее строки
    local name="$1"; shift
    { echo "# фикстура"; echo; printf '%s\n' "$@"; } > "$WORK/$name"
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
echo "[6а] Глушилки парсера: строка, отключающая проверку остатка блока"
# ═══════════════════════════════════════════════════════════════════════════
# Самый опасный класс: не «правило не поймало», а «до правил не дошло».
# Ложный heredoc глушит ВСЕ правила до конца блока, и замок печатает «чисто»
# при живых нарушениях. Восемь способов нашёл проверщик 25.07.2026 — все ниже.
# Проверяем так: глушилка + заведомо плохая строка под ней; плохая обязана ловиться.
i=0
for muffler in \
    '# пример вызова: cat << EOF' \
    'echo "разделитель a << b"' \
    'MASK=$(( 1 << BITS ))' \
    '# <<<<<<< HEAD' \
    'grep -c "<<" file.txt' \
    'echo "a" <<< "$VAR"'
do
    i=$((i+1))
    f="$(fixture "muffler-$i.md" "$muffler" 'for f in $KEY_FILES; do echo x; done')"
    if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
        bad "ГЛУШИЛКА: проверка отключена строкой → $muffler"
    else
        ok "не глушит: $muffler"
    fi
done

# Ограничитель с дефисом: sed обрезал его на дефисе, и блок немел до конца
{ echo '```bash'; echo "cat > f <<'EOF-1'"; echo 'тело'; echo 'EOF-1';
  echo 'echo "${v^^}"'; echo '```'; } > "$WORK/hd-dash.md"
if bash "$LINTER" --root "$WORK" "$WORK/hd-dash.md" >/dev/null 2>&1; then
    bad "ГЛУШИЛКА: ограничитель с дефисом (<<'EOF-1') глушит остаток блока"
else
    ok "ограничитель с дефисом закрывается корректно"
fi

# Кавычки из разных одинарных выражений склеивались в мнимую пару
f="$(fixture "quote-pair.md" "sed 's/\"/x/' a; cd \$DIRS && sed 's/\"/y/' b")"
if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
    bad 'ГЛУШИЛКА: кавычки из разных одинарных выражений прячут дефект'
else
    ok 'мнимая пара кавычек не прячет дефект'
fi

# Терминатор после переменной: точка с запятой — самая ходовая форма
i=0
for probe in \
    'cd $DIRS; docker compose restart' \
    'systemctl restart $UNITS; echo ok' \
    '(cd $DIRS)' \
    'chmod 600 $KEY' \
    'docker logs --tail 50 $NAME'
do
    i=$((i+1))
    f="$(fixture "term-$i.md" "$probe")"
    if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
        bad "не поймано (терминатор): $probe"
    else
        ok "поймано: $probe"
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

# ═══════════════════════════════════════════════════════════════════════════
echo "[9] Правило 16 — страховка кода возврата в живой подстановке (ADR-0029)"
# ═══════════════════════════════════════════════════════════════════════════
# Ожог 2026-07-27: helper вернул 1 («есть просроченные файлы» — его штатный сигнал),
# подстановка отдала код наружу, и Claude Code вернул ПУСТОЙ ответ при коде выхода 0.
# Ни ошибки, ни предупреждения — скилл выглядел сломанным целиком.
#
# ЧЕСТНО ПРО ИСТОЧНИК. Незастрахованной версии строки в git НЕТ: она прожила меньше
# одного коммита. Поэтому фикстура не «дословная» (так было написано в первой редакции
# теста — проверщик 27.07.2026 справедливо назвал это дефектом уровня C.2), а
# ВЫВЕДЕННАЯ из реальной: берём живую строку из коммита и снимаем с неё страховку.
# Выдумки тут нет — есть операция над настоящим текстом.
REAL_LINE="$(git -C "$ROOT" show '0bb4c6b:.claude/skills/refresh-vpn-knowledge/SKILL.md' 2>/dev/null | grep -F '!`' | head -1)"
if [ -z "$REAL_LINE" ]; then
    bad "не достал реальную строку подстановки из 0bb4c6b — секция без источника не считается"
else
    ok "источник получен из коммита 0bb4c6b, а не из головы автора"
    UNGUARDED="$(printf '%s' "$REAL_LINE" | sed 's/ || true`$/`/')"
    if [ "$UNGUARDED" = "$REAL_LINE" ]; then
        bad "снять страховку с реальной строки не удалось — форма изменилась, фикстура протухла"
    fi
    f="$(fixture_plain "subst-burn.md" "$UNGUARDED")"
    if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
        bad "НЕ поймал реальную строку со снятой страховкой"
    else
        ok "поймал реальную строку со снятой страховкой"
    fi
    f="$(fixture_plain "subst-ok.md" "$REAL_LINE")"
    if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
        ok "пропустил её же со страховкой (ложных срабатываний нет)"
    else
        bad "ложное срабатывание на реальной строке из репозитория"
    fi
fi
echo

# ═══════════════════════════════════════════════════════════════════════════
echo "[10] Фикстура обхода: формы, которые среда исполняет, а замок обязан видеть"
# ═══════════════════════════════════════════════════════════════════════════
# Формы взяты не из головы: проверщик 27.07.2026 достал регулярки из самого клиента
# Claude Code 2.1.220 —
#     ```!  …  ```                 исполняемый блок
#     (?<=^|\s)!`команда`          инлайн, в ЛЮБОМ месте строки, по нескольку раз
# — и воспроизвёл ДВЕНАДЦАТЬ обходов первой редакции правила 16, которая знала только
# «строка целиком состоит из подстановки». Каждая строка ниже реально исполняется.
# Урок, ради которого секция существует: замок проверяют фикстурой ОБХОДА, а не
# примерами, ради которых он писался.
BYPASS_CASES=(
    'текст перед !`echo hi`'
    '- пункт списка !`echo hi`'
    '> цитата !`echo hi`'
    '**жирный** !`echo hi`'
    '!`echo hi` текст после'
    'две в строке !`echo a` и !`echo b || true`'
)
i=0
for case_line in "${BYPASS_CASES[@]}"; do
    i=$((i+1))
    f="$(fixture_plain "bypass-$i.md" "$case_line")"
    if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
        bad "обход прошёл насквозь: $case_line"
    else
        ok "обход закрыт: $case_line"
    fi
done

# Экранированная форма среде НЕ команда — ловить её было бы ложным срабатыванием.
f="$(fixture_plain "escaped.md" '\!`echo hi`')"
if bash "$LINTER" --root "$WORK" "$f" >/dev/null 2>&1; then
    ok "экранированная \\!\`…\` не считается подстановкой"
else
    bad "ложное срабатывание на экранированной форме"
fi

# Вторая форма — исполняемый блок ```! : его тело раньше не проверялось НИ ОДНИМ правилом.
{ echo "# фикстура"; echo; echo '```!'; echo 'echo привет'; echo 'for f in $DIRS; do echo $f; done'; echo '```'; } > "$WORK/exec-bad.md"
out="$(bash "$LINTER" --root "$WORK" "$WORK/exec-bad.md" 2>&1)"
case "$out" in
    *"без страховки"*) ok "блок \`\`\`! без страховки пойман" ;;
    *) bad "блок \`\`\`! без страховки прошёл насквозь" ;;
esac
case "$out" in
    *"перебор строки вместо массива"*) ok "общие правила достают внутрь блока \`\`\`!" ;;
    *) bad "внутрь блока \`\`\`! общие правила не достают" ;;
esac

{ echo "# фикстура"; echo; echo '```!'; echo 'echo ок || true'; echo '```'; } > "$WORK/exec-ok.md"
if bash "$LINTER" --root "$WORK" "$WORK/exec-ok.md" >/dev/null 2>&1; then
    ok "блок \`\`\`! со страховкой пропущен"
else
    bad "ложное срабатывание на корректном блоке \`\`\`!"
fi

# Регулярка клиента /```!\s*\n?([\s\S]*?)\n?```/g НЕ привязана к началу строки и НЕ требует
# перевода строки. Первая редакция разбора была построчной и обе формы ниже пропускала —
# воспроизведено проверщиком 27.07.2026 против регулярки самого клиента.
{ echo "# фикстура"; echo; echo 'текст перед забором ```!'; echo 'echo без страховки'; echo '```'; } > "$WORK/exec-midline.md"
if bash "$LINTER" --root "$WORK" "$WORK/exec-midline.md" >/dev/null 2>&1; then
    bad "забор \`\`\`! в середине строки прошёл насквозь"
else
    ok "забор \`\`\`! в середине строки пойман"
fi

{ echo "# фикстура"; echo; echo 'однострочный: ```!false```'; } > "$WORK/exec-oneline.md"
if bash "$LINTER" --root "$WORK" "$WORK/exec-oneline.md" >/dev/null 2>&1; then
    bad "однострочный блок \`\`\`!команда\`\`\` прошёл насквозь"
else
    ok "однострочный блок \`\`\`!команда\`\`\` пойман"
fi

# Номер строки обязан быть абсолютным: первая редакция накопительного смещения не вела,
# и второй блок в файле показывался со строкой из первого.
{ echo "# фикстура"; echo; echo '```!'; echo 'echo один'; echo '```'; echo; echo '```!'; echo 'echo два'; echo '```'; } > "$WORK/exec-two.md"
out="$(bash "$LINTER" --root "$WORK" "$WORK/exec-two.md" 2>&1)"
case "$out" in
    *":7 "*|*":7 —"*) ok "номер строки второго блока абсолютный (7)" ;;
    *) bad "номер строки второго блока неверен: $out" ;;
esac
echo

echo "────────────────────────────────────────────────────────"
printf 'PASS: %s   FAIL: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
