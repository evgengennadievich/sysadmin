#!/usr/bin/env bash
# security-audit.sh — security-аудит сервера по чек-листу.
#
# Read-only — только проверки, ничего не меняет на сервере.
#
# Использование:
#   bash security-audit.sh \
#       --server <user>@<your-server> \
#       --scope all \
#       --domains-file inventory/hosts/<host>/domains.md \
#       --env-paths "/srv/apps /opt" \
#       --repo-path /path/to/repo \
#       --output inventory/audits/$(date +%Y-%m-%d).md
#
# ГЛАВНЫЙ ПРИНЦИП (введён 2026-07-29 после разбора ложных срабатываний):
# у проверки ТРИ исхода, а не два — PASS, WARN/FAIL и UNKNOWN.
# UNKNOWN = «проверить не удалось» (нет прав, нет команды, нет каталога).
# Раньше такие случаи молча превращались в PASS: команда падала, вывод был пуст,
# пустой вывод читался как «нарушений не найдено». Ложный PASS опаснее ложного
# FAIL: паника заметна сразу, а необоснованное спокойствие — нет.

set -uo pipefail

SERVER=""
SCOPE="all"
DOMAINS_FILE=""
OUTPUT=""
# Каталоги, где ищем .env. Раньше был жёстко зашит /opt — и на инфраструктуре
# с сервисами в /srv/apps проверка не находила НИ ОДНОГО файла, рапортуя PASS.
ENV_PATHS="/srv/apps /opt /srv /home"
REPO_PATH="."

while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER="$2"; shift 2 ;;
        --scope) SCOPE="$2"; shift 2 ;;
        --domains-file) DOMAINS_FILE="$2"; shift 2 ;;
        --env-paths) ENV_PATHS="$2"; shift 2 ;;
        --repo-path) REPO_PATH="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo "Неизвестный аргумент: $1"; exit 2 ;;
    esac
done

if [ -z "$SERVER" ]; then
    echo "Использование: $0 --server user@host [--scope host|docker|git|tls|all]"
    echo "               [--domains-file FILE] [--env-paths \"/srv/apps /opt\"]"
    echo "               [--repo-path DIR] [--output report.md]"
    exit 2
fi

PASS=0; WARN=0; FAIL=0; UNKNOWN=0
RESULTS_HOST=()
RESULTS_DOCKER=()
RESULTS_GIT=()
RESULTS_TLS=()
RECOMMENDATIONS=()
UNKNOWN_NOTES=()

# add_result CATEGORY STATUS CHECK_NAME DETAILS
add_result() {
    local CAT="$1" STATUS="$2" NAME="$3" DETAILS="$4"
    local LINE="| $NAME | $STATUS | $DETAILS |"
    case "$CAT" in
        host) RESULTS_HOST+=("$LINE") ;;
        docker) RESULTS_DOCKER+=("$LINE") ;;
        git) RESULTS_GIT+=("$LINE") ;;
        tls) RESULTS_TLS+=("$LINE") ;;
    esac
    case "$STATUS" in
        PASS) PASS=$((PASS + 1)) ;;
        WARN) WARN=$((WARN + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
        UNKNOWN) UNKNOWN=$((UNKNOWN + 1)); UNKNOWN_NOTES+=("$NAME — $DETAILS") ;;
    esac
}

add_recommendation() {
    RECOMMENDATIONS+=("$1")
}

# --- Транспорт -------------------------------------------------------------
# rexec CMD           — выполнить на сервере как есть
# rexec_root CMD      — выполнить с sudo -n (без пароля); при отказе вернуть 127
#
# Обе печатают stdout команды; КОД ВОЗВРАТА значим — по нему отличаем
# «команда отработала и ничего не нашла» от «команда не отработала».
rexec() {
    ssh -o ConnectTimeout=15 -o BatchMode=yes "$SERVER" "$1" 2>/dev/null
}

SUDO_AVAILABLE="unknown"
rexec_root() {
    if [ "$SUDO_AVAILABLE" = "no" ]; then
        return 127
    fi
    ssh -o ConnectTimeout=15 -o BatchMode=yes "$SERVER" "sudo -n $1" 2>/dev/null
}

# --- Предполётная проверка транспорта --------------------------------------
echo "[init] Проверка доступа..."
if ! rexec "true"; then
    echo "ОШИБКА: нет SSH-доступа к $SERVER. Аудит невозможен." >&2
    exit 2
fi

# Многие проверки требуют root (ufw status, fail2ban-client, ss -p, чтение
# /etc/ssh/sshd_config.d). Без sudo они не FAIL, а UNKNOWN — и это должно быть
# видно в отчёте, а не спрятано за бодрым PASS.
if rexec "sudo -n true" >/dev/null 2>&1; then
    SUDO_AVAILABLE="yes"
    echo "[init] sudo без пароля доступен — проверки уровня root выполнимы."
else
    SUDO_AVAILABLE="no"
    echo "[init] ВНИМАНИЕ: sudo без пароля недоступен."
    echo "       Проверки, требующие root, будут помечены UNKNOWN, а не PASS."
fi

# === HOST scope ===
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "host" ]; then
    echo "[host] Проверка UFW, SSH, fail2ban, портов..."

    # --- UFW ---
    # `ufw status` БЕЗ root отвечает «ERROR: You need to be root to run this
    # script» и выходит с кодом 0. Старая версия скрипта не находила в этом
    # выводе «Status: active» и рапортовала FAIL «UFW неактивен» на сервере с
    # полностью рабочим firewall. Отличаем отказ в правах от реального ответа.
    UFW_OUT=$(rexec_root "ufw status verbose")
    UFW_RC=$?
    if [ $UFW_RC -ne 0 ] || [ -z "$UFW_OUT" ] || echo "$UFW_OUT" | grep -qi "need to be root"; then
        add_result host UNKNOWN "UFW активен" "нет прав root — проверка не выполнена (не путать с «firewall выключен»)"
        add_recommendation "[UNKNOWN] Статус UFW не проверен: нужен sudo. Проверь вручную: \`sudo ufw status verbose\`"
    elif echo "$UFW_OUT" | grep -q "Status: active"; then
        if echo "$UFW_OUT" | grep -q "Default: deny (incoming)"; then
            add_result host PASS "UFW активен и default deny" "Status: active, Default: deny incoming"
        else
            add_result host WARN "UFW активен, но default не deny" "Проверь Default policy"
            add_recommendation "[WARN] UFW Default policy не deny incoming — \`ufw default deny incoming\` (Yellow Zone)"
        fi
    else
        add_result host FAIL "UFW активен" "Status: inactive"
        add_recommendation "[FAIL] UFW неактивен — критичный риск, \`ufw enable\` после allow 22/80/443 (Yellow Zone)"
    fi

    # --- Состав правил UFW ---
    # Показываем правила как есть, не пытаясь угадать «лишние»: на реальном
    # сервере легитимными бывают и панель на нестандартном порту, и доступ из
    # docker-подсетей. Решение о нужности правила — за человеком.
    if [ $UFW_RC -eq 0 ] && [ -n "$UFW_OUT" ] && ! echo "$UFW_OUT" | grep -qi "need to be root"; then
        ALLOW_RULES=$(echo "$UFW_OUT" | grep "ALLOW IN" | grep -vE "\(v6\)" | awk '{print $1}' | tr '\n' ' ')
        add_result host PASS "UFW: состав правил" "ALLOW IN: ${ALLOW_RULES:-нет правил}"
    else
        add_result host UNKNOWN "UFW: состав правил" "нет прав root — правила не прочитаны"
    fi

    # --- SSH: читаем ДЕЙСТВУЮЩУЮ конфигурацию, а не файл ---
    # `sshd -T` показывает то, что реально применено, с учётом sshd_config.d/*
    # и Match-блоков. Чтение одного sshd_config врёт, когда настройка
    # переопределена в другом файле (типовой случай на облачных образах).
    SSHD_EFFECTIVE=$(rexec_root "sshd -T")
    SSHD_RC=$?
    if [ $SSHD_RC -eq 0 ] && [ -n "$SSHD_EFFECTIVE" ]; then
        SSH_PWD=$(echo "$SSHD_EFFECTIVE" | grep -E "^passwordauthentication " | awk '{print $2}')
        SSH_ROOT=$(echo "$SSHD_EFFECTIVE" | grep -E "^permitrootlogin " | awk '{print $2}')
        SSH_KBD=$(echo "$SSHD_EFFECTIVE" | grep -E "^kbdinteractiveauthentication " | awk '{print $2}')
        SRC="действующая конфигурация (sshd -T)"
    else
        # Запасной путь: читаем файлы. Помечаем, что источник менее надёжен.
        SSH_PWD=$(rexec "grep -hE '^PasswordAuthentication' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -1 | awk '{print \$2}'")
        SSH_ROOT=$(rexec "grep -hE '^PermitRootLogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -1 | awk '{print \$2}'")
        SSH_KBD=""
        SRC="чтение файлов (sshd -T недоступен — возможны переопределения)"
    fi

    if [ -z "$SSH_PWD" ]; then
        add_result host UNKNOWN "SSH: вход по паролю" "не удалось определить"
    elif echo "$SSH_PWD" | grep -qi "^no$"; then
        add_result host PASS "SSH: вход по паролю" "no ($SRC)"
    else
        add_result host FAIL "SSH: вход по паролю" "$SSH_PWD ($SRC)"
        add_recommendation "[FAIL] SSH разрешает вход по паролю — включи \`PasswordAuthentication no\`, затем \`sshd -t && systemctl reload ssh\` (Yellow Zone; правка sshd с риском потери доступа — держи открытую сессию)"
    fi

    if [ -z "$SSH_ROOT" ]; then
        add_result host UNKNOWN "SSH: вход root" "не удалось определить"
    elif echo "$SSH_ROOT" | grep -qiE "^(no|prohibit-password)$"; then
        add_result host PASS "SSH: вход root" "$SSH_ROOT ($SRC)"
    else
        add_result host WARN "SSH: вход root" "$SSH_ROOT ($SRC)"
        add_recommendation "[WARN] SSH PermitRootLogin не ограничен — \`prohibit-password\` или \`no\` (Yellow Zone)"
    fi

    if [ -n "$SSH_KBD" ] && ! echo "$SSH_KBD" | grep -qi "^no$"; then
        add_result host WARN "SSH: интерактивная аутентификация" "$SSH_KBD — обходной путь для паролей"
        add_recommendation "[WARN] kbdinteractiveauthentication включён — это второй путь входа по паролю мимо PasswordAuthentication"
    fi

    # --- fail2ban ---
    F2B_ACTIVE=$(rexec "systemctl is-active fail2ban")
    if [ "$F2B_ACTIVE" != "active" ]; then
        add_result host FAIL "fail2ban" "не запущен (systemctl is-active → ${F2B_ACTIVE:-нет ответа})"
        add_recommendation "[FAIL] fail2ban не запущен — \`apt install fail2ban && systemctl enable --now fail2ban\` (Yellow Zone)"
    else
        # fail2ban-client требует root. Без него — UNKNOWN, а не «jail отсутствует».
        F2B_JAILS=$(rexec_root "fail2ban-client status")
        F2B_RC=$?
        if [ $F2B_RC -ne 0 ] || [ -z "$F2B_JAILS" ]; then
            add_result host UNKNOWN "fail2ban: состав jail" "служба активна, но список jail требует root"
            add_recommendation "[UNKNOWN] Список jail fail2ban не прочитан (нужен sudo). Проверь: \`sudo fail2ban-client status\`"
        else
            JAIL_LIST=$(echo "$F2B_JAILS" | grep "Jail list" | cut -d: -f2 | tr -d '\t' | sed 's/^ *//')
            if echo "$JAIL_LIST" | grep -q "sshd"; then
                SSHD_STAT=$(rexec_root "fail2ban-client status sshd")
                BANNED_NOW=$(echo "$SSHD_STAT" | grep "Currently banned" | awk '{print $NF}')
                BANNED_TOTAL=$(echo "$SSHD_STAT" | grep "Total banned" | awk '{print $NF}')
                add_result host PASS "fail2ban: sshd jail" "активен; в бане сейчас ${BANNED_NOW:-?}, всего забанено ${BANNED_TOTAL:-?}. Jail list: $JAIL_LIST"
            else
                add_result host WARN "fail2ban: sshd jail" "служба активна, но jail sshd отсутствует. Jail list: $JAIL_LIST"
                add_recommendation "[WARN] fail2ban работает, но защита SSH не включена — добавь jail sshd в /etc/fail2ban/jail.d/"
            fi
        fi
    fi

    # --- unattended-upgrades ---
    if rexec "test -f /etc/apt/apt.conf.d/50unattended-upgrades"; then
        UU_REBOOT=$(rexec "grep -E '^[^/]*Unattended-Upgrade::Automatic-Reboot ' /etc/apt/apt.conf.d/50unattended-upgrades")
        UU_PERIODIC=$(rexec "grep -c 'Unattended-Upgrade \"1\"' /etc/apt/apt.conf.d/20auto-upgrades")
        if [ "${UU_PERIODIC:-0}" -eq 0 ]; then
            add_result host WARN "unattended-upgrades" "файл настроек есть, но автозапуск не включён (20auto-upgrades)"
            add_recommendation "[WARN] unattended-upgrades настроен, но не запускается — проверь APT::Periodic::Unattended-Upgrade в /etc/apt/apt.conf.d/20auto-upgrades"
        elif echo "$UU_REBOOT" | grep -q '"false"'; then
            add_result host PASS "unattended-upgrades" "включён, только security, без авто-перезагрузки"
        else
            add_result host WARN "unattended-upgrades: авто-перезагрузка" "${UU_REBOOT:-не задано}"
            add_recommendation "[WARN] unattended-upgrades может перезагрузить сервер сам — \`Automatic-Reboot \"false\"\`"
        fi
    else
        add_result host WARN "unattended-upgrades" "не настроен"
        add_recommendation "[WARN] unattended-upgrades не настроен — обновления безопасности не ставятся автоматически"
    fi

    # --- sudo без пароля ---
    # Добавлено 2026-07-29: проверки не было, а находка оказалась одной из важнейших.
    # NOPASSWD: ALL означает, что компрометация SSH-ключа даёт мгновенный root без
    # второго барьера. Это не всегда дефект (без него ломается автоматизация), но
    # оператор обязан знать, что барьер один.
    SUDO_RULES=$(rexec_root "grep -rhE 'NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null")
    SUDO_RC=$?
    if [ $SUDO_RC -ne 0 ]; then
        add_result host UNKNOWN "sudo: правила NOPASSWD" "не прочитаны (нужен root)"
    elif [ -z "$SUDO_RULES" ]; then
        add_result host PASS "sudo: правила NOPASSWD" "нет — sudo везде требует пароль"
    elif echo "$SUDO_RULES" | grep -qE 'NOPASSWD:\s*ALL'; then
        add_result host WARN "sudo: правила NOPASSWD" "есть NOPASSWD: ALL — sudo без пароля на любые команды"
        add_recommendation "[WARN] sudo настроен как NOPASSWD: ALL — компрометация SSH-ключа даёт немедленный полный root. Варианты: сузить до списка конкретных команд либо оставить осознанно. ВАЖНО при сужении: не включай в список команды, из которых можно выйти в оболочку или запустить произвольный код (cat/less/find -exec/редакторы/sqlite3/apt/systemctl без указания службы) — иначе список даёт лишь видимость защиты"
    else
        add_result host PASS "sudo: правила NOPASSWD" "есть, но ограничены конкретными командами"
    fi

    # --- Группа docker = фактический root ---
    # Добавлено 2026-07-29. Член группы docker может смонтировать / в контейнер и
    # получить root без sudo. Без этой проверки оценка «насколько сервер защищён»
    # получается завышенной: можно закрутить sudo и не заметить открытую дверь рядом.
    DOCKER_MEMBERS=$(rexec "getent group docker | cut -d: -f4")
    if [ -n "$DOCKER_MEMBERS" ]; then
        add_result host WARN "Группа docker" "состоят: $DOCKER_MEMBERS — это эквивалент root (монтирование / в контейнер)"
        add_recommendation "[WARN] Пользователи в группе docker ($DOCKER_MEMBERS) фактически имеют root. Это часто осознанный компромисс ради автоматизации — но учитывай его, когда оцениваешь пользу от ужесточения sudo: закрутив одну дверь, соседнюю оставляем открытой"
    else
        add_result host PASS "Группа docker" "пуста — прямого пути к root через Docker нет"
    fi

    # --- Слушающие сокеты ---
    # ss без root не показывает процессы (-p), но сами сокеты видны. Отличаем
    # «ничего не слушает наружу» от «ss не отработал».
    SS_OUT=$(rexec_root "ss -tlnp")
    SS_RC=$?
    if [ $SS_RC -ne 0 ] || [ -z "$SS_OUT" ]; then
        SS_OUT=$(rexec "ss -tln")
        SS_RC=$?
    fi
    if [ $SS_RC -ne 0 ] || [ -z "$SS_OUT" ]; then
        add_result host UNKNOWN "Внешние слушающие порты" "ss не отработал — список портов не получен"
    else
        EXTERNAL=$(echo "$SS_OUT" | awk 'NR>1 && ($4 ~ /^0\.0\.0\.0:/ || $4 ~ /^\*:/ || $4 ~ /^\[::\]:/) {split($4,a,":"); print a[length(a)]}' | sort -un | tr '\n' ' ')
        add_result host PASS "Внешние слушающие порты" "${EXTERNAL:-нет}"
        # Порты вне 22/80/443 — не приговор, а повод сверить с UFW и инвентарём.
        UNUSUAL=$(echo "$EXTERNAL" | tr ' ' '\n' | grep -vE '^(22|80|443)$' | tr '\n' ' ')
        if [ -n "$(echo "$UNUSUAL" | tr -d ' ')" ]; then
            add_recommendation "[ПРОВЕРЬ] Наружу слушают нестандартные порты: $UNUSUAL. Это не обязательно дефект (панель, VPN-инбаунд), но каждый должен быть в инвентаре и либо закрыт в UFW, либо осознанно открыт"
        fi
    fi
fi

# === DOCKER scope ===
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "docker" ]; then
    echo "[docker] Проверка daemon.json, прав .env..."

    if rexec "test -f /etc/docker/daemon.json"; then
        if rexec "grep -q 'insecure-registries' /etc/docker/daemon.json"; then
            add_result docker WARN "daemon.json" "содержит insecure-registries"
            add_recommendation "[WARN] Docker daemon.json содержит insecure-registries — если это внутренний registry, задокументируй в inventory/hosts/<host>/server.md"
        else
            add_result docker PASS "daemon.json" "без insecure-registries"
        fi
    else
        add_result docker PASS "daemon.json" "конфигурация по умолчанию"
    fi

    # --- Права .env ---
    # ГЛАВНАЯ ПРАВКА 2026-07-29. Раньше искали только в /opt с фиксированной
    # глубиной. На инфраструктуре с сервисами в /srv/apps не проверялся НИ ОДИН
    # файл, а отчёт показывал PASS «все .env mode 600» — то есть уверенность
    # была там, где проверки не происходило вовсе.
    # Теперь: считаем найденное. Ноль найденных файлов — это UNKNOWN, не PASS.
    ENV_FOUND=$(rexec "find $ENV_PATHS -maxdepth 4 -name '.env' -type f 2>/dev/null | wc -l")
    ENV_RC=$?
    if [ $ENV_RC -ne 0 ] || [ -z "$ENV_FOUND" ]; then
        add_result docker UNKNOWN "Права .env" "поиск не выполнен (проверялись пути: $ENV_PATHS)"
    elif [ "$ENV_FOUND" -eq 0 ]; then
        add_result docker UNKNOWN "Права .env" "не найдено ни одного .env в путях: $ENV_PATHS — проверять нечего, но и подтвердить нечего"
        add_recommendation "[UNKNOWN] Файлы .env не найдены в $ENV_PATHS. Если сервисы живут в другом каталоге, передай его через --env-paths, иначе проверка прав секретов не проводилась"
    else
        BAD_ENV=$(rexec "find $ENV_PATHS -maxdepth 4 -name '.env' -type f -exec stat -c '%a %U:%G %n' {} \; 2>/dev/null | grep -vE '^600 '")
        if [ -z "$BAD_ENV" ]; then
            add_result docker PASS "Права .env" "проверено файлов: $ENV_FOUND, все mode 600"
        else
            BAD_COUNT=$(echo "$BAD_ENV" | grep -c . )
            add_result docker WARN "Права .env" "проверено $ENV_FOUND, с лишними правами: $BAD_COUNT"
            add_recommendation "[WARN] .env с избыточными правами (секреты читает любой процесс системы):
$BAD_ENV
Исправление: \`chmod 600 <файл>\` (Yellow Zone). Проверь, от какого пользователя работает контейнер — если от root, смена прав его не сломает"
        fi
    fi
fi

# === GIT scope ===
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "git" ]; then
    echo "[git] Проверка gitleaks и .gitignore..."

    if [ ! -d "$REPO_PATH/.git" ]; then
        add_result git UNKNOWN "gitleaks scan" "$REPO_PATH не git-репозиторий — скан не выполнялся"
    elif command -v gitleaks >/dev/null 2>&1; then
        GL_OUT=$(cd "$REPO_PATH" && gitleaks detect --no-banner --log-opts='--all' 2>&1)
        if [ $? -eq 0 ]; then
            SCANNED=$(echo "$GL_OUT" | grep -oE '[0-9]+ commits scanned' | head -1)
            add_result git PASS "gitleaks scan" "утечек нет (${SCANNED:-история просмотрена})"
        else
            add_result git FAIL "gitleaks scan" "найдены утечки"
            add_recommendation "[FAIL] gitleaks нашёл секреты в $REPO_PATH — детали: \`cd $REPO_PATH && gitleaks detect --log-opts='--all' --report-path leaks.json\`. Исправление: ротировать утёкшие секреты (git-историю переписывать только после ротации — сам по себе filter-repo секрет не отзывает)"
        fi
    else
        add_result git UNKNOWN "gitleaks scan" "gitleaks не установлен — автоматический скан не проводился"
        add_recommendation "[UNKNOWN] gitleaks не установлен (\`brew install gitleaks\`). Ручной поиск по истории ловит меньше форматов, чем специализированный инструмент"
    fi

    if [ -f "$REPO_PATH/.gitignore" ]; then
        MISSING=""
        for pattern in '\.env' '\*\.key' '\*\.pem' 'secrets/'; do
            grep -qE "$pattern" "$REPO_PATH/.gitignore" || MISSING="$MISSING $pattern"
        done
        if [ -z "$MISSING" ]; then
            add_result git PASS ".gitignore: правила для секретов" ".env, *.key, *.pem, secrets/"
        else
            add_result git WARN ".gitignore: правила для секретов" "отсутствуют:$MISSING"
            add_recommendation "[WARN] В .gitignore нет правил:$MISSING — секретов может и не быть, но единственная защита от их случайного добавления сейчас это внимательность"
        fi
    else
        add_result git UNKNOWN ".gitignore" "файл отсутствует в $REPO_PATH"
    fi
fi

# === TLS scope ===
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "tls" ]; then
    echo "[tls] Проверка сертификатов..."

    if [ -n "$DOMAINS_FILE" ] && [ -f "$DOMAINS_FILE" ]; then
        DOMAINS=$(grep -oE '\b[a-z0-9][a-z0-9.-]*\.(ru|com|tech|io|net|org|dev|app|su)\b' "$DOMAINS_FILE" | sort -u)
        for domain in $DOMAINS; do
            # Разделяем три разных исхода, которые раньше сливались в FAIL:
            #   1) порт не отвечает вовсе        → UNKNOWN (может быть закрыт намеренно)
            #   2) TLS есть, но это не веб       → PASS по сертификату (штатно для VPN-инбаунда)
            #   3) сертификат есть → считаем срок
            CERT_RAW=$(echo | openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null)
            EXPIRY=$(echo "$CERT_RAW" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

            if [ -z "$EXPIRY" ]; then
                add_result tls UNKNOWN "$domain" "порт 443 не отвечает или не отдаёт сертификат — проверь, обслуживается ли домен на этом сервере"
                add_recommendation "[UNKNOWN] $domain: TLS-соединение не установилось. Это не обязательно авария — порт может быть закрыт или занят не-TLS сервисом. Проверь вручную: \`openssl s_client -connect $domain:443\`"
                continue
            fi

            VERIFY=$(echo "$CERT_RAW" | grep -E "^\s*Verify return code:" | tail -1 | sed 's/^ *//')

            EXPIRY_TS=$(date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null \
                || date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
            NOW_TS=$(date +%s)
            DAYS=$(( (EXPIRY_TS - NOW_TS) / 86400 ))

            if [ "$EXPIRY_TS" = "0" ]; then
                add_result tls UNKNOWN "$domain" "сертификат получен, но дату истечения разобрать не удалось: $EXPIRY"
            elif [ "$DAYS" -lt 14 ]; then
                add_result tls FAIL "$domain" "$EXPIRY ($DAYS дней). $VERIFY"
                add_recommendation "[FAIL] $domain истекает через $DAYS дней — обнови сертификат немедленно (\`acme.sh --renew -d $domain\`) и проверь, что автопродление работает"
            elif [ "$DAYS" -lt 30 ]; then
                add_result tls WARN "$domain" "$EXPIRY ($DAYS дней). $VERIFY"
                add_recommendation "[WARN] $domain истекает через $DAYS дней — автопродление должно сработать, проверь его расписание"
            else
                add_result tls PASS "$domain" "$EXPIRY ($DAYS дней). $VERIFY"
            fi
        done
    else
        echo "  (файл доменов не задан или не найден — TLS-проверки пропущены)"
        add_result tls UNKNOWN "TLS-проверки" "файл доменов не задан (--domains-file), проверки не проводились"
    fi
fi

# === Сборка отчёта ===
TS=$(date +%Y-%m-%d)
REPORT_FILE="${OUTPUT:-/tmp/security-audit-${TS}.md}"

{
    echo "# Security Audit — $TS"
    echo ""
    echo "**Сервер:** $SERVER"
    echo "**Scope:** $SCOPE"
    echo "**Сводка:** $PASS PASS / $WARN WARN / $FAIL FAIL / $UNKNOWN UNKNOWN"
    echo ""
    if [ "$SUDO_AVAILABLE" = "no" ]; then
        echo "> **Внимание:** sudo без пароля недоступен, часть проверок уровня root не выполнена."
        echo "> Их статус — UNKNOWN. Отсутствие FAIL при этом **не означает**, что нарушений нет."
        echo ""
    fi
    if [ "$UNKNOWN" -gt 0 ]; then
        echo "> **Непроверенное ($UNKNOWN):** ниже перечислены проверки, которые выполнить не удалось."
        echo "> Это не результат «всё хорошо» — это отсутствие результата."
        echo ""
        for n in "${UNKNOWN_NOTES[@]}"; do
            echo "> - $n"
        done
        echo ""
    fi

    if [ ${#RESULTS_HOST[@]} -gt 0 ]; then
        echo "## Host"
        echo "| Проверка | Статус | Детали |"
        echo "|----------|--------|--------|"
        printf '%s\n' "${RESULTS_HOST[@]}"
        echo ""
    fi
    if [ ${#RESULTS_DOCKER[@]} -gt 0 ]; then
        echo "## Docker"
        echo "| Проверка | Статус | Детали |"
        echo "|----------|--------|--------|"
        printf '%s\n' "${RESULTS_DOCKER[@]}"
        echo ""
    fi
    if [ ${#RESULTS_GIT[@]} -gt 0 ]; then
        echo "## Git"
        echo "| Проверка | Статус | Детали |"
        echo "|----------|--------|--------|"
        printf '%s\n' "${RESULTS_GIT[@]}"
        echo ""
    fi
    if [ ${#RESULTS_TLS[@]} -gt 0 ]; then
        echo "## TLS"
        echo "| Домен | Статус | Детали |"
        echo "|-------|--------|--------|"
        printf '%s\n' "${RESULTS_TLS[@]}"
        echo ""
    fi
    if [ ${#RECOMMENDATIONS[@]} -gt 0 ]; then
        echo "## Рекомендации"
        i=1
        for r in "${RECOMMENDATIONS[@]}"; do
            echo "$i. $r"
            i=$((i + 1))
        done
        echo ""
    fi
    echo "---"
    echo ""
    echo "_Отчёт составлен автоматически. Каждую находку следует подтвердить вручную перед"
    echo "тем, как действовать: у скрипта нет доступа к контексту (какой порт открыт осознанно,"
    echo "какой сервис где живёт). Статус UNKNOWN означает «не проверено», а не «в порядке»._"
} > "$REPORT_FILE"

echo ""
echo "=== Аудит завершён ==="
echo "Сводка: $PASS PASS / $WARN WARN / $FAIL FAIL / $UNKNOWN UNKNOWN"
echo "Отчёт: $REPORT_FILE"
echo ""
if [ "$UNKNOWN" -gt 0 ]; then
    echo "Не выполнено проверок: $UNKNOWN — см. раздел «Непроверенное» в отчёте."
fi
if [ "$FAIL" -gt 0 ]; then
    echo "ВНИМАНИЕ: найдены FAIL'ы — рассмотри как incident."
    exit 1
fi
