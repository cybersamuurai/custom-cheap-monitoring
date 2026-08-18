#!/usr/bin/env bash
#
# custom-cheap-monitoring.sh — мониторинг сервера на bash.
#
# Без внешних зависимостей: только bash, ping, df и /proc.
#
# Режимы:
#   (без аргументов)  интерактивное меню
#   --once            один прогон всех проверок, для cron
#   --daemon          бесконечный цикл с интервалом INTERVAL
#   --check <имя>     одна проверка: servers | disk | cpu

set -u

VERSION="1.0.0"

# --- Значения по умолчанию ---
# Приоритет: значения по умолчанию < переменные окружения < файл конфигурации
# < флаги командной строки (для INTERVAL — флаг --interval).
: "${SERVERS:=1.1.1.1 2.2.2.2 3.3.3.3}"
: "${PING_COUNT:=3}"
: "${PING_TIMEOUT:=2}"
: "${DISK_THRESHOLD:=90}"
: "${CPU_LOAD_THRESHOLD:=4.0}"
: "${LOG_FILE:=/var/log/custom-cheap-monitoring.log}"
: "${INTERVAL:=300}"

CONFIG_FILE="${CONFIG_FILE:-}"

MODE="interactive"
CHECK_NAME=""
CLI_INTERVAL=""
PROBLEMS=0

usage() {
    cat <<'EOF'
Использование: custom-cheap-monitoring.sh [опции]

Без опций запускается интерактивное меню.

Опции:
  --once              один прогон всех проверок (для cron)
  --daemon            цикл проверок (интервал — --interval или INTERVAL)
  --check <имя>       одна проверка: servers | disk | cpu
  --config <файл>     файл конфигурации (формат KEY=VALUE)
  --interval <сек>    интервал в секундах для режима --daemon
  --help              эта справка
  --version           версия программы

Коды выхода (--once, --check):
  0 — все проверки пройдены
  1 — обнаружены проблемы (сервер недоступен, диск/загрузка выше порога)
  2 — внутренняя ошибка (неверный аргумент, недоступен инструмент)
EOF
}

log() {
    local level="$1"
    shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
    printf '%s\n' "$line"
    if [ -n "$LOG_FILE" ]; then
        { printf '%s\n' "$line" >> "$LOG_FILE"; } 2>/dev/null
    fi
    return 0
}

# --- Проверка доступности серверов по IP/именам ---
check_servers() {
    local server
    if [ "${#SERVERS_ARRAY[@]}" -eq 0 ]; then
        log "WARN" "Список серверов пуст, проверка пропущена"
        return 0
    fi
    log "INFO" "Проверка доступности серверов (${#SERVERS_ARRAY[@]} шт.): ${SERVERS_ARRAY[*]}"
    for server in "${SERVERS_ARRAY[@]}"; do
        if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$server" > /dev/null 2>&1; then
            log "INFO" "Сервер $server доступен"
        else
            log "WARN" "Сервер $server недоступен"
            PROBLEMS=$((PROBLEMS + 1))
        fi
    done
    return 0
}

# --- Проверка использования дискового пространства ---
check_disk() {
    local fs pct
    log "INFO" "Проверка дискового пространства (порог: ${DISK_THRESHOLD}%)"
    while read -r fs _size _used _avail pct _mount; do
        pct="${pct%\%}"
        case "$pct" in
            '' | *[!0-9]*) continue ;;
        esac
        log "INFO" "Файловая система $fs: занято ${pct}%"
        if [ "$pct" -ge "$DISK_THRESHOLD" ]; then
            log "WARN" "Файловая система $fs: занято ${pct}% — превышен порог ${DISK_THRESHOLD}%"
            PROBLEMS=$((PROBLEMS + 1))
        fi
    done < <(df -hP 2>/dev/null | tail -n +2)
    return 0
}

# --- Проверка загрузки процессора (1-мин. load average) ---
check_cpu() {
    local load
    if [ ! -r /proc/loadavg ]; then
        log "WARN" "/proc/loadavg недоступен — проверка загрузки процессора пропущена"
        return 0
    fi
    load="$(awk '{print $1}' /proc/loadavg)"
    if awk -v l="$load" -v t="$CPU_LOAD_THRESHOLD" 'BEGIN { exit !(l > t) }'; then
        log "WARN" "Загрузка процессора (1 мин): $load — превышен порог $CPU_LOAD_THRESHOLD"
        PROBLEMS=$((PROBLEMS + 1))
    else
        log "INFO" "Загрузка процессора (1 мин): $load"
    fi
    return 0
}

run_all() {
    PROBLEMS=0
    log "INFO" "===== Мониторинг: начало ====="
    check_servers
    check_disk
    check_cpu
    log "INFO" "===== Мониторинг: окончено, проблем: $PROBLEMS ====="
    if [ "$PROBLEMS" -gt 0 ]; then
        return 1
    fi
    return 0
}

interactive_menu() {
    local choice
    echo "Выберите действие:"
    echo "1. Проверка доступности серверов"
    echo "2. Проверка использования дискового пространства"
    echo "3. Проверка загрузки процессора"
    echo "4. Выход"

    read -r choice || return 0

    case "$choice" in
        1)
            PROBLEMS=0
            check_servers
            return 1
            ;;
        2)
            PROBLEMS=0
            check_disk
            return 1
            ;;
        3)
            PROBLEMS=0
            check_cpu
            return 1
            ;;
        4) return 0 ;;
        *)
            echo "Неверный выбор. Пожалуйста, выберите действие из списка."
            return 1
            ;;
    esac
}

run_single_check() {
    PROBLEMS=0
    case "$CHECK_NAME" in
        servers) check_servers ;;
        disk) check_disk ;;
        cpu) check_cpu ;;
        *)
            echo "Ошибка: неизвестная проверка '$CHECK_NAME' (доступны: servers, disk, cpu)" >&2
            exit 2
            ;;
    esac
    if [ "$PROBLEMS" -gt 0 ]; then
        return 1
    fi
    return 0
}

# --- Разбор аргументов ---
while [ $# -gt 0 ]; do
    case "$1" in
        --once)
            MODE="once"
            ;;
        --daemon)
            MODE="daemon"
            ;;
        --config)
            if [ $# -lt 2 ]; then
                echo "Ошибка: --config требует аргумент." >&2
                exit 2
            fi
            CONFIG_FILE="$2"
            shift
            ;;
        --interval)
            if [ $# -lt 2 ]; then
                echo "Ошибка: --interval требует аргумент." >&2
                exit 2
            fi
            CLI_INTERVAL="$2"
            shift
            ;;
        --check)
            if [ $# -lt 2 ]; then
                echo "Ошибка: --check требует аргумент (servers | disk | cpu)." >&2
                exit 2
            fi
            CHECK_NAME="$2"
            MODE="check"
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        --version)
            echo "custom-cheap-monitoring $VERSION"
            exit 0
            ;;
        *)
            echo "Ошибка: неизвестный аргумент '$1'. Используйте --help." >&2
            exit 2
            ;;
    esac
    shift
done

# --- Загрузка конфигурации ---
if [ -n "$CONFIG_FILE" ]; then
    if [ ! -r "$CONFIG_FILE" ]; then
        echo "Ошибка: файл конфигурации '$CONFIG_FILE' не найден или нечитаем." >&2
        exit 2
    fi
    # Конфиг доверяем: это локальный файл оператора, формат KEY=VALUE.
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi

# Флаг командной строки имеет приоритет над файлом конфигурации.
if [ -n "$CLI_INTERVAL" ]; then
    INTERVAL="$CLI_INTERVAL"
fi

read -r -a SERVERS_ARRAY <<< "$SERVERS"

# --- Валидация значений ---
# Выполняется после загрузки конфигурации: значения из любого источника
# (окружение, файл конфигурации, флаги) проходят одну и ту же проверку.
case "$INTERVAL" in
    '' | *[!0-9]*)
        echo "Ошибка: INTERVAL должен быть целым числом секунд." >&2
        exit 2
        ;;
esac
if [ "$INTERVAL" -lt 1 ]; then
    echo "Ошибка: INTERVAL должен быть больше нуля." >&2
    exit 2
fi

case "$PING_COUNT" in
    '' | *[!0-9]*)
        echo "Ошибка: PING_COUNT должен быть целым числом." >&2
        exit 2
        ;;
esac
case "$PING_TIMEOUT" in
    '' | *[!0-9]*)
        echo "Ошибка: PING_TIMEOUT должен быть целым числом." >&2
        exit 2
        ;;
esac
case "$DISK_THRESHOLD" in
    '' | *[!0-9]*)
        echo "Ошибка: DISK_THRESHOLD должен быть целым числом." >&2
        exit 2
        ;;
esac
if ! [[ "$CPU_LOAD_THRESHOLD" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Ошибка: CPU_LOAD_THRESHOLD должен быть числом (например, 4.0)." >&2
    exit 2
fi

# --- Проверка инструментов ---
for tool in ping df awk; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        log "ERROR" "Не найден необходимый инструмент: $tool"
        exit 2
    fi
done

# --- Запуск ---
case "$MODE" in
    interactive)
        while true; do
            interactive_menu
            status=$?
            [ "$status" -eq 0 ] && break
            echo
        done
        exit 0
        ;;
    once)
        run_all
        exit $?
        ;;
    check)
        run_single_check
        exit $?
        ;;
    daemon)
        log "INFO" "Запуск в режиме daemon (интервал: ${INTERVAL} с)"
        while true; do
            run_all || true
            sleep "$INTERVAL"
        done
        ;;
esac
