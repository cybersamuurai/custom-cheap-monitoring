#!/bin/bash

# Скрипт для мониторинга сервера

# Проверка доступности серверов по IP-адресам
check_servers() {
    echo "Проверка доступности серверов:"

    declare -a servers=("1.1.1.1" "2.2.2.2" "3.3.3.3")

    for server in "${servers[@]}"
    do
        ping -c 1 $server > /dev/null
        if [ $? -eq 0 ]; then
            echo "Сервер $server доступен."
        else
            echo "Сервер $server недоступен."
        fi
    done
}

# Проверка использования дискового пространства
check_disk_usage() {
    echo "Проверка использования дискового пространства:"

    df -h | grep -E 'Filesystem|/dev/sd' | awk '{print "Файловая система: " $1 ", Использование: " $5}'
}

# Проверка загрузки процессора
check_cpu_load() {
    echo "Проверка загрузки процессора:"

    load=$(awk '{print $1}' /proc/loadavg)
    echo "Средняя загрузка процессора за последнюю минуту: $load"
}

# Основной цикл программы
while true
do
    echo "Выберите действие:"
    echo "1. Проверка доступности серверов"
    echo "2. Проверка использования дискового пространства"
    echo "3. Проверка загрузки процессора"
    echo "4. Выход"

    read choice

    case $choice in
        1)
            check_servers
            ;;
        2)
            check_disk_usage
            ;;
        3)
            check_cpu_load
            ;;
        4)
            break
            ;;
        *)
            echo "Неверный выбор. Пожалуйста, выберите действие из списка."
            ;;
    esac

    echo
done