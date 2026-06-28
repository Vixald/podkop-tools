#!/bin/sh

# ANSI Цветовые коды для оформления вывода
R="\033[1;31m"
G="\033[1;32m"
Y="\033[1;33m"
C="\033[1;36m"
N="\033[0m"

# Константы для скачивания официальных скриптов
UPDATE_SINGBOX_URL="https://raw.githubusercontent.com/EikeiDev/OpenWRT-sing-box-extended/refs/heads/main/install.sh"
XHTTP_PATCH_URL="https://raw.githubusercontent.com/moix89/podkop-xhttp-patch/main/install.sh"

# Глобальные переменные для временных файлов
TMP_SCRIPT=""
TMP_PATCH=""

# Функция автоматической очистки временных файлов
cleanup() {
    [ -n "$TMP_SCRIPT" ] && rm -f "$TMP_SCRIPT"
    [ -n "$TMP_PATCH" ] && rm -f "$TMP_PATCH"
    TMP_SCRIPT=""
    TMP_PATCH=""
}
trap cleanup EXIT INT TERM

# 1. Надежное определение абсолютного пути к директории самого скрипта
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# 2. Комплексная проверка окружения (наличие бинарника и init-скрипта)
if [ -f "/opt/etc/init.d/podkop" ]; then
    PODKOP_INIT="/opt/etc/init.d/podkop"
elif [ -f "/etc/init.d/podkop" ]; then
    PODKOP_INIT="/etc/init.d/podkop"
else
    PODKOP_INIT=
fi

if ! command -v podkop >/dev/null 2>&1 || [ -z "$PODKOP_INIT" ]; then
    printf "${R}[!] ОШИБКА: Среда Podkop настроена неверно или не установлена.${N}\n"
    printf "${R}Требуется наличие утилиты 'podkop' в PATH и инициализационного скрипта в /etc/init.d/.${N}\n"
    exit 1
fi

# Функция ожидания нажатия Enter перед возвратом в меню
wait_key() {
    printf "\n${Y}Нажмите Enter для продолжения...${N}"
    read -r _
}

show_menu() {
    printf "\n"
    printf "${C}=========================${N}\n"
    printf "${C} Podkop Tools            ${N}\n"
    printf "${C}=========================${N}\n"
    printf "\n"
    printf "  ${Y}1)${N} Update sing-box\n"
    printf "  ${Y}2)${N} Apply patches\n"
    printf "  ${Y}3)${N} Update sing-box + Apply patches\n"
    printf "  ${Y}4)${N} Restart Podkop\n"
    printf "  ${Y}5)${N} Podkop global_check\n"
    printf "  ${Y}0)${N} Exit\n"
    printf "\n"
    printf "${C}[?] Выберите пункт меню (0-5): ${N}"
}

# Универсальная функция для скачивания файлов (аргументы: $1 - url, $2 - dest)
download_script() {
    if command -v curl >/dev/null 2>&1; then
        if ! curl --fail --silent --show-error --location -o "$2" "$1"; then
            printf "${R}[!] ОШИБКА: curl не смог скачать файл с $1${N}\n"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -qO "$2" "$1"; then
            printf "${R}[!] ОШИБКА: wget не смог скачать файл с $1${N}\n"
            return 1
        fi
    else
        printf "${R}[!] ОШИБКА: Не найден ни curl, ни wget для скачивания.${N}\n"
        return 1
    fi

    if [ ! -f "$2" ]; then
        printf "${R}[!] ОШИБКА: Файл не был создан после скачивания: $1${N}\n"
        return 1
    fi

    if [ ! -s "$2" ]; then
        printf "${R}[!] ОШИБКА: Скачанный файл оказался пустым: $1${N}\n"
        rm -f "$2"
        return 1
    fi

    # Первичная грубая проверка: отсекаем явные HTML-страницы
    if head -n 20 "$2" 2>/dev/null | grep -qiE '<!DOCTYPE|<html|<head|<body'; then
        printf "${R}[!] ОШИБКА: Вместо скрипта получена HTML-страница сервера: $1${N}\n"
        rm -f "$2"
        return 1
    fi

    # Глубокая проверка синтаксиса: отсекаем битые файлы, 404-текст и прочий мусор
    if ! sh -n "$2" >/dev/null 2>&1; then
        printf "${R}[!] ОШИБКА: Загруженный файл содержит синтаксические ошибки или поврежден: $1${N}\n"
        rm -f "$2"
        return 1
    fi

    return 0
}

run_update_sing_box() {
    printf "\n${C}[*] Запуск обновления sing-box...${N}\n"
    
    if ! TMP_SCRIPT="$(mktemp)"; then
        printf "${R}[ FAILED ] Не удалось создать временный файл в /tmp${N}\n"
        return 1
    fi

    printf "${C}[*] Скачивание официального скрипта обновления...${N}\n"
    if download_script "$UPDATE_SINGBOX_URL" "$TMP_SCRIPT"; then
        if sh "$TMP_SCRIPT"; then
            printf "${G}[ OK ] Обновление sing-box успешно завершено.${N}\n"
            rm -f "$TMP_SCRIPT"
            TMP_SCRIPT=""
            return 0
        else
            printf "${R}[ FAILED ] Ошибка при выполнении скрипта обновления sing-box.${N}\n"
            rm -f "$TMP_SCRIPT"
            TMP_SCRIPT=""
            return 1
        fi
    else
        printf "${R}[ FAILED ] Ошибка загрузки скрипта обновления sing-box.${N}\n"
        rm -f "$TMP_SCRIPT"
        TMP_SCRIPT=""
        return 1
    fi
}

run_patches() {
    printf "\n${C}[*] Автоматический поиск и применение патчей...${N}\n"
    
    if ! TMP_PATCH="$(mktemp)"; then
        printf "${R}[ FAILED ] Не удалось создать временный файл в /tmp${N}\n"
        return 1
    fi

    printf "${C}[*] Скачивание официального xHTTP патча...${N}\n"
    if download_script "$XHTTP_PATCH_URL" "$TMP_PATCH"; then
        printf "${C}[*] Выполнение патча xHTTP...${N}\n"
        if sh "$TMP_PATCH"; then
            printf "${G}[ OK ] Патч xHTTP успешно применен.${N}\n"
            rm -f "$TMP_PATCH"
            TMP_PATCH=""
        else
            printf "${R}[ FAILED ] Ошибка при выполнении xHTTP патча. Прерывание конвейера.${N}\n"
            rm -f "$TMP_PATCH"
            TMP_PATCH=""
            return 1
        fi
    else
        printf "${R}[ FAILED ] Ошибка загрузки xHTTP патча. Прерывание конвейера.${N}\n"
        rm -f "$TMP_PATCH"
        TMP_PATCH=""
        return 1
    fi
    
    # Если папки patches нет, то локальные патчи просто мягко пропускаются
    if [ ! -d "$SCRIPT_DIR/patches" ]; then
        printf "${Y}[!] Директория patches/ не найдена. Локальные патчи пропущены.${N}\n"
        return 0
    fi

    has_patches=0
    for patch in "$SCRIPT_DIR"/patches/*.sh; do
        if [ -f "$patch" ]; then
            has_patches=1
            break
        fi
    done

    if [ "$has_patches" -eq 0 ]; then
        printf "${Y}[!] Дополнительные локальные патчи в директории patches/ не найдены.${N}\n"
        return 0
    fi

    # Автоматический перебор локальных скриптов и запуск через sh
    for patch in "$SCRIPT_DIR"/patches/*.sh; do
        if [ -f "$patch" ]; then
            printf "${C}[*] Выполнение патча: %s...${N}\n" "$patch"
            if sh "$patch"; then
                printf "${G}[ OK ] %s успешно применен.${N}\n" "$(basename "$patch")"
            else
                printf "${R}[ FAILED ] Патч %s завершился ошибкой. Прерывание конвейера.${N}\n" "$patch"
                return 1
            fi
        fi
    done
    return 0
}

run_restart_podkop() {
    printf "\n${C}[*] Перезапуск сервиса Podkop...${N}\n"
    if "$PODKOP_INIT" restart; then
        printf "${C}[*] Ожидание стабилизации процессов (2 сек)...${N}\n"
        sleep 2
        printf "${G}[ OK ] Подкоп успешно перезапущен.${N}\n"
        return 0
    else
        printf "${R}[ FAILED ] Ошибка при выполнении команды restart.${N}\n"
        return 1
    fi
}

run_global_check() {
    printf "\n${C}[*] Проверка работоспособности (podkop global_check)...${N}\n"
    if podkop global_check; then
        printf "${G}[ OK ] Проверка global_check успешно пройдена.${N}\n"
        return 0
    else
        printf "${Y}[ WARN ] ВНИМАНИЕ: Проверка global_check завершилась с ошибкой!${N}\n"
        return 1
    fi
}

# Главный цикл меню
while true; do
    show_menu
    read -r choice || choice="0"
    case "$choice" in
        1)
            run_update_sing_box
            wait_key
            ;;
        2)
            run_patches
            wait_key
            ;;
        3)
            if run_update_sing_box; then
                if run_patches; then
                    if run_restart_podkop; then
                        run_global_check
                    fi
                fi
            fi
            wait_key
            ;;
        4)
            run_restart_podkop
            wait_key
            ;;
        5)
            run_global_check
            wait_key
            ;;
        0)
            printf "${G}[*] Выход из программы.${N}\n"
            break
            ;;
        *)
            printf "${R}[!] Неверный ввод. Пожалуйста, выберите пункт от 0 до 5.${N}\n"
            wait_key
            ;;
    esac
done