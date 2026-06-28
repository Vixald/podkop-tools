#!/bin/sh
# Podkop curl download patch
# - Заменяет функцию download_to_file() целиком на реализацию с curl
# - Валидирует исходный код функции СТРОГО внутри её границ перед заменой
# - Автоматически очищает временные файлы и производит откат при сбоях

HELPERS="/usr/lib/podkop/helpers.sh"
BACKUP_DIR="/root"
MARKER_COMMENT="# PODKOP-CURL-PATCH"

log()  { echo "[podkop-curl-patch] $1"; }
warn() { echo "[podkop-curl-patch] WARN: $1" >&2; }
err()  { echo "[podkop-curl-patch] ERROR: $1" >&2; }

# Инициализация путей временных файлов (для функции cleanup)
NEW_FUNC_FILE="/tmp/_podkop_curl_func.$$"
TMP_OUTPUT="/tmp/helpers.sh.patched.$$"

# Автоматический сборщик мусора при любом выходе из скрипта
cleanup() {
    rm -f "$NEW_FUNC_FILE" "$TMP_OUTPUT"
}
trap cleanup EXIT INT TERM

# Безопасная функция отката (проверяет физическое наличие бэкапа перед восстановлением)
rollback() {
    if [ -f "${HELPERS}.bak" ]; then
        mv -f "${HELPERS}.bak" "$HELPERS"
    fi
}

# -- 1. Предварительные проверки окружения -------------------------------------

if [ ! -f "$HELPERS" ]; then
    err "Файл не найден: $HELPERS — Podkop установлен?"
    exit 1
fi

# Проверка идемпотентности
if grep -q "$MARKER_COMMENT" "$HELPERS"; then
    log "Патч curl-download уже установлен. Пропускаю."
    exit 0
fi

# -- 2. Создание резервных копий -----------------------------------------------

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="$BACKUP_DIR/helpers.sh.backup.$TS"
if ! cp "$HELPERS" "$BACKUP_FILE"; then
    err "Не удалось создать резервную копию в каталог $BACKUP_DIR."
    exit 1
fi
log "Создана системная резервная копия: $BACKUP_FILE"

# Локальный бэкап для быстрого отката силами пользователя и атомарного восстановления
if ! cp "$HELPERS" "${HELPERS}.bak"; then
    err "Не удалось создать бэкап ${HELPERS}.bak"
    exit 1
fi

# -- 3. Формирование новой реализации функции ----------------------------------

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

# -- 4. Избирательный контроль и замена блока функции через awk ----------------

# awk-скрипт пропускает вывод старой функции и делает инъекцию новой только
# ПОСЛЕ того, как функция дочитана до конца и внутри нее верифицирован оригинальный wget.
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
        # Ищем маркер оригинального wget строго внутри границ функции
        if ($0 ~ /wget -O[[:space:]]*"\$filepath"[[:space:]]*"\$url"/) {
            has_target_wget = 1;
        }

        t = $0;
        while (sub(/\{/, "", t)) braces++;
        while (sub(/\}/, "", t)) braces--;
        
        # Нашли закрывающую скобку функции
        if (braces <= 0) {
            in_func = 0;
            
            if (has_target_wget == 1) {
                # Валидация успешна: делаем инъекцию новой функции
                while ((getline line < func_file) > 0) { print line }
                close(func_file);
            } else {
                # Структура нарушена: выходим со стандартным POSIX-кодом ошибки
                exit 2;
            }
        }
    }
}
END {
    # Функция вообще не найдена в файле
    if (replaced != 1) {
        exit 1;
    }
}
' "$HELPERS" > "$TMP_OUTPUT"

AWK_RES=$?

# Контроль кодов возврата анализатора структуры
if [ "$AWK_RES" -eq 2 ]; then
    err "ОШИБКА: Структура download_to_file() изменена в новой версии Podkop."
    err "Оригинальный вызов wget внутри границ функции не найден. Отмена операции."
    rollback
    exit 1
elif [ "$AWK_RES" -ne 0 ]; then
    err "Ошибка: Функция download_to_file() не найдена или файл имеет неверную структуру. Отмена."
    rollback
    exit 1
fi

# -- 5. Верификация синтаксиса и структуры (Rollback) --------------------------

# Проверка на общую синтаксическую корректность в BusyBox
if ! ash -n "$TMP_OUTPUT" 2>/dev/null; then
    err "Синтаксическая проверка измененного файла провалена. Откат изменений."
    rollback
    exit 1
fi

# Проверка физического присутствия функции в результирующем файле
if ! grep -q '^[[:space:]]*download_to_file\(\)[[:space:]]*\{' "$TMP_OUTPUT"; then
    err "Критическая ошибка: Сигнатура download_to_file() утеряна после патча. Откат."
    rollback
    exit 1
fi

# Проверка фиксации маркера
if ! grep -q "$MARKER_COMMENT" "$TMP_OUTPUT"; then
    err "Критическая ошибка: Маркер патча не зафиксирован в коде функции. Откат."
    rollback
    exit 1
fi

# -- 6. Применение изменений ---------------------------------------------------

if mv -f "$TMP_OUTPUT" "$HELPERS"; then
    log "Патч успешно применен. Функция download_to_file() обновлена на curl."
    log "Локальная резервная копия сохранена в ${HELPERS}.bak"
    exit 0
else
    err "Не удалось записать изменения в $HELPERS. Восстановление оригинала."
    rollback
    exit 1
fi