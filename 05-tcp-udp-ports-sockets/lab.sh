#!/usr/bin/env bash

set -euo pipefail

# Префикс "dn5-" отделяет объекты этой главы от стендов предыдущих: они
# сносятся независимо, и оставшийся стенд не должен ронять создание нового.
client_ns="dn5-client"
server_ns="dn5-server"
client_if="dn5-c"
server_if="dn5-s"

client4="198.51.100.10/24"
server4="198.51.100.20/24"
client6="2001:db8:5::10/64"
server6="2001:db8:5::20/64"

# Порты из динамического диапазона IANA: они не закреплены ни за одной службой,
# поэтому учебный стенд не притворяется чужим сервисом.
tcp_port=54321
udp_port=54322

state_dir="/run/dn5-lab"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
listener="${here}/listener.py"

check_ns="dn5-check-ns"
check_a="dn5-check-a"
check_b="dn5-check-b"
check_failures=0

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        printf 'Run this command with sudo.\n' >&2
        exit 1
    fi
}

require_tools() {
    local tool
    for tool in ip ss; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            printf 'Required command not found: %s\n' "${tool}" >&2
            exit 1
        fi
    done
}

namespace_exists() {
    ip netns list | awk '{print $1}' | grep -Fxq "$1"
}

link_exists() {
    ip link show dev "$1" >/dev/null 2>&1
}

check_ok() {
    printf '[ ok ]   %s\n' "$1"
}

check_fail() {
    printf '[ FAIL ] %s\n' "$1" >&2
    check_failures=$((check_failures + 1))
}

# Номер процесса ядро переиспользует, поэтому одного его наличия мало:
# `kill -0` подтверждает, что процесс с таким номером существует, но не что
# это наш. Стенд работает от root, и слепой kill попал бы в чужой процесс,
# занявший освободившийся номер. Вместе с номером сохраняем время старта из
# /proc/<pid>/stat: пара «номер + время старта» процесс определяет однозначно.
#
# Поле comm в /proc/<pid>/stat заключено в скобки и может содержать и пробелы,
# и скобки, поэтому разбор ведётся от последней закрывающей: после неё поля
# начинаются с состояния, и время старта оказывается двадцатым.
proc_starttime() {
    local stat rest
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    rest=${stat##*) }
    printf '%s' "${rest}" | awk '{print $20}'
}

# Печатает номер процесса, если файл описывает наш живой слушатель.
listener_pid() {
    local pidfile=$1 pid saved now
    [[ -f ${pidfile} ]] || return 1
    read -r pid saved < "${pidfile}" || return 1
    [[ -n ${pid} && -n ${saved} ]] || return 1
    now=$(proc_starttime "${pid}") || return 1
    [[ ${now} == "${saved}" ]] || return 1
    printf '%s' "${pid}"
}

stop_listeners() {
    local pidfile pid
    shopt -s nullglob
    for pidfile in "${state_dir}"/*.pid; do
        if pid=$(listener_pid "${pidfile}"); then
            kill "${pid}" 2>/dev/null || true
        fi
        rm -f "${pidfile}"
    done
    shopt -u nullglob
}

cleanup() {
    local ns if_name
    stop_listeners
    # Журналы слушателей тоже наши: без их удаления каталог состояния
    # остаётся, и "down" перестаёт означать «убрано всё».
    rm -f "${state_dir}"/*.log 2>/dev/null || true
    rmdir "${state_dir}" 2>/dev/null || true
    for ns in "${client_ns}" "${server_ns}"; do
        if namespace_exists "${ns}"; then
            ip netns delete "${ns}" >/dev/null 2>&1 || true
        fi
    done
    for if_name in "${client_if}" "${server_if}"; do
        if link_exists "${if_name}"; then
            ip link delete "${if_name}" >/dev/null 2>&1 || true
        fi
    done
}

create_lab() {
    local ns if_name
    for ns in "${client_ns}" "${server_ns}"; do
        if namespace_exists "${ns}"; then
            printf 'A lab object already exists: %s. Run "%s down" first.\n' "${ns}" "$0" >&2
            exit 1
        fi
    done
    for if_name in "${client_if}" "${server_if}"; do
        if link_exists "${if_name}"; then
            printf 'A lab object already exists: %s. Run "%s down" first.\n' "${if_name}" "$0" >&2
            exit 1
        fi
    done

    trap 'trap - ERR; printf "Setup failed; removing partially created lab.\n" >&2; cleanup' ERR

    ip netns add "${client_ns}"
    ip netns add "${server_ns}"
    ip link add "${client_if}" type veth peer name "${server_if}"
    ip link set "${client_if}" netns "${client_ns}"
    ip link set "${server_if}" netns "${server_ns}"

    ip -n "${client_ns}" link set lo up
    ip -n "${server_ns}" link set lo up
    ip -n "${client_ns}" addr add "${client4}" dev "${client_if}"
    ip -n "${client_ns}" -6 addr add "${client6}" dev "${client_if}" nodad
    ip -n "${client_ns}" link set "${client_if}" up
    ip -n "${server_ns}" addr add "${server4}" dev "${server_if}"
    ip -n "${server_ns}" -6 addr add "${server6}" dev "${server_if}" nodad
    ip -n "${server_ns}" link set "${server_if}" up

    mkdir -p "${state_dir}"
    trap - ERR

    printf 'Lab is up.\n\n'
    printf '  %-12s %s / %s\n' "${client_ns}" "${client4%/*}" "${client6%/*}"
    printf '  %-12s %s / %s\n' "${server_ns}" "${server4%/*}" "${server6%/*}"
    printf '\n  учебные порты: TCP %s, UDP %s\n' "${tcp_port}" "${udp_port}"
    printf '\nStart with: ip netns exec %s ss -ltn\n' "${server_ns}"
}

start_listener() {
    # Раздельные local: в одной команде bash раскрывает все слова до
    # присваивания, и ${proto} внутри третьего был бы ещё пуст.
    local proto=$1
    local port=$2
    local once=${3:-}
    local pidfile="${state_dir}/${proto}.pid"
    if ! namespace_exists "${server_ns}"; then
        printf 'Lab is not up. Run "%s up" first.\n' "$0" >&2
        exit 1
    fi
    local running=""
    if running=$(listener_pid "${pidfile}"); then
        printf 'Слушатель %s уже запущен (pid %s).\n' "${proto}" "${running}"
        return 0
    fi
    mkdir -p "${state_dir}"
    ip netns exec "${server_ns}" python3 "${listener}" "${proto}" "${port}" ${once} \
        > "${state_dir}/${proto}.log" 2>&1 &
    local started=$!
    printf '%s %s\n' "${started}" "$(proc_starttime "${started}")" > "${pidfile}"
    sleep 0.3
    if ! listener_pid "${pidfile}" >/dev/null; then
        printf 'Слушатель %s не запустился:\n' "${proto}" >&2
        cat "${state_dir}/${proto}.log" >&2
        rm -f "${pidfile}"
        exit 1
    fi
    printf 'Слушатель %s занял порт %s в %s. Журнал: %s\n' \
        "${proto}" "${port}" "${server_ns}" "${state_dir}/${proto}.log"
}

show_status() {
    local ns
    for ns in "${client_ns}" "${server_ns}"; do
        if namespace_exists "${ns}"; then
            printf '=== %s ===\n' "${ns}"
            ip -n "${ns}" -brief addr show
            printf -- '--- слушающие сокеты ---\n'
            ip netns exec "${ns}" ss -ltun 2>/dev/null || true
            printf -- '--- установленные соединения ---\n'
            ip netns exec "${ns}" ss -tn state established 2>/dev/null || true
            printf '\n'
        else
            printf '=== %s: не существует ===\n\n' "${ns}"
        fi
    done
}

check_cleanup() {
    if namespace_exists "${check_ns}"; then
        ip netns delete "${check_ns}" >/dev/null 2>&1 || true
    fi
    if link_exists "${check_a}"; then
        ip link delete "${check_a}" >/dev/null 2>&1 || true
    fi
    if link_exists "${check_b}"; then
        ip link delete "${check_b}" >/dev/null 2>&1 || true
    fi
}

run_check() {
    local tool

    if namespace_exists "${check_ns}" || link_exists "${check_a}" || link_exists "${check_b}"; then
        printf 'A check object already exists. Run "%s down" first.\n' "$0" >&2
        return 1
    fi

    trap check_cleanup EXIT
    printf 'Checking the environment required by this lab.\n\n'

    for tool in ss python3; do
        if command -v "${tool}" >/dev/null 2>&1; then
            check_ok "command available: ${tool}"
        else
            check_fail "command not found: ${tool}"
        fi
    done
    if command -v tcpdump >/dev/null 2>&1; then
        check_ok "command available: tcpdump"
    else
        # Глава называет tcpdump обязательным: без него не пройти шаг 3 и не
        # закрыть связанный с ним критерий приёмки. Пометка «optional»
        # противоречила главе и позволяла проверке завершиться успехом.
        check_fail "command not found: tcpdump (шаг 3 без него не пройти)"
    fi

    [[ -r ${listener} ]] && check_ok "listener.py на месте" \
        || check_fail "listener.py не найден рядом с lab.sh"

    if ip netns add "${check_ns}" >/dev/null 2>&1; then
        check_ok "network namespace can be created"
    else
        check_fail "network namespace cannot be created"
    fi
    if ip link add "${check_a}" type veth peer name "${check_b}" >/dev/null 2>&1; then
        check_ok "veth pair can be created"
    else
        check_fail "veth pair cannot be created"
    fi

    # Практика целиком построена на чтении состояний сокетов. Если ss внутри
    # namespace не отдаёт данные, шаги 1-5 показать нечего.
    if ip netns exec "${check_ns}" ss -ltn >/dev/null 2>&1; then
        check_ok "ss работает внутри namespace"
    else
        check_fail "ss не работает внутри namespace (шаги 1-5 не выполнить)"
    fi

    # Слушатель занимает порт из динамического диапазона; если это запрещено
    # средой, занять порт не удастся и сервер не поднимется.
    if ip netns exec "${check_ns}" python3 "${listener}" tcp "${tcp_port}" --once \
        >/dev/null 2>&1 & then
        local probe=$!
        sleep 0.4
        if kill -0 "${probe}" 2>/dev/null; then
            check_ok "порт ${tcp_port} можно занять внутри namespace"
            kill "${probe}" 2>/dev/null || true
        else
            check_fail "не удалось занять порт ${tcp_port}"
        fi
        wait "${probe}" 2>/dev/null || true
    fi

    printf '\n'
    if [[ ${check_failures} -gt 0 ]]; then
        printf 'Environment is not ready: %d check(s) failed.\n' "${check_failures}" >&2
        return 1
    fi
    printf 'Environment is ready: all checks passed.\n'
    return 0
}

usage() {
    printf 'Usage: %s {up|check|status|serve-tcp|serve-udp|serve-once|stop|down}\n' "$0" >&2
    printf '\n' >&2
    printf '  up         создать два namespace, соединённых veth\n' >&2
    printf '  check      проверить среду, ничего не создавая\n' >&2
    printf '  status     адреса, слушающие сокеты и соединения\n' >&2
    printf '  serve-tcp  занять TCP-порт %s на сервере\n' "${tcp_port}" >&2
    printf '  serve-udp  занять UDP-порт %s на сервере\n' "${udp_port}" >&2
    printf '  serve-once обслужить одно TCP-соединение и закрыть его\n' >&2
    printf '  stop       остановить слушателей, стенд оставить\n' >&2
    printf '  down       удалить всё, что создаёт этот скрипт\n' >&2
    exit 2
}

require_tools

case "${1:-}" in
    up)        require_root; create_lab ;;
    check)     require_root; run_check ;;
    status)    show_status ;;
    serve-tcp) require_root; start_listener tcp "${tcp_port}" ;;
    serve-udp) require_root; start_listener udp "${udp_port}" ;;
    # Закрывающий сервер нужен отдельной командой: обычный слушатель держит
    # соединения открытыми, и состояние TIME-WAIT в нём не наступает.
    serve-once) require_root; start_listener tcp "${tcp_port}" --once ;;
    stop)      require_root; stop_listeners; printf 'Слушатели остановлены.\n' ;;
    down)      require_root; cleanup; check_cleanup; printf 'Lab objects were removed if they existed.\n' ;;
    *)         usage ;;
esac
