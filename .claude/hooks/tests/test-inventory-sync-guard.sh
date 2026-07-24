#!/usr/bin/env bash
# Тесты Stop-хука «инвентарь не отстаёт» (§3.2, ADR-0023).
# Прогон: bash .claude/hooks/tests/test-inventory-sync-guard.sh
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/.." && pwd)/inventory-sync-guard.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Метки предохранителя кладём в свой TMPDIR: иначе они переживают прогон и следующий
# запуск тестов «пропускает» блокировки (метка = один блок на ход). Заодно не задеваем
# метки живой сессии.
MARKS="$TMP/marks"; mkdir -p "$MARKS"
PASS=0; FAIL=0

# Собираем транскрипт: реплика оператора + перечисленные вызовы инструментов.
mk() { # $1 = файл, далее пары "Bash:команда" / "Edit:путь"
  local out="$1"; shift
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"почини сервис"}}'
    for spec in "$@"; do
      local tool="${spec%%:*}" arg="${spec#*:}"
      python3 - "$tool" "$arg" <<'PY'
import json, sys
tool, arg = sys.argv[1], sys.argv[2]
inp = {"command": arg} if tool == "Bash" else {"file_path": arg, "new_string": "x"}
print(json.dumps({"type":"assistant","message":{"role":"assistant","content":[
  {"type":"tool_use","name":tool,"input":inp}]}}, ensure_ascii=False))
PY
    done
  } > "$out"
}

run() { # $1 = транскрипт, $2 = stop_hook_active (true|false)
  python3 - "$1" "${2:-false}" <<'PY' | TMPDIR="$MARKS" bash "$HOOK"
import json, sys, os
# session_id стабилен между запусками (hash() в Python рандомизирован — метку бы не нашли).
print(json.dumps({"session_id": os.path.basename(sys.argv[1]), "cwd": "/tmp/p",
                  "transcript_path": sys.argv[1],
                  "stop_hook_active": sys.argv[2] == "true"}, ensure_ascii=False))
PY
}

check() { # $1 = block|pass, $2 = описание, $3 = транскрипт, $4 = stop_hook_active
  local out; out="$(run "$3" "${4:-false}")"
  local got="pass"; printf '%s' "$out" | grep -q '"decision": *"block"' && got="block"
  if [ "$got" = "$1" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$2"
  else FAIL=$((FAIL+1)); printf '  ❌ %s — ожидали %s, получили %s\n' "$2" "$1" "$got"; fi
}

echo "── Тесты Stop-хука «инвентарь не отстаёт» ───────────────"

echo "[1] Диагностика без изменений — не трогаем"
mk "$TMP/ro.jsonl" "Bash:docker ps -a" "Bash:systemctl status nginx" "Bash:df -h"
check pass "read-only команды" "$TMP/ro.jsonl"

echo "[2] Изменение без обновления inventory — останавливаем"
mk "$TMP/change1.jsonl" "Bash:ssh bronto 'docker compose up -d academii'"
check block "docker compose up" "$TMP/change1.jsonl"
mk "$TMP/change2.jsonl" "Bash:ssh bronto 'systemctl restart nginx'"
check block "systemctl restart" "$TMP/change2.jsonl"
mk "$TMP/change3.jsonl" "Bash:ssh bronto 'ufw allow 8443'"
check block "правило firewall" "$TMP/change3.jsonl"
mk "$TMP/change4.jsonl" "Bash:ssh bronto 'docker network create services'"
check block "новая сеть" "$TMP/change4.jsonl"

echo "[3] Изменение + обновление inventory — пропускаем"
mk "$TMP/ok1.jsonl" "Bash:ssh bronto 'docker compose up -d'" "Edit:/infra/inventory/hosts/bronto/services.md"
check pass "правка inventory в том же ходе" "$TMP/ok1.jsonl"
mk "$TMP/ok2.jsonl" "Bash:ssh bronto 'systemctl restart nginx'" "Bash:ssh bronto '/opt/infra-dashboard/bin/refresh.sh'"
check pass "пересборка снимка/дашборда" "$TMP/ok2.jsonl"
mk "$TMP/ok3.jsonl" "Bash:ssh bronto 'docker compose up -d'" "Bash:bash scripts/dump-snapshot.sh bronto"
check pass "пересъёмка снимка" "$TMP/ok3.jsonl"

echo "[4] Защита от зацикливания"
mk "$TMP/loop.jsonl" "Bash:ssh bronto 'docker compose restart api'"
check block "первый раз останавливаем" "$TMP/loop.jsonl"
check pass  "второй раз тот же ход — пропускаем (метка)" "$TMP/loop.jsonl"
mk "$TMP/loop2.jsonl" "Bash:ssh bronto 'docker compose restart web'"
check pass  "stop_hook_active=true — пропускаем" "$TMP/loop2.jsonl" true

echo "[5] Fail-open: непонятный вход не мешает работе"
printf 'не json' | TMPDIR="$MARKS" bash "$HOOK" >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "  ✅ мусор на входе"; } \
  || { FAIL=$((FAIL+1)); echo "  ❌ мусор на входе уронил хук"; }
echo '{"session_id":"x","transcript_path":"/nope/none.jsonl"}' | TMPDIR="$MARKS" bash "$HOOK" >/dev/null 2>&1 \
  && { PASS=$((PASS+1)); echo "  ✅ транскрипта нет"; } || { FAIL=$((FAIL+1)); echo "  ❌ упал без транскрипта"; }

echo "─────────────────────────────────────────────────────────"
printf 'Итог: %d прошло, %d провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
