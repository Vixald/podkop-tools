#!/bin/sh
# =============================================================================
#  Podkop Unified Maintenance Tool
# -----------------------------------------------------------------------------
#  Единый монолитный установщик/обслуживатель для OpenWrt (BusyBox /bin/sh).
#  Объединяет:
#    1. Автообновление Podkop            (irat25/podkop-auto-update)
#    2. Обновление sing-box              (EikeiDev/OpenWRT-sing-box-extended)
#    3. Патч xHTTP                       (moix89/podkop-xhttp-patch)
#    4. Меню/цвета                       (Vixald/podkop-tools)
#    5. Встроенный патч wget -> curl     (Vixald/podkop-tools/patches/20-curl-download.sh)
#
#  Главная фишка: пункт «Setup Full Auto-Update» ставит ночное автообновление
#  Подкопа от irat25 и ВНЕДРЯЕТ хук в cron так, что сразу после фонового
#  обновления автоматически накатываются патч xHTTP и встроенный curl-патч.
#  Поэтому ночное обновление Подкопа больше никогда не затрёт патчи.
#
#  Совместимость: чистый POSIX /bin/sh. Ключевое слово `local` НЕ используется
#  в логике установщика (единственное его появление — внутри строкового
#  payload, который внедряется в helpers.sh самого Podkop, где это его код).
# =============================================================================

# Намеренно НЕ используем `set -e`: ошибки обрабатываются вручную по месту,
# чтобы меню оставалось интерактивным даже после сбойной операции.
set -u

# ----------------------------------------------------------------------------
#  ANSI-цвета (из Vixald/podkop-tools)
# ----------------------------------------------------------------------------
R="\033[1;31m"   # красный  — ошибки
G="\033[1;32m"   # зелёный  — успех
Y="\033[1;33m"   # жёлтый   — предупреждения
C="\033[1;36m"   # голубой  — информация
N="\033[0m"      # сброс

# ----------------------------------------------------------------------------
#  Источники (raw-ссылки)
# ----------------------------------------------------------------------------
# Установщик автообновления Подкопа (прописывает себя в cron):
PODKOP_AUTOUPDATE_INSTALL_URL="https://raw.githubusercontent.com/irat25/podkop-auto-update/main/install.sh"
# Сам скрипт-обновлятор Подкопа (вызывается планировщиком; используем для ручного апдейта):
PODKOP_UPDATE_URL="https://raw.githubusercontent.com/irat25/podkop-auto-update/main/files/root/podkop-auto-update.sh"
# Обновление sing-box:
SINGBOX_URL="https://raw.githubusercontent.com/EikeiDev/OpenWRT-sing-box-extended/refs/heads/main/install.sh"
# Патч xHTTP:
XHTTP_URL="https://raw.githubusercontent.com/moix89/podkop-xhttp-patch/main/install.sh"

# ----------------------------------------------------------------------------
#  Системные пути
# ----------------------------------------------------------------------------
CRON_FILE="/etc/crontabs/root"
AUTOUPDATE_SCRIPT="/root/podkop-auto-update.sh"
HOOK_SCRIPT="/root/podkop-patch-hook.sh"
HELPERS="/usr/lib/podkop/helpers.sh"

# ----------------------------------------------------------------------------
#  Управление временными файлами и очистка
# ----------------------------------------------------------------------------
TMP_FILE=""

# trap на старте: гарантированно подчищаем за собой временные файлы и
# обнуляем переменные, чтобы не забивать tmpfs роутера.
cleanup() {
    [ -n "${TMP_FILE:-}" ] && rm -f "$TMP_FILE"
    TMP_FILE=""
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------------
#  Определение Podkop
# ----------------------------------------------------------------------------
if [ -f "/opt/etc/init.d/podkop" ]; then
    PODKOP_INIT="/opt/etc/init.d/podkop"
elif [ -f "/etc/init.d/podkop" ]; then
    PODKOP_INIT="/etc/init.d/podkop"
else
    PODKOP_INIT=""
fi

if ! command -v podkop >/dev/null 2>&1; then
    printf "${Y}[!] Предупреждение: команда 'podkop' не найдена в PATH.${N}\n"
    printf "${Y}    Часть операций (restart/global_check/патчи) может быть недоступна.${N}\n"
fi

# ----------------------------------------------------------------------------
#  Утилита: пауза до нажатия Enter
# ----------------------------------------------------------------------------
wait_key() {
    printf "\n${Y}Нажмите Enter для продолжения...${N}"
    read -r _
}

# ----------------------------------------------------------------------------
#  Универсальная функция загрузки: download_script <url> <dest>
#    - curl --fail --silent --show-error --location, фоллбек на wget -qO
#    - проверка на пустоту
#    - проверка первых 20 строк на HTML/серверные ошибки
#    - синтаксический чекер `sh -n`
#  Возвращает 0 при успехе, 1 при ошибке (с удалением битого файла).
# ----------------------------------------------------------------------------
download_script() {
    # $1 = url, $2 = dest (позиционные параметры — без `local`)
    if command -v curl >/dev/null 2>&1; then
        if ! curl --fail --silent --show-error --location -o "$2" "$1"; then
            printf "${R}[!] Ошибка: curl не смог скачать $1${N}\n"
            rm -f "$2"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -qO "$2" "$1"; then
            printf "${R}[!] Ошибка: wget не смог скачать $1${N}\n"
            rm -f "$2"
            return 1
        fi
    else
        printf "${R}[!] Ошибка: не найдено ни curl, ни wget.${N}\n"
        return 1
    fi

    # Файл вообще создан?
    if [ ! -f "$2" ]; then
        printf "${R}[!] Ошибка: файл не был создан после загрузки: $1${N}\n"
        return 1
    fi

    # Файл не пустой?
    if [ ! -s "$2" ]; then
        printf "${R}[!] Ошибка: скачанный файл пустой: $1${N}\n"
        rm -f "$2"
        return 1
    fi

    # Первые 20 строк не содержат HTML-разметку или серверную ошибку?
    if head -n 20 "$2" 2>/dev/null | grep -qiE '<html|<body|<!DOCTYPE|404: Not Found|Bad Gateway|Internal Server Error'; then
        printf "${R}[!] Ошибка: ответ сервера выглядит как HTML/ошибка, а не скрипт: $1${N}\n"
        rm -f "$2"
        return 1
    fi

    # Синтаксическая корректность скачанного скрипта?
    if ! sh -n "$2" >/dev/null 2>&1; then
        printf "${R}[!] Ошибка: скачанный файл не проходит проверку синтаксиса: $1${N}\n"
        rm -f "$2"
        return 1
    fi

    return 0
}

# ----------------------------------------------------------------------------
#  Встроенный код патча wget -> curl (20-curl-download.sh)
#  Печатает в stdout полностью самодостаточный скрипт-патч, который заменяет
#  функцию download_to_file() в /usr/lib/podkop/helpers.sh на curl-версию.
#  Внешний heredoc — В КАВЫЧКАХ ('CURL_PATCH_EOF'), поэтому НИЧЕГО здесь не
#  раскрывается установщиком и payload пишется дословно. Вложенный heredoc
#  (CURL_FUNC_EOF) раскрывается уже при ВЫПОЛНЕНИИ патча.
# ----------------------------------------------------------------------------
emit_curl_patch() {
cat <<'CURL_PATCH_EOF'
#!/bin/sh
# Podkop curl download patch (встроен в unified installer)
# Заменяет функцию download_to_file() в helpers.sh: сначала curl, fallback wget.
# Идемпотентен: повторный запуск ничего не ломает (проверяется маркер).

HELPERS="/usr/lib/podkop/helpers.sh"
BACKUP_DIR="/root"
MARKER_COMMENT="# PODKOP-CURL-PATCH"

cp_log()  { echo "[podkop-curl-patch] $1"; }
cp_warn() { echo "[podkop-curl-patch] WARN: $1" >&2; }
cp_err()  { echo "[podkop-curl-patch] ERROR: $1" >&2; }

# Временные файлы — через mktemp, с немедленной очисткой по trap.
NEW_FUNC_FILE=""
TMP_OUTPUT=""
cp_cleanup() {
    [ -n "$NEW_FUNC_FILE" ] && rm -f "$NEW_FUNC_FILE"
    [ -n "$TMP_OUTPUT" ] && rm -f "$TMP_OUTPUT"
}
trap cp_cleanup EXIT INT TERM

# Откат: восстановить файл из временной копии .bak.
rollback() {
    if [ -f "${HELPERS}.bak" ]; then
        mv -f "${HELPERS}.bak" "$HELPERS"
    fi
}

# -- 1. Предварительные проверки --------------------------------------------
if [ ! -f "$HELPERS" ]; then
    cp_err "Файл не найден: $HELPERS — Podkop установлен?"
    exit 1
fi

# Проверка идемпотентности.
if grep -q "$MARKER_COMMENT" "$HELPERS"; then
    cp_log "Патч curl-download уже установлен. Пропускаем."
    exit 0
fi

# -- 2. Резервные копии ------------------------------------------------------
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="$BACKUP_DIR/helpers.sh.backup.$TS"
if ! cp "$HELPERS" "$BACKUP_FILE"; then
    cp_err "Не удалось создать резервную копию в $BACKUP_DIR."
    exit 1
fi
cp_log "Создана резервная копия: $BACKUP_FILE"

# Рабочая копия для отката в случае проблем.
if ! cp "$HELPERS" "${HELPERS}.bak"; then
    cp_err "Не удалось создать копию ${HELPERS}.bak"
    exit 1
fi

if ! NEW_FUNC_FILE="$(mktemp)"; then
    cp_err "Не удалось создать временный файл (mktemp)."
    rollback
    exit 1
fi
if ! TMP_OUTPUT="$(mktemp)"; then
    cp_err "Не удалось создать временный файл (mktemp)."
    rollback
    exit 1
fi

# -- 3. Генерация новой реализации функции ----------------------------------
# Вложенный heredoc БЕЗ кавычек: $MARKER_COMMENT раскрывается, а \$1, \${4:-3}
# и \\ экранированы, чтобы попасть в файл как $1, ${4:-3} и одиночный \.
cat > "$NEW_FUNC_FILE" << CURL_FUNC_EOF
download_to_file() {
    $MARKER_COMMENT
    local url="\$1"
    local filepath="\$2"
    local http_proxy_address="\$3"
    local retries="\${4:-3}"
    local wait="\${5:-2}"

    for attempt in \$(seq 1 "\$retries"); do
        if command -v curl >/dev/null 2>&1; then
            if [ -n "\$http_proxy_address" ]; then
                curl --fail --silent --show-error --location --proxy "http://\$http_proxy_address" --output "\$filepath" "\$url"
            else
                curl --fail --silent --show-error --location --output "\$filepath" "\$url"
            fi
        else
            if [ -n "\$http_proxy_address" ]; then
                http_proxy="http://\$http_proxy_address" \\
                https_proxy="http://\$http_proxy_address" \\
                wget -O "\$filepath" "\$url"
            else
                wget -O "\$filepath" "\$url"
            fi
        fi

        if [ \$? -eq 0 ]; then
            return 0
        fi

        log "Attempt \$attempt/\$retries to download \$url failed" "warn"
        sleep "\$wait"
    done

    return 1
}
CURL_FUNC_EOF

# -- 4. Замена старой функции через awk -------------------------------------
# awk построчно отслеживает баланс фигурных скобок тела функции и, найдя
# завершение оригинального download_to_file(), подставляет новый текст из
# func_file. Перед заменой убеждаемся, что внутри был ожидаемый вызов wget.
awk -v func_file="$NEW_FUNC_FILE" '
BEGIN {
    in_func = 0;
    braces = 0;
    replaced = 0;
    has_target_wget = 0;
}
{
    if (!in_func) {
        if ($0 ~ /^[[:space:]]*download_to_file\(\)[[:space:]]*\{/) {
            in_func = 1;
            braces = 0;
            replaced++;

            t = $0;
            while (sub(/\{/, "", t)) braces++;
            while (sub(/\}/, "", t)) braces--;

            if (braces == 0 && in_func) {
                in_func = 0;
                if (has_target_wget == 1) {
                    while ((getline line < func_file) > 0) { print line }
                    close(func_file);
                } else {
                    exit 2;
                }
            }
            next;
        }
        print $0;
    } else {
        # Ищем именно целевой wget внутри старого тела функции.
        if ($0 ~ /wget -O[[:space:]]*"\$filepath"[[:space:]]*"\$url"/) {
            has_target_wget = 1;
        }

        t = $0;
        while (sub(/\{/, "", t)) braces++;
        while (sub(/\}/, "", t)) braces--;

        # Достигли конца тела функции.
        if (braces <= 0) {
            in_func = 0;

            if (has_target_wget == 1) {
                # Подставляем новую реализацию вместо старого тела.
                while ((getline line < func_file) > 0) { print line }
                close(func_file);
            } else {
                # Неизвестная структура: выходим, не трогая файл.
                exit 2;
            }
        }
    }
}
END {
    # Функция должна встретиться ровно один раз.
    if (replaced != 1) {
        exit 1;
    }
}
' "$HELPERS" > "$TMP_OUTPUT"

AWK_RES=$?

# Анализ кода возврата awk.
if [ "$AWK_RES" -eq 2 ]; then
    cp_err "Неизвестная структура download_to_file() в этой версии Podkop."
    cp_err "Ожидаемый вызов wget внутри тела функции не найден. Патч отменён."
    rollback
    exit 1
elif [ "$AWK_RES" -ne 0 ]; then
    cp_err "Функция download_to_file() не найдена или встречается не один раз. Отмена."
    rollback
    exit 1
fi

# -- 5. Проверки результата с откатом (rollback) ----------------------------
# Синтаксическая корректность нового файла.
if ! sh -n "$TMP_OUTPUT" >/dev/null 2>&1; then
    cp_err "Синтаксическая проверка пропатченного файла не пройдена. Откат."
    rollback
    exit 1
fi

# Заголовок функции на месте.
if ! grep -q '^[[:space:]]*download_to_file()[[:space:]]*{' "$TMP_OUTPUT"; then
    cp_err "Контрольная проверка: заголовок download_to_file() пропал. Откат."
    rollback
    exit 1
fi

# Маркер патча записан.
if ! grep -q "$MARKER_COMMENT" "$TMP_OUTPUT"; then
    cp_err "Контрольная проверка: маркер патча не записан. Откат."
    rollback
    exit 1
fi

# -- 6. Финальная установка --------------------------------------------------
if mv -f "$TMP_OUTPUT" "$HELPERS"; then
    TMP_OUTPUT=""
    cp_log "Патч успешно применён. download_to_file() переведён на curl."
    cp_log "Резервная рабочая копия: ${HELPERS}.bak"
    exit 0
else
    cp_err "Не удалось записать изменения в $HELPERS. Восстанавливаю."
    rollback
    exit 1
fi
CURL_PATCH_EOF
}

# ----------------------------------------------------------------------------
#  run_my_curl_patch — запускает встроенный curl-патч из временного файла.
#  Файл запускается строго через `sh "$TMP_FILE"` (без chmod +x).
# ----------------------------------------------------------------------------
run_my_curl_patch() {
    printf "\n${C}[*] Применение встроенного curl-патча (wget -> curl)...${N}\n"

    if ! TMP_FILE="$(mktemp)"; then
        printf "${R}[ FAILED ] Не удалось создать временный файл в /tmp${N}\n"
        return 1
    fi

    emit_curl_patch > "$TMP_FILE"

    # Синтаксический чекер перед запуском.
    if ! sh -n "$TMP_FILE" >/dev/null 2>&1; then
        printf "${R}[ FAILED ] Встроенный curl-патч не прошёл проверку синтаксиса.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 1
    fi

    if sh "$TMP_FILE"; then
        printf "${G}[ OK ] Встроенный curl-патч применён.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 0
    else
        printf "${R}[ FAILED ] Встроенный curl-патч завершился с ошибкой.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 1
    fi
}

# ----------------------------------------------------------------------------
#  run_xhttp_patch — скачивает и применяет патч xHTTP (moix89).
# ----------------------------------------------------------------------------
run_xhttp_patch() {
    printf "\n${C}[*] Применение патча xHTTP (moix89)...${N}\n"

    if ! TMP_FILE="$(mktemp)"; then
        printf "${R}[ FAILED ] Не удалось создать временный файл в /tmp${N}\n"
        return 1
    fi

    if ! download_script "$XHTTP_URL" "$TMP_FILE"; then
        printf "${R}[ FAILED ] Не удалось загрузить патч xHTTP.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 1
    fi

    if sh "$TMP_FILE"; then
        printf "${G}[ OK ] Патч xHTTP применён.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 0
    else
        printf "${R}[ FAILED ] Ошибка при выполнении патча xHTTP.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 1
    fi
}

# ----------------------------------------------------------------------------
#  Пункт меню 1 — обновление sing-box (EikeiDev).
# ----------------------------------------------------------------------------
run_update_singbox() {
    printf "\n${C}[*] Обновление sing-box (EikeiDev)...${N}\n"

    if ! TMP_FILE="$(mktemp)"; then
        printf "${R}[ FAILED ] Не удалось создать временный файл в /tmp${N}\n"
        return 1
    fi

    if ! download_script "$SINGBOX_URL" "$TMP_FILE"; then
        printf "${R}[ FAILED ] Не удалось загрузить скрипт обновления sing-box.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 1
    fi

    if sh "$TMP_FILE"; then
        printf "${G}[ OK ] sing-box обновлён.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 0
    else
        printf "${R}[ FAILED ] Ошибка при обновлении sing-box.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 1
    fi
}

# ----------------------------------------------------------------------------
#  Пункт меню 2 — ручное применение xHTTP + сразу поверх встроенный curl-патч.
# ----------------------------------------------------------------------------
run_apply_patches() {
    rc=0
    if ! run_xhttp_patch; then
        rc=1
    fi
    # curl-патч накатываем в любом случае (он идемпотентен и не зависит от xHTTP).
    if ! run_my_curl_patch; then
        rc=1
    fi
    return "$rc"
}

# ----------------------------------------------------------------------------
#  Обновление самого Подкопа (ручное) — запускаем скрипт-обновлятор irat25
#  напрямую, БЕЗ установки cron.
# ----------------------------------------------------------------------------
run_update_podkop() {
    printf "\n${C}[*] Обновление Podkop...${N}\n"

    if ! TMP_FILE="$(mktemp)"; then
        printf "${R}[ FAILED ] Не удалось создать временный файл в /tmp${N}\n"
        return 1
    fi

    if ! download_script "$PODKOP_UPDATE_URL" "$TMP_FILE"; then
        printf "${R}[ FAILED ] Не удалось загрузить скрипт обновления Podkop.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 1
    fi

    if sh "$TMP_FILE"; then
        printf "${G}[ OK ] Podkop обновлён.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 0
    else
        printf "${R}[ FAILED ] Ошибка при обновлении Podkop.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 1
    fi
}

# ----------------------------------------------------------------------------
#  Генерация hook-скрипта /root/podkop-patch-hook.sh.
#  Самодостаточный: скачивает и запускает патч xHTTP (moix89), затем выполняет
#  встроенный curl-патч. Вызывается планировщиком как `sh <файл>` (без chmod).
# ----------------------------------------------------------------------------
write_hook_script() {
    # Шапка хука пишется через quoted-heredoc (без раскрытий установщиком).
    cat > "$HOOK_SCRIPT" <<'HOOK_HEADER_EOF'
#!/bin/sh
# =============================================================================
#  Auto-generated by Podkop Unified Maintenance Tool.
#  Запускается из cron СРАЗУ после фонового обновления Подкопа и повторно
#  накатывает патчи (xHTTP + curl), чтобы ночное обновление их не затирало.
#  НЕ редактировать вручную — файл перегенерируется установщиком.
# =============================================================================

HOOK_LOG="/tmp/podkop-patch-hook.log"
hlog() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$HOOK_LOG"; }

XHTTP_URL="https://raw.githubusercontent.com/moix89/podkop-xhttp-patch/main/install.sh"

hlog "=== hook start ==="

# -- 1. Патч xHTTP (moix89) -------------------------------------------------
if HK_TMP="$(mktemp)"; then
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location -o "$HK_TMP" "$XHTTP_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$HK_TMP" "$XHTTP_URL"
    fi

    if [ -s "$HK_TMP" ] \
       && ! head -n 20 "$HK_TMP" 2>/dev/null | grep -qiE '<html|<body|<!DOCTYPE|404: Not Found|Bad Gateway|Internal Server Error' \
       && sh -n "$HK_TMP" >/dev/null 2>&1; then
        if sh "$HK_TMP" >> "$HOOK_LOG" 2>&1; then
            hlog "xHTTP patch: OK"
        else
            hlog "xHTTP patch: FAILED (runtime)"
        fi
    else
        hlog "xHTTP patch: пропущен (загрузка/проверка не пройдена)"
    fi
    rm -f "$HK_TMP"
else
    hlog "xHTTP patch: пропущен (mktemp failed)"
fi

# -- 2. Встроенный curl-патч (код ниже выполняется как обычный скрипт) -------
hlog "curl patch: запуск встроенного патча"
HOOK_HEADER_EOF

    # Дописываем тело встроенного curl-патча (тот же самый код, что и в меню).
    emit_curl_patch >> "$HOOK_SCRIPT"
}

# ----------------------------------------------------------------------------
#  Внедрение хука в cron: дописывает к строке автообновления вызов хука.
#  Идемпотентно — повторный запуск не дублирует.
# ----------------------------------------------------------------------------
patch_cron_hook() {
    if [ ! -f "$CRON_FILE" ]; then
        printf "${R}[!] Файл cron $CRON_FILE не найден — автообновление не установилось?${N}\n"
        return 1
    fi

    # Уже внедрён?
    if grep -q 'podkop-patch-hook.sh' "$CRON_FILE"; then
        printf "${Y}[!] Хук уже присутствует в cron. Пропускаем.${N}\n"
        return 0
    fi

    if ! TMP_FILE="$(mktemp)"; then
        printf "${R}[ FAILED ] Не удалось создать временный файл в /tmp${N}\n"
        return 1
    fi

    # К каждой строке, вызывающей автообновлятор Подкопа и ещё не содержащей
    # вызов хука, дописываем `; sh /root/podkop-patch-hook.sh`.
    awk '
        /\/root\/podkop-auto-update\.sh/ && $0 !~ /podkop-patch-hook\.sh/ {
            $0 = $0 " ; sh /root/podkop-patch-hook.sh"
        }
        { print }
    ' "$CRON_FILE" > "$TMP_FILE"

    if ! grep -q 'podkop-patch-hook.sh' "$TMP_FILE"; then
        printf "${R}[!] Не найдена строка автообновления Подкопа в cron — хук не внедрён.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 1
    fi

    cat "$TMP_FILE" > "$CRON_FILE"
    rm -f "$TMP_FILE"
    TMP_FILE=""

    # Перечитываем crontab.
    /etc/init.d/cron restart >/dev/null 2>&1 || true

    printf "${G}[ OK ] Хук внедрён в cron — патчи будут накатываться после ночного обновления.${N}\n"
    return 0
}

# ----------------------------------------------------------------------------
#  Пункт меню 3 — установка автообновления irat25 + внедрение хука.
# ----------------------------------------------------------------------------
run_setup_autoupdate() {
    printf "\n${C}[*] Установка полной автоматизации (автообновление + хук патчей)...${N}\n"

    # 1. Базовая структура автообновления от irat25.
    if ! TMP_FILE="$(mktemp)"; then
        printf "${R}[ FAILED ] Не удалось создать временный файл в /tmp${N}\n"
        return 1
    fi

    printf "${C}[*] Загрузка установщика автообновления (irat25)...${N}\n"
    if ! download_script "$PODKOP_AUTOUPDATE_INSTALL_URL" "$TMP_FILE"; then
        printf "${R}[ FAILED ] Не удалось загрузить установщик автообновления.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 1
    fi

    printf "${C}[*] Установка базового автообновления...${N}\n"
    if ! sh "$TMP_FILE"; then
        printf "${R}[ FAILED ] Установщик автообновления завершился с ошибкой.${N}\n"
        rm -f "$TMP_FILE"
        TMP_FILE=""
        return 1
    fi
    rm -f "$TMP_FILE"
    TMP_FILE=""
    printf "${G}[ OK ] Базовое автообновление установлено.${N}\n"

    # 2. Генерация хук-скрипта.
    printf "${C}[*] Генерация hook-скрипта %s...${N}\n" "$HOOK_SCRIPT"
    if ! write_hook_script; then
        printf "${R}[ FAILED ] Не удалось записать hook-скрипт.${N}\n"
        return 1
    fi
    # Проверяем синтаксис сгенерированного хука.
    if ! sh -n "$HOOK_SCRIPT" >/dev/null 2>&1; then
        printf "${R}[ FAILED ] Сгенерированный hook-скрипт не проходит проверку синтаксиса.${N}\n"
        return 1
    fi
    printf "${G}[ OK ] Hook-скрипт создан и проверен.${N}\n"

    # 3. Внедрение хука в cron.
    printf "${C}[*] Внедрение хука в cron...${N}\n"
    if ! patch_cron_hook; then
        return 1
    fi

    printf "${G}[ OK ] Полная автоматизация настроена.${N}\n"
    printf "${C}    Лог фонового хука: /tmp/podkop-patch-hook.log${N}\n"
    return 0
}

# ----------------------------------------------------------------------------
#  Пункт меню 5 — перезапуск Podkop.
# ----------------------------------------------------------------------------
run_restart_podkop() {
    printf "\n${C}[*] Перезапуск службы Podkop...${N}\n"

    if [ -n "$PODKOP_INIT" ]; then
        if "$PODKOP_INIT" restart; then
            printf "${C}[*] Ожидание инициализации (2 сек)...${N}\n"
            sleep 2
            printf "${G}[ OK ] Служба перезапущена.${N}\n"
            return 0
        fi
        printf "${R}[ FAILED ] Ошибка при перезапуске через init-скрипт.${N}\n"
        return 1
    elif command -v podkop >/dev/null 2>&1; then
        if podkop restart; then
            sleep 2
            printf "${G}[ OK ] Служба перезапущена.${N}\n"
            return 0
        fi
        printf "${R}[ FAILED ] Ошибка при перезапуске через 'podkop restart'.${N}\n"
        return 1
    else
        printf "${R}[ FAILED ] Не найден способ перезапуска Podkop.${N}\n"
        return 1
    fi
}

# ----------------------------------------------------------------------------
#  Пункт меню 6 — диагностика Podkop global_check.
# ----------------------------------------------------------------------------
run_global_check() {
    printf "\n${C}[*] Диагностика (podkop global_check)...${N}\n"

    if ! command -v podkop >/dev/null 2>&1; then
        printf "${R}[ FAILED ] Команда 'podkop' не найдена.${N}\n"
        return 1
    fi

    if podkop global_check; then
        printf "${G}[ OK ] global_check выполнен.${N}\n"
        return 0
    else
        printf "${Y}[ WARN ] global_check завершился с ошибкой!${N}\n"
        return 1
    fi
}

# ----------------------------------------------------------------------------
#  Пункт меню 4 — полный ручной конвейер обслуживания.
#    Обновление Подкопа -> xHTTP -> curl-патч -> sing-box -> restart -> check
# ----------------------------------------------------------------------------
run_full_maintenance() {
    printf "\n${C}========== Full Maintenance ==========${N}\n"

    run_update_podkop  || printf "${Y}[!] Шаг обновления Подкопа завершился с ошибкой, продолжаем.${N}\n"
    run_xhttp_patch    || printf "${Y}[!] Шаг патча xHTTP завершился с ошибкой, продолжаем.${N}\n"
    run_my_curl_patch  || printf "${Y}[!] Шаг curl-патча завершился с ошибкой, продолжаем.${N}\n"
    run_update_singbox || printf "${Y}[!] Шаг обновления sing-box завершился с ошибкой, продолжаем.${N}\n"
    run_restart_podkop || printf "${Y}[!] Шаг перезапуска завершился с ошибкой, продолжаем.${N}\n"
    run_global_check   || printf "${Y}[!] global_check завершился с предупреждением.${N}\n"

    printf "${G}[ OK ] Конвейер обслуживания завершён.${N}\n"
    return 0
}

# ----------------------------------------------------------------------------
#  Интерактивное меню
# ----------------------------------------------------------------------------
show_menu() {
    printf "\n"
    printf "${C}====================================${N}\n"
    printf "${C}   Podkop Unified Maintenance Tool  ${N}\n"
    printf "${C}====================================${N}\n"
    printf "\n"
    printf "  ${Y}1)${N} Update sing-box (EikeiDev)\n"
    printf "  ${Y}2)${N} Apply xHTTP & My curl patch\n"
    printf "  ${Y}3)${N} Setup Full Auto-Update (+ cron hook)\n"
    printf "  ${Y}4)${N} Run Full Maintenance\n"
    printf "  ${Y}5)${N} Restart Podkop\n"
    printf "  ${Y}6)${N} Podkop global_check\n"
    printf "  ${Y}0)${N} Exit\n"
    printf "\n"
    printf "${C}[?] Выберите пункт меню (0-6): ${N}"
}

while true; do
    show_menu
    read -r choice || choice="0"
    case "$choice" in
        1) run_update_singbox;    wait_key ;;
        2) run_apply_patches;     wait_key ;;
        3) run_setup_autoupdate;  wait_key ;;
        4) run_full_maintenance;  wait_key ;;
        5) run_restart_podkop;    wait_key ;;
        6) run_global_check;      wait_key ;;
        0)
            printf "${G}[*] Выход.${N}\n"
            break
            ;;
        *)
            printf "${R}[!] Неверный ввод. Выберите число от 0 до 6.${N}\n"
            wait_key
            ;;
    esac
done
