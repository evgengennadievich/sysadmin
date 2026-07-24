#!/usr/bin/env bash
# Тесты гейта находок /retro (ADR-0021). Прогон: bash .claude/hooks/tests/test-retro-finding-gate.sh
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/.." && pwd)/retro-finding-gate.sh"
PASS=0; FAIL=0

run() { # $1 = file_path, $2 = текст правки, $3 = поле (new_string|content)
  python3 - "$1" "$2" "${3:-new_string}" <<'PY' | bash "$HOOK"
import json, sys
print(json.dumps({"tool_name": "Edit", "tool_input": {"file_path": sys.argv[1], sys.argv[3]: sys.argv[2]}}, ensure_ascii=False))
PY
}

check() { # $1 = allow|deny, $2 = описание, $3 = path, $4 = текст, $5 = поле
  local out; out="$(run "$3" "$4" "${5:-new_string}")"
  local got="allow"; printf '%s' "$out" | grep -q '"permissionDecision": *"deny"' && got="deny"
  if [ "$got" = "$1" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$2"
  else FAIL=$((FAIL+1)); printf '  ❌ %s — ожидали %s, получили %s\n' "$2" "$1" "$got"; fi
}

B="/repo/retro/BACKLOG.md"
OK_FACT='| 2026-07-24 | MUST | скиллы | факт | скилл выдал ложный drift | чинить парсер | open |'
OK_HYPO='| 2026-07-24 | MAY | персона | гипотеза | возможно, рефлекс не сработал | проверить на след. сессии | open |'
NO_BASIS='| 2026-07-24 | MUST | скиллы | агент сломал оператору рабочий VPN | откатить | open |'
HISTORIC='| 2026-06-14 | MUST | скиллы | старая находка без основания | предложение | done (fix abc123) |'
HEADER='| Дата | Severity | Фронт | Основание | Находка | Предложение | Статус |
|------|----------|-------|----------|---------|-------------|--------|'

echo "── Тесты гейта находок /retro ───────────────────────────"
echo "[1] Посторонние файлы гейт не трогает"
check allow "правка README"            "/repo/README.md"        "$NO_BASIS"
check allow "правка другого бэклога"   "/repo/docs/BACKLOG.md"  "$NO_BASIS"

echo "[2] Корректные находки проходят"
check allow "основание «факт»"         "$B" "$OK_FACT"
check allow "основание «гипотеза»"     "$B" "$OK_HYPO"
check allow "шапка и разделитель"      "$B" "$HEADER"
check allow "историческая строка done" "$B" "$HISTORIC"
check allow "обычный текст без таблиц" "$B" "## Раздел про находки, open вопросы"

echo "[3] Находка без основания блокируется"
check deny  "нет ни факта, ни гипотезы" "$B" "$NO_BASIS"
check deny  "среди корректных затесалась плохая" "$B" "$OK_FACT
$NO_BASIS"
check deny  "полная перезапись файла (content)"  "$B" "$HEADER
$NO_BASIS" content

echo "[4] Относительный путь тоже под гейтом"
check deny  "retro/BACKLOG.md без префикса" "retro/BACKLOG.md" "$NO_BASIS"

echo "─────────────────────────────────────────────────────────"
printf 'Итог: %d прошло, %d провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
