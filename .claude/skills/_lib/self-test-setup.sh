#!/usr/bin/env bash
# self-test-setup.sh — финальная самопроверка после настройки агента.
#
# Принцип (feedback Василия 2026-05-24): «не смог — скажи прямо». В конце /sysadmin-init
# (и при желании других setup-скиллов) прогоняем РЕАЛЬНЫЙ тест, что всё работает. Если
# хоть что-то не так — печатаем понятный новичку вердикт и возвращаем 1. Вызывающий скилл
# НЕ должен говорить «Готово», если этот тест не прошёл.
#
# Что проверяем (всё — на реально записанном конфиге, не на черновике):
#   1. bash и jq доступны и работают.
#   2. CONFIG_PATH существует и читается.
#   3. Это валидный JSON (jq empty).
#   4. Проходит JSON Schema (validate-config.sh).
#   5. Папка инфры проекта существует (ADR-0013: projects[].infra_root в мозге,
#      либо legacy .infrastructure.root_path в старом всё-в-одном конфиге).
#   6. bridge-файл ~/.claude/agents/sysadmin.md на месте (агент вызываем из любой папки).
#
# Использование (ADR-0013 — ДВА файла):
#   source "<...>/_lib/self-test-setup.sh"
#   self_test_setup "$AGENT_CONFIG_PATH" "$SYSADMIN_ROOT" "$INFRA_CONFIG_PATH"
#   # $3 (infra-config.json) — опционален: если не передан, путь берётся из projects[].
#   # Совместимость: можно передать и старый одиночный sysadmin-config.json как $1.
#   # rc=0 — всё ок (можно печатать «Готово»); rc=1 — вердикт уже выведен, НЕ говори «Готово».

[ -n "${_SYSADMIN_SELFTEST_LOADED:-}" ] && return 0
_SYSADMIN_SELFTEST_LOADED=1

# Подключаем единый резолвер пути к инфре (resolve_infra_path).
# Канон fix v1.4.2: относительный root_path резолвится от каталога конфига,
# а не от cwd процесса — иначе self-test ложно проваливается на «../infra».
_stp_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=find-config.sh
[ -f "$_stp_script_dir/find-config.sh" ] && . "$_stp_script_dir/find-config.sh"

# Печатает честный вердикт-провал понятным новичку языком.
# $1 — список конкретных проблем (многострочный).
_setup_failure_verdict() {
    local problems="$1"
    cat <<EOF

────────────────────────────────────────────────────────────
⚠️  НАСТРОЙКА НЕ ЗАВЕРШЕНА — агент сейчас работать НЕ будет.

Я честно проверил результат и кое-что не получилось:

$problems

Что делать: НЕ продолжай работу с агентом в таком состоянии — он
будет вести себя непредсказуемо. Открой issue:
https://github.com/vefmvai/sysadmin/issues — приложи вывод
'bash scripts/collect-diagnostics.sh' (обезличен, без секретов) и
это сообщение. Это не твоя ошибка: что-то в окружении/установке
требует ручного разбора.
────────────────────────────────────────────────────────────
EOF
}

# Главная функция. $1 = CONFIG_PATH (agent-config.json или legacy sysadmin-config.json),
# $2 = SYSADMIN_ROOT, $3 = INFRA_CONFIG_PATH (опц., infra-config.json активного проекта).
# Возврат: 0 — всё работает; 1 — есть проблемы (вердикт напечатан).
self_test_setup() {
    local config_path="$1"
    local sysadmin_root="$2"
    local infra_config_path="${3:-}"
    local problems=""
    # helper: дописать проблему в список (bash не умеет local-функции, поэтому через переменную)
    _stp_add() { problems="${problems}  • $1"$'\n'; }

    # Определяем «вид» переданного $1: новый мозг (agent-config) или legacy всё-в-одном.
    local is_brain="false"
    case "$config_path" in
        *agent-config*) is_brain="true" ;;
    esac

    # 1. bash + jq
    # Проверяем НАЛИЧИЕ бинарника bash, а не $BASH_VERSION текущего процесса — Claude Code
    # гоняет команды через дефолтный шелл оператора (на macOS это часто zsh), где
    # $BASH_VERSION пуста даже при установленном и рабочем bash.
    command -v bash >/dev/null 2>&1 || _stp_add "Нет bash (оболочка не bash — нужен Git Bash на Windows)."
    if command -v jq >/dev/null 2>&1; then :; else
        _stp_add "Утилита jq недоступна — без неё конфиг не читается. Установка jq не удалась."
    fi

    # 2. CONFIG_PATH существует и читается
    if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
        _stp_add "Файл конфига не создан (ожидался: ${config_path:-<путь не задан>})."
    else
        # 3. валидный JSON
        if command -v jq >/dev/null 2>&1 && ! jq empty "$config_path" >/dev/null 2>&1; then
            _stp_add "Файл конфига есть, но это не валидный JSON (повреждён при записи)."
        fi
        # 4. JSON Schema — validate-config.sh сам определит схему по имени файла.
        local validator="$sysadmin_root/.claude/skills/sysadmin-init/scripts/validate-config.sh"
        if [ -f "$validator" ]; then
            if ! bash "$validator" "$config_path" >/dev/null 2>&1; then
                _stp_add "Конфиг не проходит проверку по схеме (какое-то поле заполнено неверно)."
            fi
            # Если передан второй файл (infra-config) — валидируем и его.
            if [ -n "$infra_config_path" ] && [ -f "$infra_config_path" ]; then
                if ! bash "$validator" "$infra_config_path" >/dev/null 2>&1; then
                    _stp_add "Конфиг инфры не проходит проверку по схеме: $infra_config_path"
                fi
            fi
        fi
        # 5. папка инфры проекта существует.
        if command -v jq >/dev/null 2>&1; then
            local raw infra
            if [ "$is_brain" = "true" ]; then
                # ADR-0013: путь к инфре — в projects[]. Берём проект default_project.
                local def
                def="$(jq -r '.default_project // empty' "$config_path" 2>/dev/null)"
                if [ -n "$def" ]; then
                    raw="$(jq -r --arg id "$def" '.projects[]? | select(.id==$id) | .infra_root // empty' "$config_path" 2>/dev/null)"
                fi
            else
                # legacy всё-в-одном — старое поле.
                raw="$(jq -r '.infrastructure.root_path // empty' "$config_path" 2>/dev/null)"
            fi
            if [ -n "$raw" ]; then
                if command -v resolve_infra_path >/dev/null 2>&1; then
                    # resolve_infra_path печатает абсолютный путь; rc=1 если папки нет.
                    if ! infra="$(resolve_infra_path "$raw" "$config_path")"; then
                        _stp_add "Папка инфраструктуры не создана: $raw → $infra (агенту некуда писать inventory)."
                    fi
                else
                    # Fallback, если резолвер не подгрузился: хотя бы tilde + от каталога конфига.
                    infra="${raw/#\~/$HOME}"
                    case "$infra" in
                        /*|[A-Za-z]:[\\/]*) : ;;  # абсолютный — как есть
                        *) infra="$(cd "$(dirname "$config_path")" 2>/dev/null && cd "$infra" 2>/dev/null && pwd)" ;;
                    esac
                    if [ -z "$infra" ] || [ ! -d "$infra" ]; then
                        _stp_add "Папка инфраструктуры не создана: $raw (агенту некуда писать inventory)."
                    fi
                fi
            fi
        fi
    fi

    # 6. bridge-файл
    if [ ! -f "$HOME/.claude/agents/sysadmin.md" ]; then
        _stp_add "Нет bridge-файла ~/.claude/agents/sysadmin.md — @sysadmin не вызвать из других папок."
    fi

    if [ -n "$problems" ]; then
        _setup_failure_verdict "$problems"
        return 1
    fi

    cat <<EOF

✅ Самопроверка пройдена — всё на месте и работает:
   • bash + jq: OK
   • конфиг(и) записан(ы) и валиден(ы): $config_path${infra_config_path:+ + $infra_config_path}
   • папка инфраструктуры существует
   • bridge-файл на месте (@sysadmin доступен из любой папки)
EOF
    return 0
}
