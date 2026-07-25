#!/usr/bin/env bash
# check-shell-portability.sh — линтер переносимости inline-кода скиллов и персоны.
#
# ЗАЧЕМ. Код внутри ```bash-блоков в SKILL.md и references/*.md агент не запускает
# скриптом — он вставляет его в оболочку оператора. На macOS это **zsh**, а писался код
# в расчёте на bash. Три бага этого класса уже стоили работы (живой прогон 2026-07-25):
#
#   1) inventory-scan, verify снимка: `for f in $KEY_FILES` дал ОДНУ итерацию со
#      слипшимися именами → валидный снимок объявлен битым;
#   2) rotate-secrets, шаг 5: `for d in $CONSUMER_DIRS` → `cd /opt/a /opt/b` падает
#      «too many arguments», НИ ОДИН потребитель не перезапущен после смены пароля БД;
#   3) _lib/ensure-local-env.sh: гейт проверял `$BASH_VERSION` в `source`-контексте →
#      на маке отказывал и советовал поставить Git for Windows.
#
# Правило оператора: «правило, нарушенное дважды, идёт в код». Нарушено трижды —
# отсюда этот линтер (ADR-0028). Он не просит писать переносимо, он не даёт закоммитить.
#
# ГРАНИЦА. Проверяются ТОЛЬКО inline-блоки в markdown. Файлы `*.sh` не проверяются:
# у них шебанг `#!/usr/bin/env bash`, они реально исполняются bash, и запрещать им
# bash-конструкции было бы вредно.
#
# Использование:
#   bash scripts/check-shell-portability.sh                 # весь репозиторий
#   bash scripts/check-shell-portability.sh --root <путь>   # явный корень
#   bash scripts/check-shell-portability.sh <файл> [...]    # только указанные файлы
#
# Возврат: 0 — чисто; 1 — найдены непереносимые конструкции (выведены с объяснением).

set -u

ROOT=""
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) FILES+=("$1"); shift ;;
    esac
done

if [ -z "$ROOT" ]; then
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT="$(pwd)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Правила. Каждое: regex @@ короткое имя @@ чем плохо @@ как чинить.
#
# Разделитель — «@@», а НЕ «|»: символ «|» нужен внутри самих регулярок
# (`(;|$)`, `(mapfile|readarray)`), и если делить поля по нему, регулярка обрежется
# на первой же альтернативе и правило замолчит. Именно это поймал тест при первом
# прогоне — два правила из семи не срабатывали вовсе.
# ─────────────────────────────────────────────────────────────────────────────
RULES=(
'for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+\$\{?[A-Za-z_][A-Za-z0-9_]*\}?[[:space:]]*(;|$)@@перебор строки вместо массива@@zsh НЕ дробит $VAR на слова: цикл делает ОДНУ итерацию со склеенным значением@@список — массивом: arr=(a b); for x in "${arr[@]}"'
'\$\{[A-Za-z_][A-Za-z0-9_]*\[0\]\}@@индекс [0] у массива@@в zsh массивы нумеруются с 1, ${arr[0]} пуст@@брать "${arr[1]}" или перебирать "${arr[@]}"'
'\bread[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*-[a-zA-Z]*a[a-zA-Z]*[[:space:]]@@read -a@@в zsh чтение в массив это -A, не -a@@разобрать без read -a, либо вынести в *.sh'
'\bshopt[[:space:]]@@shopt@@команды shopt в zsh нет вообще@@обойтись без неё или вынести код в *.sh с шебангом bash'
'\$\{PIPESTATUS\[@@PIPESTATUS@@в zsh это $pipestatus (другое имя и нумерация с 1)@@проверять код возврата иначе, либо вынести в *.sh'
'\b(mapfile|readarray)[[:space:]]@@mapfile/readarray@@обеих команд в zsh нет@@читать циклом while read, либо вынести в *.sh'
'\[[[:space:]]+-z[[:space:]]+"?\$\{?BASH_VERSION@@проверка $BASH_VERSION@@файл, подключённый через source, исполняется в оболочке ВЫЗЫВАЮЩЕГО: на маке это zsh и переменная пуста всегда@@проверять то, что реально нужно (наличие бинарника bash, POSIX-совместимость), а не имя текущей оболочки'
)

# ─────────────────────────────────────────────────────────────────────────────
# Сбор файлов: markdown скиллов и персоны.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${#FILES[@]}" -eq 0 ]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(
        find "$ROOT/.claude/skills" "$ROOT/.claude/agents" -name '*.md' -type f 2>/dev/null | sort
    )
fi

TOTAL_HITS=0
SCANNED=0

for file in "${FILES[@]}"; do
    [ -f "$file" ] || continue
    case "$file" in *.md) ;; *) continue ;; esac
    SCANNED=$((SCANNED + 1))

    # Идём построчно, отслеживая границы ```-блоков. Проверяем ТОЛЬКО shell-блоки
    # (```bash / ```sh / ```shell) — в ```json, ```nginx, ```cron ловить нечего.
    in_block=0
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        trimmed="${line#"${line%%[![:space:]]*}"}"

        case "$trimmed" in
            '```'*)
                if [ "$in_block" -eq 1 ]; then
                    in_block=0
                else
                    case "$trimmed" in
                        '```bash'*|'```sh'*|'```shell'*) in_block=1 ;;
                        *) in_block=0 ;;
                    esac
                fi
                continue
                ;;
        esac

        [ "$in_block" -eq 1 ] || continue
        # комментарии внутри блока не исполняются — пропускаем
        case "$trimmed" in '#'*) continue ;; esac

        for rule in "${RULES[@]}"; do
            re="${rule%%@@*}"
            rest="${rule#*@@}"
            name="${rest%%@@*}"
            rest="${rest#*@@}"
            why="${rest%%@@*}"
            fix="${rest#*@@}"

            if printf '%s' "$line" | grep -Eq "$re"; then
                rel="${file#"$ROOT"/}"
                printf '❌ %s:%s — %s\n' "$rel" "$lineno" "$name" >&2
                printf '   %s\n' "$trimmed" >&2
                printf '   почему: %s\n' "$why" >&2
                printf '   как чинить: %s\n\n' "$fix" >&2
                TOTAL_HITS=$((TOTAL_HITS + 1))
            fi
        done
    done < "$file"
done

if [ "$TOTAL_HITS" -eq 0 ]; then
    echo "✅ переносимость inline-кода: чисто (проверено файлов: $SCANNED)"
    exit 0
fi

{
    echo "🔴 непереносимых конструкций: $TOTAL_HITS (файлов проверено: $SCANNED)"
    echo
    echo "Эти строки агент вставит в оболочку ОПЕРАТОРА, а на macOS это zsh."
    echo "Скрипты *.sh не проверяются — у них шебанг bash, им bash-конструкции можно."
    echo "Обход в исключительном случае (НЕ по привычке): git commit --no-verify"
} >&2
exit 1
