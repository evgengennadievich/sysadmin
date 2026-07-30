#!/usr/bin/env bash
# Регрессионный тест: снимок собирается на хосте БЕЗ Docker (ADR-0024).
# До правки dump-snapshot.sh делал fail-fast «Docker не найден → exit 1», и нативные
# VPS (VPN-сервер с 3X-UI + nginx, одиночный сервис) вообще не могли получить inventory.
#
# Прогон: bash .claude/skills/inventory-scan/tests/test-native-host.sh
# Работает локально: «хост без Docker» имитируется урезанным PATH, снимок пишется
# во временный каталог. Сервер не трогается — тест read-only и офлайновый.

set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/dump-snapshot.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ❌ $1"; }

CLEAN_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
if PATH="$CLEAN_PATH" command -v docker >/dev/null 2>&1; then
  echo "ПРОПУСК: docker виден даже в урезанном PATH — имитация нативного хоста невозможна."
  exit 0
fi

echo "── Снимок на хосте без Docker (ADR-0024) ────────────────"
PATH="$CLEAN_PATH" bash "$SCRIPT" local today "$WORK/inv" > "$WORK/run.log" 2>&1
CODE=$?
[ "$CODE" -eq 0 ] && ok "скрипт завершился успешно (раньше здесь был exit 1)" \
                  || no "скрипт упал с кодом $CODE: $(tail -3 "$WORK/run.log")"

SNAP="$(find "$WORK/inv" -type d -path '*/snapshots/*' | head -1)"
[ -n "$SNAP" ] && ok "каталог снимка создан" || { no "каталог снимка не создан"; exit 1; }

N=$(find "$SNAP" -maxdepth 1 -type f ! -name '*.err' | wc -l | tr -d ' ')
[ "$N" -ge 20 ] && ok "файлов снимка: $N (ожидали ≥20)" || no "файлов только $N, ожидали ≥20"

grep -q 'host_kind: native' "$SNAP/meta.txt" && ok "meta.txt: host_kind=native" || no "meta.txt без host_kind=native"
grep -q 'has_docker: no'    "$SNAP/meta.txt" && ok "meta.txt: has_docker=no"    || no "meta.txt без has_docker=no"

# Секции контейнеров: файлы ЕСТЬ (иначе verify сочтёт снимок битым), но честно помечены.
for f in containers.txt compose-files.txt networks.txt volumes.txt; do
  head -1 "$SNAP/$f" 2>/dev/null | grep -q '^NOT_APPLICABLE:' \
    && ok "$f помечен NOT_APPLICABLE" || no "$f без маркера"
done
[ "$(cat "$SNAP/containers-inspect.json")" = "[]" ] && ok "containers-inspect.json = []" \
  || no "containers-inspect.json не пустой массив"

# Ради чего всё затевалось: нативные источники состояния собраны.
for f in firewall.txt host-resources.txt nginx-sites.txt tls-certs.txt systemd-enabled.txt \
         host-services.txt systemd-timers.txt crontab.txt health-flags.txt watchers.txt; do
  [ -f "$SNAP/$f" ] && ok "секция собрана: $f" || no "секция отсутствует: $f"
done

grep -q 'exited_containers=n/a' "$SNAP/health-flags.txt" \
  && ok "health-flags: контейнерные метрики помечены n/a" \
  || no "health-flags: нет пометки n/a"

echo "─────────────────────────────────────────────────────────"
printf 'Итог: %d прошло, %d провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { echo "--- хвост лога ---"; tail -20 "$WORK/run.log"; exit 1; }
