#!/bin/sh
# =============================================================================
#  Podkop Unified Maintenance Tool
# -----------------------------------------------------------------------------
#  Единый монолитный установщик/обслуживатель для OpenWrt (BusyBox /bin/sh).
#  Объединяет:
#     1. Автообновление Podkop            (irat25/podkop-auto-update)
#     2. Обновление sing-box              (EikeiDev/OpenWRT-sing-box-extended)
#     3. Патч xHTTP                       (moix89/podkop-xhttp-patch)
#     4. Меню/цвета                       (Vixald/podkop-tools)
#     5. Встроенный патч wget -> curl     (Vixald/podkop-tools/patches/20-curl-download.sh)
# =============================================================================

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
PODKOP_AUTOUPDATE_INSTALL_URL="https://raw.githubusercontent.com/irat25/podkop-auto-update/main/install.sh"
PODKOP_UPDATE_URL="https://raw.githubusercontent.com/irat25/podkop-auto-update/main/files/root/podkop-auto-update.sh"
SINGBOX_URL="https://raw.githubusercontent.com/EikeiDev/OpenWRT-sing-box-extended/refs/heads/main/install.sh"
XHTTP_URL="https://raw.githubusercontent.com/moix89/podkop-xhttp-patch/main/install.sh"

# ----------------------------------------------------------------------------
#  Системные пути
# ----------------------------------------------------------------------------
CRON_FILE="/etc/crontabs/root"
HOOK_SCRIPT="/root/podkop-patch-hook.sh"
HELPERS="/usr/lib/podkop/helpers.sh"
NFT_KILLSWITCH_SCRIPT="/usr/share/podkop_killswitch.nft"

# ----------------------------------------------------------------------------
#  Управление временными файлами и очистка
# ----------------------------------------------------------------------------
TMP_FILE=""

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

wait_key() {
    printf "\n${Y}Нажмите Enter для продолжения...${N}"
    read -r _
}

# ----------------------------------------------------------------------------
#  Универсальная функция загрузки
# ----------------------------------------------------------------------------
download_script() {
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

    if [ ! -f "$2" ] || [ ! -s "$2" ]; then
        printf "${R}[!] Ошибка: файл не создан или пустой после загрузки: $1${N}\n"
        rm -f "$2" 2>/dev/null
        return 1
    fi

    if head -n 20 "$2" 2>/dev/null | grep -qiE '<html|<body|<!DOCTYPE|404: Not Found|Bad Gateway|Internal Server Error|Too Many Requests|rate limit exceeded|Forbidden|Unauthorized|403:|429:|AccessDenied|Request blocked|abuse detection'; then
        printf "${R}[!] Ошибка: GitHub/Сервер вернул блокировку, лимит или ошибку вместо скрипта.${N}\n"
        printf "${Y}    URL: $1${N}\n"
        rm -f "$2"
        return 1
    fi

    if ! sh -n "$2" >/dev/null 2>&1; then
        printf "${R}[!] Ошибка: скачанный файл не проходит проверку синтаксиса: $1${N}\n"
        rm -f "$2"
        return 1
    fi

    return 0
}

# ----------------------------------------------------------------------------
#  Встроенный код патча wget -> curl (20-curl-download.sh)
# ----------------------------------------------------------------------------
emit_curl_patch() {
cat <<'CURL_PATCH_EOF'
#!/bin/sh
HELPERS="/usr/lib/podkop/helpers.sh"
BACKUP_DIR="/root"
MARKER_COMMENT="# PODKOP-CURL-PATCH"

cp_log()  { echo "[podkop-curl-patch] $1"; }
cp_warn() { echo "[podkop-curl-patch] WARN: $1" >&2; }
cp_err()  { echo "[podkop-curl-patch] ERROR: $1" >&2; }

NEW_FUNC_FILE=""
TMP_OUTPUT=""
cp_cleanup() {
    [ -n "$NEW_FUNC_FILE" ] && rm -f "$NEW_FUNC_FILE"
    [ -n "$TMP_OUTPUT" ] && rm -f "$TMP_OUTPUT"
}
trap cp_cleanup EXIT INT TERM

rollback() {
    if [ -f "${HELPERS}.bak" ]; then
        mv -f "${HELPERS}.bak" "$HELPERS"
    fi
}

if [ ! -f "$HELPERS" ]; then
    cp_err "Файл не найден: $HELPERS"
    exit 1
fi

if grep -q "$MARKER_COMMENT" "$HELPERS"; then
    cp_log "Патч curl-download уже установлен. Пропускаем."
    exit 0
fi

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="$BACKUP_DIR/helpers.sh.backup.$TS"
if ! cp "$HELPERS" "$BACKUP_FILE"; then
    exit 1
fi

if ! cp "$HELPERS" "${HELPERS}.bak"; then
    exit 1
fi

if ! NEW_FUNC_FILE="$(mktemp)" || ! TMP_OUTPUT="$(mktemp)"; then
    rollback
    exit 1
fi

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

awk -v func_file="$NEW_FUNC_FILE" '
BEGIN { in_func = 0; braces = 0; replaced = 0; has_target_wget = 0; }
{
    if (!in_func) {
        if ($0 ~ /^[[:space:]]*download_to_file\(\)[[:space:]]*\{/) {
            in_func = 1; braces = 0; replaced++;
            t = $0;
            while (sub(/\{/, "", t)) braces++;
            while (sub(/\}/, "", t)) braces--;
            if (braces == 0 && in_func) {
                in_func = 0;
                if (has_target_wget == 1) {
                    while ((getline line < func_file) > 0) { print line }
                    close(func_file);
                } else { exit 2; }
            }
            next;
        }
        print $0;
    } else {
        if ($0 ~ /wget -O[[:space:]]*"\$filepath"[[:space:]]*"\$url"/) { has_target_wget = 1; }
        t = $0;
        while (sub(/\{/, "", t)) braces++;
        while (sub(/\}/, "", t)) braces--;
        if (braces <= 0) {
            in_func = 0;
            if (has_target_wget == 1) {
                while ((getline line < func_file) > 0) { print line }
                close(func_file);
            } else { exit 2; }
        }
    }
}
END { if (replaced != 1) exit 1; }
' "$HELPERS" > "$TMP_OUTPUT"

AWK_RES=$?
if [ "$AWK_RES" -ne 0 ]; then
    rollback
    exit 1
fi

if ! sh -n "$TMP_OUTPUT" >/dev/null 2>&1 || ! grep -q "$MARKER_COMMENT" "$TMP_OUTPUT"; then
    rollback
    exit 1
fi

if mv -f "$TMP_OUTPUT" "$HELPERS"; then
    exit 0
else
    rollback
    exit 1
fi
CURL_PATCH_EOF
}

run_my_curl_patch() {
    printf "\n${C}[*] Применение встроенного curl-патча...${N}\n"
    if ! TMP_FILE="$(mktemp)"; then return 1; fi
    emit_curl_patch > "$TMP_FILE"
    if sh "$TMP_FILE"; then
        printf "${G}[ OK ] Встроенный curl-патч применён.${N}\n"
        rm -f "$TMP_FILE"; TMP_FILE=""; return 0
    else
        printf "${R}[ FAILED ] Ошибка curl-патча.${N}\n"
        rm -f "$TMP_FILE"; TMP_FILE=""; return 1
    fi
}

run_xhttp_patch() {
    printf "\n${C}[*] Применение патча xHTTP (moix89)...${N}\n"
    if ! TMP_FILE="$(mktemp)"; then return 1; fi
    if ! download_script "$XHTTP_URL" "$TMP_FILE"; then
        rm -f "$TMP_FILE"; TMP_FILE=""; return 1
    fi
    if sh "$TMP_FILE"; then
        printf "${G}[ OK ] Патч xHTTP применён.${N}\n"
        rm -f "$TMP_FILE"; TMP_FILE=""; return 0
    else
        printf "${R}[ FAILED ] Ошибка патча xHTTP.${N}\n"
        rm -f "$TMP_FILE"; TMP_FILE=""; return 1
    fi
}

run_update_singbox() {
    printf "\n${C}[*] Обновление sing-box (EikeiDev)...${N}\n"
    if ! TMP_FILE="$(mktemp)"; then return 1; fi
    if ! download_script "$SINGBOX_URL" "$TMP_FILE"; then
        rm -f "$TMP_FILE"; TMP_FILE=""; return 1
    fi
    if sh "$TMP_FILE"; then
        printf "${G}[ OK ] sing-box обновлён.${N}\n"
        rm -f "$TMP_FILE"; TMP_FILE=""; return 0
    else
        printf "${R}[ FAILED ] Ошибка обновления sing-box.${N}\n"
        rm -f "$TMP_FILE"; TMP_FILE=""; return 1
    fi
}

run_apply_patches() {
    rc=0
    run_xhttp_patch || rc=1
    run_my_curl_patch || rc=1
    return "$rc"
}

run_update_podkop() {
    printf "\n${C}[*] Обновление Podkop...${N}\n"
    if ! TMP_FILE="$(mktemp)"; then return 1; fi
    if ! download_script "$PODKOP_UPDATE_URL" "$TMP_FILE"; then
        rm -f "$TMP_FILE"; TMP_FILE=""; return 1
    fi
    if sh "$TMP_FILE"; then
        printf "${G}[ OK ] Podkop обновлён.${N}\n"
        rm -f "$TMP_FILE"; TMP_FILE=""; return 0
    else
        printf "${R}[ FAILED ] Ошибка обновления Podkop.${N}\n"
        rm -f "$TMP_FILE"; TMP_FILE=""; return 1
    fi
}

write_hook_script() {
    cat > "$HOOK_SCRIPT" <<'HOOK_HEADER_EOF'
#!/bin/sh
HOOK_LOG="/tmp/podkop-patch-hook.log"
hlog() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$HOOK_LOG"; }
XHTTP_URL="https://raw.githubusercontent.com/moix89/podkop-xhttp-patch/main/install.sh"
hlog "=== hook start ==="

if HK_TMP="$(mktemp)"; then
    if command -v curl >/dev/null 2>&1; then curl --fail --silent --show-error --location -o "$HK_TMP" "$XHTTP_URL"
    elif command -v wget >/dev/null 2>&1; then wget -qO "$HK_TMP" "$XHTTP_URL"
    fi
    if [ -s "$HK_TMP" ] && ! head -n 20 "$HK_TMP" 2>/dev/null | grep -qiE '<html|<body|<!DOCTYPE|404: Not Found|Too Many Requests|rate limit exceeded|Forbidden|AccessDenied|Request blocked' && sh -n "$HK_TMP" >/dev/null 2>&1; then
        if sh "$HK_TMP" >> "$HOOK_LOG" 2>&1; then hlog "xHTTP patch: OK"
        else hlog "xHTTP patch: FAILED"
        fi
    else hlog "xHTTP patch: пропущен"
    fi
    rm -f "$HK_TMP"
fi
HOOK_HEADER_EOF
    emit_curl_patch >> "$HOOK_SCRIPT"
}

patch_cron_hook() {
    if [ ! -f "$CRON_FILE" ]; then return 1; fi
    if grep -q 'podkop-patch-hook.sh' "$CRON_FILE"; then return 0; fi
    if ! TMP_FILE="$(mktemp)"; then return 1; fi

    awk '/\/root\/podkop-auto-update\.sh/ && $0 !~ /podkop-patch-hook\.sh/ { $0 = $0 " ; sh /root/podkop-patch-hook.sh" } { print }' "$CRON_FILE" > "$TMP_FILE"
    
    if ! grep -q 'podkop-patch-hook.sh' "$TMP_FILE"; then
        printf "${R}[!] Ошибка: Не удалось внедрить хук в структуру cron.${N}\n"
        rm -f "$TMP_FILE"
        return 1
    fi

    cat "$TMP_FILE" > "$CRON_FILE"
    rm -f "$TMP_FILE"; TMP_FILE=""
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    return 0
}

# ----------------------------------------------------------------------------
#  Пункт меню 3 — Идеальный KillSwitch через безопасный uci firewall include
# ----------------------------------------------------------------------------
run_setup_autoupdate() {
    printf "\n${C}[*] Установка полной автоматизации (автообновление + хук патчей)...${N}\n"

    if ! TMP_FILE="$(mktemp)"; then return 1; fi
    if ! download_script "$PODKOP_AUTOUPDATE_INSTALL_URL" "$TMP_FILE" || ! sh "$TMP_FILE"; then
        rm -f "$TMP_FILE"; TMP_FILE=""; return 1
    fi
    rm -f "$TMP_FILE"; TMP_FILE=""

    write_hook_script
    patch_cron_hook || return 1

    printf "${C}[*] Интеграция Умного Hard KillSwitch в официальную подсистему fw4 include...${N}\n"
    
    if [ -f "/etc/init.d/podkop_killswitch" ]; then
        /etc/init.d/podkop_killswitch disable >/dev/null 2>&1 || true
        rm -f "/etc/init.d/podkop_killswitch"
    fi
    rm -f /etc/rc.d/S*podkop_killswitch 2>/dev/null || true

    # Генерируем shell-скрипт инклуда С ИДЕМПОТЕНТНЫМИ ПРОВЕРКАМИ СУЩЕСТВОВАНИЯ ПРАВИЛ И ЦЕПОЧЕК
    cat << 'EOF' > "$NFT_KILLSWITCH_SCRIPT"
#!/bin/sh

# 1. Проверяем и защищаем forward цепочку
if nft list chain inet fw4 forward 2>/dev/null | grep -q "inet fw4"; then
    if ! nft list chain inet fw4 forward 2>/dev/null | grep -q "198.18.0.0/15"; then
        nft add rule inet fw4 forward ip daddr 198.18.0.0/15 drop 2>/dev/null
    fi
fi

# 2. Проверяем и защищаем output цепочку
if nft list chain inet fw4 output 2>/dev/null | grep -q "inet fw4"; then
    if ! nft list chain inet fw4 output 2>/dev/null | grep -q "198.18.0.0/15"; then
        nft add rule inet fw4 output ip daddr 198.18.0.0/15 drop 2>/dev/null
    fi
fi

# 3. Динамическая проверка filter_forward (зависит от конкретной версии OpenWrt)
if nft list chain inet fw4 filter_forward 2>/dev/null | grep -q "inet fw4"; then
    if ! nft list chain inet fw4 filter_forward 2>/dev/null | grep -q "198.18.0.0/15"; then
        nft add rule inet fw4 filter_forward oifname "wan" ip daddr 198.18.0.0/15 drop 2>/dev/null
    fi
fi
EOF

    # Делаем скрипт-инклуд исполняемым для fw4
    chmod 0755 "$NFT_KILLSWITCH_SCRIPT"

    # Регистрируем инклуд через UCI API
    if ! uci show firewall | grep -q "podkop_ks"; then
        uci -q batch <<UCI_EOF
set firewall.podkop_ks=include
set firewall.podkop_ks.type='script'
set firewall.podkop_ks.path='$NFT_KILLSWITCH_SCRIPT'
set firewall.podkop_ks.family='any'
set firewall.podkop_ks.reload='1'
commit firewall
UCI_EOF
    fi

    /etc/init.d/firewall restart >/dev/null 2>&1 || true
    printf "${G}[ OK ] Чистый KillSwitch (ориентированный на FakeIP) успешно активирован в uci firewall.${N}\n"

    return 0
}

run_restart_podkop() {
    printf "\n${C}[*] Перезапуск службы Podkop...${N}\n"
    if [ -n "$PODKOP_INIT" ] && "$PODKOP_INIT" restart; then
        sleep 2; printf "${G}[ OK ] Служба перезапущена.${N}\n"; return 0
    elif command -v podkop >/dev/null 2>&1 && podkop restart; then
        sleep 2; printf "${G}[ OK ] Служба перезапущена.${N}\n"; return 0
    fi
    return 1
}

run_global_check() {
    printf "\n${C}[*] Диагностика (podkop global_check)...${N}\n"
    if command -v podkop >/dev/null 2>&1 && podkop global_check; then
        printf "${G}[ OK ] global_check выполнен.${N}\n"; return 0
    fi
    return 1
}

# ----------------------------------------------------------------------------
#  Пункт меню 4 — Идеальный логический конвейер обслуживания
# ----------------------------------------------------------------------------
run_full_maintenance() {
    printf "\n${C}========== MAINTENANCE CONVEYER ==========${N}\n"

    run_update_singbox || printf "${Y}[!] Обновление ядра sing-box завершилось с ошибкой, продолжаем.${N}\n"
    run_update_podkop  || printf "${Y}[!] Обновление структуры Podkop завершилось с ошибкой, продолжаем.${N}\n"
    run_xhttp_patch    || printf "${Y}[!] Накатывание патча xHTTP завершилось с ошибкой, продолжаем.${N}\n"
    run_my_curl_patch  || printf "${Y}[!] Накатывание curl-патча завершилось с ошибкой, продолжаем.${N}\n"
    run_restart_podkop || printf "${Y}[!] Перезапуск системы завершился с ошибкой, продолжаем.${N}\n"
    run_global_check   || printf "${Y}[!] Финальный global_check выявил предупреждения.${N}\n"

    printf "${G}[ OK ] Конвейер обслуживания полностью завершён.${N}\n"
    return 0
}

show_menu() {
    printf "\n"
    printf "${C}====================================${N}\n"
    printf "${C}   Podkop Unified Maintenance Tool  ${N}\n"
    printf "${C}====================================${N}\n"
    printf "\n"
    printf "  ${Y}1)${N} Update sing-box (EikeiDev)\n"
    printf "  ${Y}2)${N} Apply xHTTP & My curl patch\n"
    printf "  ${Y}3)${N} Setup Full Auto-Update (+ чистый KillSwitch fw4)\n"
    printf "  ${Y}4)${N} Run Full Maintenance (Правильный порядок)\n"
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
        0) printf "${G}[*] Выход.${N}\n"; break ;;
        *) printf "${R}[!] Неверный ввод.${N}\n"; wait_key ;;
    esac
done
