#!/bin/sh
# =============================================================================
#   Podkop Unified Maintenance Tool (Official Release v1.2.1-GOLD)
# -----------------------------------------------------------------------------
#   Единый монолитный установщик/обслуживатель для OpenWrt (BusyBox /bin/sh).
# =============================================================================

set -u

# ----------------------------------------------------------------------------
#   ANSI-цвета
# ----------------------------------------------------------------------------
R="\033[1;31m"   # красный  — ошибки
G="\033[1;32m"   # зелёный  — успех
Y="\033[1;33m"   # жёлтый   — предупреждения
C="\033[1;36m"   # голубой  — информация
N="\033[0m"      # сброс

# ----------------------------------------------------------------------------
#   Источники (raw-ссылки)
# ----------------------------------------------------------------------------
PODKOP_AUTOUPDATE_INSTALL_URL="https://raw.githubusercontent.com/irat25/podkop-auto-update/main/install.sh"
PODKOP_UPDATE_URL="https://raw.githubusercontent.com/irat25/podkop-auto-update/main/files/root/podkop-auto-update.sh"
SINGBOX_URL="https://raw.githubusercontent.com/EikeiDev/OpenWRT-sing-box-extended/refs/heads/main/install.sh"
XHTTP_URL="https://raw.githubusercontent.com/moix89/podkop-xhttp-patch/main/install.sh"

# ----------------------------------------------------------------------------
#   Системные пути
# ----------------------------------------------------------------------------
CRON_FILE="/etc/crontabs/root"
HOOK_SCRIPT="/root/podkop-patch-hook.sh"
HELPERS="/usr/lib/podkop/helpers.sh"
NFT_KILLSWITCH_SCRIPT="/usr/share/podkop_killswitch.nft"

# ----------------------------------------------------------------------------
#   Управление временными файлами и очистка
# ----------------------------------------------------------------------------
TMP_FILE=""

cleanup() {
    [ -n "${TMP_FILE:-}" ] && rm -f "$TMP_FILE"
    TMP_FILE=""
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------------
#   Определение подсистемы Podkop
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
#   Универсальная функция загрузки (с сетевыми таймаутами и авто-повторами)
# ----------------------------------------------------------------------------
download_script() {
    if command -v curl >/dev/null 2>&1; then
        if ! curl --fail --silent --show-error --location --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 -o "$2" "$1"; then
            printf "${R}[!] Ошибка: curl не смог скачать $1${N}\n"
            rm -f "$2"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -T 60 -qO "$2" "$1"; then
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

    if head -n 20 "$2" 2>/dev/null | grep -qiE '<html|<body|<!DOCTYPE|404: Not Found|Bad Gateway|Internal Server Error|Too Many Requests|rate limit exceeded|Forbidden|Unauthorized|403:|429:|502:|503:|Server Error|Service Unavailable|AccessDenied|Request blocked|abuse detection'; then
        printf "${R}[!] Ошибка: GitHub/Сервер вернул ошибку, лимит или отказ вместо скрипта.${N}\n"
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
#   Встроенный код патча wget -> curl (20-curl-download.sh)
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

check_nft_rule() {
    if nft list chain inet fw4 "$1" >/dev/null 2>&1; then
        if nft list chain inet fw4 "$1" 2>/dev/null | grep -Fq "ip daddr 198.18.0.0/15 drop"; then
            return 0
        fi
    fi
    return 1
}

# ----------------------------------------------------------------------------
#   Пункт меню 3 — Идеальный Железобетонный KillSwitch с автоопределением цепочек
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

    printf "${C}[*] Анализ архитектуры файрвола ядра Linux...${N}\n"
    
    TARGET_FORWARD_CHAIN=""
    if nft list chain inet fw4 raw_prerouting >/dev/null 2>&1; then
        TARGET_FORWARD_CHAIN="raw_prerouting"
        printf "${G}[ INFO ] Обнаружена оптимальная подсистема RAW. Аппаратное ускорение (Offloading) будет обойдено.${N}\n"
    elif nft list chain inet fw4 forward >/dev/null 2>&1; then
        TARGET_FORWARD_CHAIN="forward"
        printf "${Y}[ INFO ] Подсистема RAW не найдена. Откат на стандартную фильтрацию цепочки FORWARD.${N}\n"
    else
        printf "${R}[ FAILED ] Ошибка несовместимости: в таблице fw4 не найдено ни raw_prerouting, ни forward!${N}\n"
        return 1
    fi

    printf "${C}[*] Интеграция Безусловного Hard KillSwitch в подсистему fw4 include...${N}\n"
    
    if [ -f "/etc/init.d/podkop_killswitch" ]; then
        /etc/init.d/podkop_killswitch disable >/dev/null 2>&1 || true
        rm -f "/etc/init.d/podkop_killswitch"
    fi
    rm -f /etc/rc.d/S*podkop_killswitch 2>/dev/null || true

    # Динамическая генерация nft-скрипта на основе результатов сканирования ядра
    cat << EOF > "$NFT_KILLSWITCH_SCRIPT"
#!/bin/sh

if nft list chain inet fw4 $TARGET_FORWARD_CHAIN >/dev/null 2>&1; then
    if ! nft list chain inet fw4 $TARGET_FORWARD_CHAIN 2>/dev/null | grep -Fq "ip daddr 198.18.0.0/15 drop"; then
        nft insert rule inet fw4 $TARGET_FORWARD_CHAIN ip daddr 198.18.0.0/15 drop 2>/dev/null
    fi
fi

if nft list chain inet fw4 output >/dev/null 2>&1; then
    if ! nft list chain inet fw4 output 2>/dev/null | grep -Fq "ip daddr 198.18.0.0/15 drop"; then
        nft insert rule inet fw4 output ip daddr 198.18.0.0/15 drop 2>/dev/null
    fi
fi
EOF

    chmod 0755 "$NFT_KILLSWITCH_SCRIPT"

    # Чистый UCI без рудиментов
    uci -q batch <<UCI_EOF
set firewall.podkop_ks=include
set firewall.podkop_ks.type='script'
set firewall.podkop_ks.path='$NFT_KILLSWITCH_SCRIPT'
commit firewall
UCI_EOF

    if ! /etc/init.d/firewall restart >/dev/null 2>&1; then
        printf "${Y}[ WARN ] Системная команда перезапуска firewall вернула ошибку.${N}\n"
        printf "${Y}         Переходим к прямой диагностике рантайма nftables...${N}\n"
    fi
    
    res_fw=0
    res_out=0
    
    check_nft_rule "$TARGET_FORWARD_CHAIN" && res_fw=1
    check_nft_rule "output"                 && res_out=1

    # Высокоточный информативный вердикт
    if [ "$res_fw" -eq 1 ] && [ "$res_out" -eq 1 ]; then
        printf "${G}[ OK ] Полная автоматизация настроена. Абсолютный KillSwitch ($TARGET_FORWARD_CHAIN & Output) активен!${N}\n"
    else
        printf "${R}[ FAILED ] Ошибка! Железобетонная защита не закрепилась в целевых точках!${N}\n"
        [ "$res_fw"  -eq 0 ] && printf "${R}           - Нарушена целостность транзитной цепочки ($TARGET_FORWARD_CHAIN)${N}\n"
        [ "$res_out" -eq 0 ] && printf "${R}           - Нарушена целостность цепочки локального вывода (OUTPUT)${N}\n"
        printf "${Y}           Проверьте синтаксис таблиц nftables вручную или перезагрузите роутер.${N}\n"
    fi

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
#   Пункт меню 4 — Мягкий конвейер обслуживания с автопилотом деплоя
# ----------------------------------------------------------------------------
run_full_maintenance() {
    run_setup_autoupdate || true
    
    printf "\n${C}[*] Запуск мягкого конвейера обслуживания компонентов...${N}\n"
    
    status_sb="${G}Успешно${N}"; status_pk="${G}Успешно${N}"; status_pt="${G}Успешно${N}"

    run_update_singbox || status_sb="${R}Ошибка (Пропущено)${N}"
    run_update_podkop  || status_pk="${R}Ошибка (Пропущено)${N}"
    run_apply_patches  || status_pt="${R}Ошибка (Пропущено)${N}"
    
    printf "\n${C}[*] Финализация процессов...${N}\n"
    run_restart_podkop || true
    run_global_check   || true

    printf "\n${C}====== ОТЧЕТ ОБСЛУЖИВАНИЯ ======${N}\n"
    printf " Обновление sing-box:  $status_sb\n"
    printf " Обновление Podkop:    $status_pk\n"
    printf " Применение патчей:    $status_pt\n"
    printf "${C}================================${N}\n"
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
    printf "  ${Y}4)${N} Run Full Maintenance (Все сразу одной кнопкой)\n"
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
