#!/usr/bin/env bash
# Регрессионные тесты security-audit.sh.
#
# Что они стерегут. У этого скрипта есть один класс дефектов, который нельзя
# поймать чтением кода и который дважды туда возвращался: проверка не
# выполнилась, но её пустой результат прочитан как вывод. Наружу это выходит
# как «PASS» там, где не проверялось ничего, — то есть как спокойствие без
# основания. Такое видно ТОЛЬКО в связке «логика скрипта + поведение удалённой
# команды», поэтому тесты подменяют сам транспорт (evals/stub-bin/ssh) и
# серверные утилиты заглушками с заданным поведением.
#
# Запуск:  bash evals/run-tests.sh
# Выход:   0 — все проверки прошли, 1 — есть провалившиеся.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/security-audit.sh"
export STUB_BIN="$HERE/stub-bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export STUB_FIX="$WORK/fix"

TOTAL=0; FAILED=0

# --- фикстуры создаются на прогоне ------------------------------------------
# В репозиторий они не кладутся сознательно: файлы с именем .env в дереве
# инструмента, который сам же ищет утечки секретов, — плохая идея.
mkdir -p "$STUB_FIX/sudoers.d" "$WORK/srv-mixed/app1" "$WORK/srv-mixed/app2" "$WORK/srv-clean/app1"
printf 'root ALL=(ALL:ALL) ALL\n%%sudo ALL=(ALL:ALL) ALL\n' > "$STUB_FIX/sudoers"
printf '# без правил NOPASSWD\n' > "$STUB_FIX/sudoers.d/README"
printf 'SECRET=x\n' > "$WORK/srv-mixed/app1/.env"; chmod 600 "$WORK/srv-mixed/app1/.env"
printf 'SECRET=x\n' > "$WORK/srv-mixed/app2/.env"; chmod 644 "$WORK/srv-mixed/app2/.env"
printf 'SECRET=x\n' > "$WORK/srv-clean/app1/.env"; chmod 600 "$WORK/srv-clean/app1/.env"

# run_audit ИМЯ_ОТЧЁТА [доп. аргументы скрипта]
run_audit() {
    local name="$1"; shift
    PATH="$STUB_BIN:$PATH" bash "$SCRIPT" \
        --server stub@test "$@" \
        --output "$WORK/$name.md" >"$WORK/$name.log" 2>&1
    echo $?
}

# expect_row ОТЧЁТ "ПРОВЕРКА" "ОЖИДАЕМЫЙ_СТАТУС" "пояснение зачем"
expect_row() {
    local file="$WORK/$1.md" check="$2" want="$3" why="$4"
    TOTAL=$((TOTAL + 1))
    local got
    got=$(grep -F "| $check |" "$file" 2>/dev/null | head -1 | awk -F'|' '{gsub(/ /,"",$3); print $3}')
    if [ "$got" = "$want" ]; then
        printf '  ✅ %-34s %s\n' "$check" "$want"
    else
        FAILED=$((FAILED + 1))
        printf '  ❌ %-34s ожидали %s, получили «%s»\n' "$check" "$want" "${got:-строки нет}"
        printf '     причина проверки: %s\n' "$why"
    fi
}

# expect_rc ФАКТ ОЖИДАНИЕ пояснение
expect_rc() {
    TOTAL=$((TOTAL + 1))
    if [ "$1" = "$2" ]; then
        printf '  ✅ код возврата %s\n' "$2"
    else
        FAILED=$((FAILED + 1))
        printf '  ❌ код возврата: ожидали %s, получили %s — %s\n' "$2" "$1" "$3"
    fi
}

# expect_absent ОТЧЁТ ПОДСТРОКА пояснение
expect_absent() {
    TOTAL=$((TOTAL + 1))
    if grep -qF "$2" "$WORK/$1.md" 2>/dev/null; then
        FAILED=$((FAILED + 1))
        printf '  ❌ в отчёте не должно быть «%s» — %s\n' "$2" "$3"
    else
        printf '  ✅ отсутствует: %s\n' "$2"
    fi
}

# expect_present ОТЧЁТ "ПОДСТРОКА" "пояснение зачем"
expect_present() {
    TOTAL=$((TOTAL + 1))
    if grep -qF "$2" "$WORK/$1.md" 2>/dev/null; then
        printf '  ✅ присутствует: %s\n' "$2"
    else
        FAILED=$((FAILED + 1))
        printf '  ❌ в отчёте нет «%s» — %s\n' "$2" "$3"
    fi
}

echo "=== Регрессионные тесты audit-security ==="
echo

# ---------------------------------------------------------------------------
echo "[1] sudo есть, правил NOPASSWD нет, группа docker с людьми"
RC=$(STUB_SUDO=allow STUB_GETENT=members STUB_SYSTEMCTL=active STUB_UFW=active \
     run_audit t1 --scope host)
expect_row t1 "sudo: правила NOPASSWD" PASS \
    "ветка PASS была НЕДОСТИЖИМА: grep без совпадений отдаёт код 1, и это считалось сбоем"
expect_row t1 "Группа docker" WARN \
    "члены группы docker имеют root без sudo — это должно быть видно"
expect_row t1 "UFW: состав правил" INFO \
    "перечень правил — справка, а не пройденная проверка; в зачёт идти не должен"
expect_row t1 "Внешние слушающие порты" INFO \
    "список портов сам по себе ничего не проверяет"
echo

# ---------------------------------------------------------------------------
echo "[2] sudo недоступен — root-проверки обязаны стать UNKNOWN, а не PASS/FAIL"
RC=$(STUB_SUDO=deny STUB_GETENT=members run_audit t2 --scope host)
expect_row t2 "sudo: правила NOPASSWD" UNKNOWN \
    "без root правила не прочитать — это отсутствие результата, а не «чисто»"
expect_row t2 "UFW активен" UNKNOWN \
    "нет прав — не путать с «firewall выключен» (была такая ложная тревога)"
expect_rc "$RC" 3 "есть непроверенное при отсутствии FAIL — выход не должен быть нулевым"
echo

# ---------------------------------------------------------------------------
echo "[3] getent отсутствует в системе — главный ложный PASS"
RC=$(STUB_SUDO=allow STUB_GETENT=missing run_audit t3 --scope host)
expect_row t3 "Группа docker" UNKNOWN \
    "конвейер getent|cut возвращал код cut (всегда 0) — пустой вывод читался как «группа пуста»"
echo

# ---------------------------------------------------------------------------
echo "[4] группы docker в системе нет — это законный PASS, не UNKNOWN"
RC=$(STUB_SUDO=allow STUB_GETENT=nogroup run_audit t4 --scope host)
expect_row t4 "Группа docker" PASS \
    "код 2 у getent означает «записи нет» — штатный ответ, а не сбой"
echo

# ---------------------------------------------------------------------------
echo "[5] systemctl отсутствует — состояние fail2ban неизвестно, а не «не запущен»"
RC=$(STUB_SUDO=allow STUB_SYSTEMCTL=missing run_audit t5 --scope host)
expect_row t5 "fail2ban" UNKNOWN \
    "пустой ответ давал FAIL «не запущен» — зеркало исходного дефекта"
echo

# ---------------------------------------------------------------------------
echo "[6] служба fail2ban действительно выключена — это FAIL"
RC=$(STUB_SUDO=allow STUB_SYSTEMCTL=inactive run_audit t6 --scope host)
expect_row t6 "fail2ban" FAIL \
    "настоящее нарушение обязано остаться нарушением"
expect_rc "$RC" 1 "при FAIL выход должен быть 1"
echo

# ---------------------------------------------------------------------------
echo "[7] права .env: нарушение находится, полнота не преувеличивается"
RC=$(STUB_SUDO=allow run_audit t7 --scope docker --env-paths "$WORK/srv-mixed")
expect_row t7 "Права .env" WARN \
    "файл 644 среди .env — секреты читает любой процесс системы"
RC=$(STUB_SUDO=allow run_audit t8 --scope docker --env-paths "$WORK/srv-clean")
expect_row t8 "Права .env" PASS \
    "поиск под root, нарушений нет — законный PASS"
RC=$(STUB_SUDO=deny run_audit t9 --scope docker --env-paths "$WORK/srv-clean")
expect_row t9 "Права .env" UNKNOWN \
    "без root find молча пропускает чужие каталоги — «все 600» утверждать нельзя"
echo

# ---------------------------------------------------------------------------
echo "[8] пустые пути .env не выдаются за проверенные"
RC=$(STUB_SUDO=allow run_audit t10 --scope docker --env-paths "$WORK/nonexistent")
expect_row t10 "Права .env" UNKNOWN \
    "ноль найденных файлов — это «проверять было нечего», а не «все файлы в порядке»"
expect_absent t10 "все mode 600" \
    "утверждение о правах при нуле найденных файлов — исходный дефект 2026-07-29"
echo

# ---------------------------------------------------------------------------
echo "[9] TLS: в проверку идут только домены из структуры, а не из прозы"
cat > "$WORK/domains.md" <<'DOC'
# Домены — фикстура теста

| домен | назначение |
|-------|------------|
| korp-podarki.ru | сайт |
| vpn.korp-podarki.ru | панель |

Reality-заглушка указывает на www.cloudflare.com, upstream живёт на
api.de.nurcloud.org. Пакеты тянутся с pypi.org, код лежит на github.com.
DOC
RC=$(STUB_SUDO=allow run_audit t11 --scope tls --domains-file "$WORK/domains.md")
expect_row t11 "korp-podarki.ru" UNKNOWN \
    "домен из таблицы обязан попасть в проверку"
expect_row t11 "vpn.korp-podarki.ru" UNKNOWN \
    "второй домен из таблицы тоже"
for foreign in github.com pypi.org www.cloudflare.com api.de.nurcloud.org; do
    expect_absent t11 "| $foreign |" \
        "чужой домен из прозы не должен попадать в проверку: это мусор в отчёте и соединение с третьим лицом от имени оператора"
done
echo

# ---------------------------------------------------------------------------
echo "[10] проверка, потерявшая источник данных, не исчезает из отчёта молча"
RC=$(STUB_SUDO=allow STUB_SSHD=missing run_audit t12 --scope host)
expect_row t12 "SSH: интерактивная аутентификация" UNKNOWN \
    "без sshd -T значение недоступно; прежде строка просто пропадала из отчёта — проверка отсутствовала бесшумно"
expect_row t12 "SSH: вход по паролю" UNKNOWN \
    "запасной путь (чтение файлов) на этой машине тоже ничего не даёт"
echo

# ---------------------------------------------------------------------------
echo "[11] ошибки вызова заметны, справка есть"
PATH="$STUB_BIN:$PATH" bash "$SCRIPT" --server stub@test --scope hosts >/dev/null 2>&1
expect_rc "$?" 2 "опечатка в --scope прежде давала пустой отчёт с кодом успеха"
PATH="$STUB_BIN:$PATH" bash "$SCRIPT" --help >/dev/null 2>&1
expect_rc "$?" 0 "--help должен работать без --server и без сервера"
echo

# ---------------------------------------------------------------------------
# Стережёт дефект, найденный 2026-07-30 при ручной верификации аудита: отчёт
# сообщал «проверялось с: рабочая машина оператора» при живом openssl на сервере.
# Причина — RC_MAX=0 у пробы s_client: ненулевой код openssl (законный ответ
# «сертификата на этом порту нет») читался как «проверка не состоялась», и скрипт
# молча уходил на локальный прогон. Вранья об источнике данных не видно из
# отчёта — оператор принимает решение по данным, полученным не оттуда, откуда
# думает. На Маке с включённым VPN-клиентом это уже приводило к ложным выводам.
echo "[12] TLS: источник проверки назван честно"
cat > "$WORK/domains-src.md" <<'DOC'
| домен | назначение |
|-------|------------|
| vpn.korp-podarki.ru | панель |
DOC

RC=$(STUB_SUDO=allow run_audit t13 --scope tls --domains-file "$WORK/domains-src.md")
expect_present t13 "проверялось с: сервер" \
    "openssl на сервере есть и отработал — ненулевой код s_client это ОТВЕТ, а не сбой; источником обязан быть сервер"
expect_absent t13 "рабочая машина оператора" \
    "откат на локальный прогон при живом openssl на сервере — это подмена источника данных"

RC=$(STUB_SUDO=allow STUB_OPENSSL=missing run_audit t14 --scope tls --domains-file "$WORK/domains-src.md")
expect_present t14 "проверялось с: рабочая машина оператора" \
    "openssl на сервере нет — откат законен, но обязан быть назван в отчёте"
expect_present t14 "openssl на сервере не найден" \
    "молчаливый откат недопустим: оператор должен узнать, что результат описывает путь с его машины, а не с сервера"
echo

echo "─────────────────────────────────────────"
if [ "$FAILED" -eq 0 ]; then
    echo "PASS — все проверки прошли ($TOTAL)"
    exit 0
fi
echo "FAIL — провалено $FAILED из $TOTAL"
echo "Отчёты и логи прогона: $WORK (удалятся при выходе; для разбора запусти с KEEP=1)"
[ "${KEEP:-0}" = "1" ] && trap - EXIT
exit 1
