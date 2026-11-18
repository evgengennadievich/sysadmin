#!/usr/bin/env bash
# run-evals.sh — прогон контрольных фраз. Движок по умолчанию: Codex.
#
# Запускает установленные CLI. Оценка числа вызовов доступна без CLI и без модели.
# См. ADR-0004 и ADR-0042.
#
# Использование:
#   ./scripts/run-evals.sh <skill-name>      # прогон одного скилла
#   ./scripts/run-evals.sh --all              # прогон всех скиллов
#   ./scripts/run-evals.sh --estimate         # только подсчитать число вызовов (без запроса)
#   ./scripts/run-evals.sh --all --positive-only  # только positive (дешевле прогон)
#   ./scripts/run-evals.sh --all --sample 1  # по одной фразе каждого типа на скилл
#
# Выход:
#   0 — все проверки прошли
#   1 — есть ошибки (отчёт всё равно записан)
#   2 — ошибка использования / окружения
#
# Запускать строго из корня репо sysadmin/. Скрипт сам проверит это.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/.claude/skills"
RESULTS_DIR="$REPO_ROOT/.eval-results"
HELPER_PARSE="$REPO_ROOT/scripts/eval-helpers/parse-triggers.sh"
HELPER_INVOKE="$REPO_ROOT/scripts/eval-helpers/invoke-claude.sh"
# Движок диспетчера (ADR-0042).
EVAL_ENGINE="${EVAL_ENGINE:-codex}"
case "$EVAL_ENGINE" in
    claude) ;;
    codex)
        SKILLS_DIR="$REPO_ROOT/.agents/skills"
        HELPER_INVOKE="$REPO_ROOT/scripts/eval-helpers/invoke-codex.sh"
        ;;
    *) echo "error: EVAL_ENGINE должен быть claude или codex" >&2; exit 2 ;;
esac

# --- Парсинг аргументов ----------------------------------------------------

MODE=""                # one-skill | all
TARGET_SKILL=""        # имя одного скилла, если MODE=one-skill
ESTIMATE_ONLY=0        # 1 — только сосчитать вызовы, не делать запросы
POSITIVE_ONLY=0        # 1 — пропустить negative и edge
SAMPLE_N=0             # >0 — взять первые N фраз каждого типа из каждого скилла

if [[ $# -eq 0 ]]; then
    cat <<EOF >&2
usage: $0 <skill-name>             — прогнать одного скилла
       $0 --all                     — прогнать все скиллы
       $0 --estimate                — оценить количество вызовов
       добавь --positive-only       — только positive-фразы (дешевле)
       добавь --sample N            — первые N фраз каждого типа (smoke)
EOF
    exit 2
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)            MODE="all" ;;
        --estimate)       ESTIMATE_ONLY=1 ;;
        --positive-only)  POSITIVE_ONLY=1 ;;
        --sample)
            if [[ ! "${2:-}" =~ ^[1-9][0-9]*$ ]]; then
                echo "error: --sample ожидает положительное целое число" >&2
                exit 2
            fi
            SAMPLE_N="$2"
            shift
            ;;
        -h|--help)        sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        --*)              echo "unknown flag: $1" >&2; exit 2 ;;
        *)
            if [[ -z "$MODE" ]]; then
                MODE="one-skill"
                TARGET_SKILL="$1"
            else
                echo "extra argument: $1" >&2; exit 2
            fi
            ;;
    esac
    shift
done

if [[ -z "$MODE" ]]; then
    MODE="all"  # --estimate без других аргументов = all + estimate
fi

# --- Проверки окружения ----------------------------------------------------

[[ -x "$HELPER_PARSE" ]]  || { echo "error: $HELPER_PARSE not executable" >&2; exit 2; }
cd "$REPO_ROOT"

# --- Собираем список скиллов ----------------------------------------------

SKILL_LIST=()
if [[ "$MODE" == "all" ]]; then
    for d in "$SKILLS_DIR"/*/; do
        skill_name=$(basename "$d")
        [[ -f "$d/evals/triggers.md" ]] && SKILL_LIST+=("$skill_name")
    done
else
    [[ -d "$SKILLS_DIR/$TARGET_SKILL" ]] || { echo "error: skill not found: $TARGET_SKILL" >&2; exit 2; }
    [[ -f "$SKILLS_DIR/$TARGET_SKILL/evals/triggers.md" ]] || {
        echo "error: no evals/triggers.md in $TARGET_SKILL" >&2; exit 2;
    }
    SKILL_LIST=("$TARGET_SKILL")
fi

[[ ${#SKILL_LIST[@]} -gt 0 ]] || { echo "error: no skills with triggers.md found" >&2; exit 2; }

# --- Подсчёт вызовов (estimate) -------------------------------------------

total_calls=0
# bash 3.2 на macOS не поддерживает ассоциативные массивы → параллельные.
PER_SKILL_NAMES=()
PER_SKILL_COUNTS=()

for skill in "${SKILL_LIST[@]}"; do
    n=0
    pos=0; neg=0; edg=0
    while IFS=$'\t' read -r kind _phrase; do
        case "$kind" in
            positive)
                if [[ $SAMPLE_N -gt 0 ]] && [[ $pos -ge $SAMPLE_N ]]; then continue; fi
                pos=$((pos+1)); n=$((n+1))
                ;;
            negative)
                [[ "$POSITIVE_ONLY" -eq 1 ]] && continue
                if [[ $SAMPLE_N -gt 0 ]] && [[ $neg -ge $SAMPLE_N ]]; then continue; fi
                neg=$((neg+1)); n=$((n+1))
                ;;
            edge)
                [[ "$POSITIVE_ONLY" -eq 1 ]] && continue
                if [[ $SAMPLE_N -gt 0 ]] && [[ $edg -ge $SAMPLE_N ]]; then continue; fi
                edg=$((edg+1)); n=$((n+1))
                ;;
        esac
    done < <("$HELPER_PARSE" "$SKILLS_DIR/$skill/evals/triggers.md")
    PER_SKILL_NAMES+=("$skill")
    PER_SKILL_COUNTS+=("$n")
    total_calls=$((total_calls + n))
done

if [[ "$ESTIMATE_ONLY" -eq 1 ]]; then
    echo "Оценка для $EVAL_ENGINE: $total_calls вызовов"
    echo
    echo "Разбивка по скиллам:"
    for i in "${!PER_SKILL_NAMES[@]}"; do
        printf "  %-30s %d\n" "${PER_SKILL_NAMES[$i]}" "${PER_SKILL_COUNTS[$i]}"
    done
    exit 0
fi

# --- Прогон ----------------------------------------------------------------

[[ -x "$HELPER_INVOKE" ]] || { echo "error: $HELPER_INVOKE not executable" >&2; exit 2; }
command -v "$EVAL_ENGINE" >/dev/null 2>&1 || { echo "error: $EVAL_ENGINE CLI not in PATH" >&2; exit 2; }
if [[ "$EVAL_ENGINE" == "claude" ]] && ! command -v jq >/dev/null 2>&1; then
    echo "error: jq not installed" >&2
    exit 2
fi
mkdir -p "$RESULTS_DIR"
TS=$(date -u +%Y%m%dT%H%M%SZ)
REPORT="$RESULTS_DIR/$TS-$EVAL_ENGINE.md"

# Шапка отчёта
{
    echo "# Eval Run $TS"
    echo
    echo "**Engine:** $EVAL_ENGINE  "
    echo "**Mode:** $MODE  "
    echo "**Skills:** ${#SKILL_LIST[@]}  "
    echo "**Planned calls:** $total_calls  "
    if [[ "$POSITIVE_ONLY" -eq 1 ]]; then
        echo "**Filter:** positive-only"
    fi
    echo
    echo "---"
    echo
} > "$REPORT"

total_ok=0
total_fail=0
total_cost=0
fail_lines=()

for skill in "${SKILL_LIST[@]}"; do
    {
        echo "## /$skill"
        echo
        echo "| Verdict | Kind | Phrase | Got | Expected |"
        echo "|---|---|---|---|---|"
    } >> "$REPORT"

    pos=0; neg=0; edg=0
    while IFS=$'\t' read -r kind phrase; do
        if [[ "$kind" != "positive" ]] && [[ "$POSITIVE_ONLY" -eq 1 ]]; then
            continue
        fi

        # Применяем sample
        case "$kind" in
            positive)
                if [[ $SAMPLE_N -gt 0 ]] && [[ $pos -ge $SAMPLE_N ]]; then continue; fi
                pos=$((pos+1))
                ;;
            negative)
                if [[ $SAMPLE_N -gt 0 ]] && [[ $neg -ge $SAMPLE_N ]]; then continue; fi
                neg=$((neg+1))
                ;;
            edge)
                if [[ $SAMPLE_N -gt 0 ]] && [[ $edg -ge $SAMPLE_N ]]; then continue; fi
                edg=$((edg+1))
                ;;
        esac

        # --- ожидание -----
        # positive → должно совпасть с $skill
        # negative → должно НЕ совпасть с $skill (может быть none или любой другой)
        # edge     → диагностический, формально считается успехом если модель
        #            хотя бы попыталась (не пустой ответ) — фактическую правильность
        #            оценивает человек по содержимому Got
        expected=""
        case "$kind" in
            positive) expected="$skill" ;;
            negative) expected="!= $skill" ;;
            edge)     expected="(human review)" ;;
        esac

        # --- вызов -----
        if out=$("$HELPER_INVOKE" "$phrase"); then
            got=$(echo "$out" | awk -F'|' '{print $1}')
            cost=$(echo "$out" | awk -F'|' '{print $2}')
            total_cost=$(awk "BEGIN { printf \"%.4f\", $total_cost + $cost }")
        else
            got="ERROR"
            cost=0
        fi

        # --- вердикт -----
        verdict="❌"
        case "$kind" in
            positive)
                [[ "$got" == "$skill" ]] && verdict="✅"
                ;;
            negative)
                [[ "$got" != "$skill" ]] && [[ "$got" != "ERROR" ]] && verdict="✅"
                ;;
            edge)
                [[ "$got" != "ERROR" ]] && verdict="🟡"  # человеческая ревизия
                ;;
        esac

        if [[ "$verdict" == "✅" ]] || [[ "$verdict" == "🟡" ]]; then
            total_ok=$((total_ok + 1))
        else
            total_fail=$((total_fail + 1))
            fail_lines+=("$skill | $kind | $phrase | got=$got | expected=$expected")
        fi

        # Экранируем `|` в фразе, чтобы не сломать markdown-таблицу
        phrase_safe="${phrase//|/\\|}"
        echo "| $verdict | $kind | $phrase_safe | $got | $expected |" >> "$REPORT"

    done < <("$HELPER_PARSE" "$SKILLS_DIR/$skill/evals/triggers.md")

    echo >> "$REPORT"
done

# Итоговая сводка
{
    echo "---"
    echo
    echo "## Итог"
    echo
    echo "- ✅ / 🟡 успехов: **$total_ok**"
    echo "- ❌ провалов: **$total_fail**"
    if [[ "$EVAL_ENGINE" == "claude" ]]; then
        echo "- 💰 суммарная стоимость по данным CLI: **\$$total_cost**"
    else
        echo "- Стоимость в долларах недоступна в отчёте Codex."
    fi
    echo
    if [[ ${#fail_lines[@]} -gt 0 ]]; then
        echo "### Расхождения и ошибки прогона"
        echo
        echo "ERROR означает сбой запуска или формата ответа. Выбор скилла в таком случае не оценён."
        echo
        for line in "${fail_lines[@]}"; do
            echo "- $line"
        done
    fi
} >> "$REPORT"

# Краткое резюме в stdout
echo "Report: $REPORT"
echo "OK/PARTIAL: $total_ok   FAIL: $total_fail"

[[ $total_fail -eq 0 ]] || exit 1
exit 0
