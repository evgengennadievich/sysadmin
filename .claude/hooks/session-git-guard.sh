#!/usr/bin/env bash
# Замок общей рабочей копии нескольких сессий агента (ADR-0041).
#
# Вешается на PreToolUse и PostToolUse инструмента Bash (.claude/settings.json). Не даёт
# отправить (`git push`) чужие коммиты без фразы оператора, не даёт закоммитить чужие файлы
# из общего индекса и останавливает коммит строк, которых эта сессия не писала, до явной
# пометки. После `git commit` записывает новые коммиты сессии. Логика целиком в
# session-git-guard.py рядом; здесь только быстрый отсев и запуск.
#
# Ручная проверка: bash .claude/hooks/tests/test-session-git-guard.sh

set -uo pipefail

RAW="$(cat)"
# Быстрый отсев: команды без git не трогаем, python не запускаем.
case "$RAW" in
  *git*) ;;
  *) exit 0 ;;
esac

# Граница (ADR-0041): без python3 замок не работает. Молчание здесь осознанное и записано,
# а не случайное: остальные замки мозга тоже опираются на python3.
command -v python3 >/dev/null 2>&1 || exit 0

HERE="$(cd "$(dirname "$0")" && pwd)"
printf '%s' "$RAW" | python3 -I "${HERE}/session-git-guard.py"
