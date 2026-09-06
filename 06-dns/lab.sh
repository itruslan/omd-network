#!/usr/bin/env bash

set -euo pipefail

# Префикс "dn6-" отделяет объекты этой главы от стендов предыдущих: они
# сносятся независимо, и оставшийся стенд не должен ронять создание нового.
client_ns="dn6-client"
resolver_ns="dn6-resolver"
auth_ns="dn6-auth"
bridge_name="dn6-br0"

client_addr="198.51.100.10/24"
resolver_addr="198.51.100.53/24"
auth_addr="198.51.100.54/24"

zone="lab.example"
# TTL намеренно короткий: студент должен успеть увидеть и обратный отсчёт в
# кэше, и истечение записи, не ожидая при этом несколько минут.
zone_ttl=30

state_dir="/run/dn6-lab"
netns_conf="/etc/netns"

check_ns="dn6-check-ns"
check_failures=0

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        printf 'Run this command with sudo.\n' >&2
        exit 1
    fi
}

require_tools() {
    local tool
    for tool in ip dig dnsmasq; do
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

# Печатает номер процесса, если файл описывает наш живой процесс.
server_pid() {
    local pidfile=$1 pid saved now
    [[ -f ${pidfile} ]] || return 1
    read -r pid saved < "${pidfile}" || return 1
    [[ -n ${pid} && -n ${saved} ]] || return 1
    now=$(proc_starttime "${pid}") || return 1
    [[ ${now} == "${saved}" ]] || return 1
    printf '%s' "${pid}"
}

# Записывает номер запущенного процесса вместе с временем старта.
save_pid() {
    printf '%s %s\n' "$1" "$(proc_starttime "$1")" > "$2"
}

stop_servers() {
    local pidfile pid
    shopt -s nullglob
    for pidfile in "${state_dir}"/*.pid; do
        if pid=$(server_pid "${pidfile}"); then
            kill "${pid}" 2>/dev/null || true
        fi
        rm -f "${pidfile}"
    done
    shopt -u nullglob
}

cleanup() {
    local ns
    stop_servers
    rm -f "${state_dir}"/*.log "${state_dir}"/*.conf 2>/dev/null || true
    rmdir "${state_dir}" 2>/dev/null || true
    for ns in "${client_ns}" "${resolver_ns}" "${auth_ns}"; do
        if namespace_exists "${ns}"; then
            ip netns delete "${ns}" >/dev/null 2>&1 || true
        fi
        # Файл resolv.conf для namespace лежит вне самого namespace и вместе с
        # ним не исчезает: без явного удаления он переживёт стенд.
        rm -f "${netns_conf}/${ns}/resolv.conf" 2>/dev/null || true
        rmdir "${netns_conf}/${ns}" 2>/dev/null || true
    done
    for ns in c r a; do
        link_exists "dn6-${ns}-br" && ip link delete "dn6-${ns}-br" >/dev/null 2>&1 || true
    done
    if link_exists "${bridge_name}"; then
        ip link delete "${bridge_name}" >/dev/null 2>&1 || true
    fi
}

attach() {
    local ns=$1 short=$2 addr=$3
    ip link add "dn6-${short}-br" type veth peer name "dn6-${short}-ns"
    ip link set "dn6-${short}-br" master "${bridge_name}"
    ip link set "dn6-${short}-br" up
    ip link set "dn6-${short}-ns" netns "${ns}"
    ip -n "${ns}" link set lo up
    ip -n "${ns}" addr add "${addr}" dev "dn6-${short}-ns"
    ip -n "${ns}" link set "dn6-${short}-ns" up
}

create_lab() {
    local ns
    for ns in "${client_ns}" "${resolver_ns}" "${auth_ns}"; do
        if namespace_exists "${ns}"; then
            printf 'A lab object already exists: %s. Run "%s down" first.\n' "${ns}" "$0" >&2
            exit 1
        fi
    done
    if link_exists "${bridge_name}"; then
        printf 'A lab object already exists: %s. Run "%s down" first.\n' "${bridge_name}" "$0" >&2
        exit 1
    fi

    trap 'trap - ERR; printf "Setup failed; removing partially created lab.\n" >&2; cleanup' ERR

    ip link add "${bridge_name}" type bridge
    ip link set "${bridge_name}" up
    ip netns add "${client_ns}"
    ip netns add "${resolver_ns}"
    ip netns add "${auth_ns}"
    attach "${client_ns}"   c "${client_addr}"
    attach "${resolver_ns}" r "${resolver_addr}"
    attach "${auth_ns}"     a "${auth_addr}"

    mkdir -p "${state_dir}"

    # Резолвер клиента задаётся файлом вне namespace: ip netns exec подставляет
    # /etc/netns/<ns>/resolv.conf вместо системного. Благодаря этому системное
    # разрешение имён внутри стенда не зависит от настроек хозяйской машины.
    mkdir -p "${netns_conf}/${client_ns}"
    printf 'nameserver %s\n' "${resolver_addr%/*}" > "${netns_conf}/${client_ns}/resolv.conf"

    start_auth
    start_resolver
    trap - ERR

    printf 'Lab is up.\n\n'
    printf '  %-13s %s\n' "${client_ns}" "${client_addr%/*}"
    printf '  %-13s %s  (кэширующий резолвер)\n' "${resolver_ns}" "${resolver_addr%/*}"
    printf '  %-13s %s  (авторитетный для %s)\n' "${auth_ns}" "${auth_addr%/*}" "${zone}"
    printf '\n  записи зоны: web.%s, api.%s; TTL %s с\n' "${zone}" "${zone}" "${zone_ttl}"
    printf '\nStart with: ip netns exec %s dig @%s web.%s\n' \
        "${client_ns}" "${resolver_addr%/*}" "${zone}"
}

start_auth() {
    local pidfile="${state_dir}/auth.pid"
    if server_pid "${pidfile}" >/dev/null; then
        printf 'Авторитетный сервер уже запущен.\n'
        return 0
    fi
    mkdir -p "${state_dir}"
    # --conf-file=/dev/null, --no-resolv и --no-hosts вместе отрезают сервер
    # от настроек хозяйской машины: он отвечает только из заданных здесь
    # записей и ничего не пересылает. Одних --no-resolv и --no-hosts мало:
    # они закрывают только resolv.conf и hosts, а /etc/dnsmasq.conf читается
    # всё равно, и network namespace от него не изолирует. Проверено: файл с
    # одной строкой `port=15353` уводил сервер с 53-го порта, и стенд
    # переставал отвечать.
    # --auth-zone делает сервер настоящим авторитетным для зоны: на имя, которого
    # в ней нет, он отвечает NXDOMAIN, а не отказом. Без этого «имени не
    # существует» и «сервер не берётся отвечать» выглядели бы одинаково.
    ip netns exec "${auth_ns}" dnsmasq --no-daemon --conf-file=/dev/null \
        --no-resolv --no-hosts \
        --auth-zone="${zone}" --auth-server="ns.${zone}" \
        --auth-ttl="${zone_ttl}" --local-ttl="${zone_ttl}" --log-queries \
        --host-record="web.${zone},198.51.100.80" \
        --host-record="api.${zone},198.51.100.81" \
        > "${state_dir}/auth.log" 2>&1 &
    save_pid $! "${pidfile}"
    sleep 0.4
    if ! server_pid "${pidfile}" >/dev/null; then
        printf 'Авторитетный сервер не запустился:\n' >&2
        cat "${state_dir}/auth.log" >&2
        rm -f "${pidfile}"
        return 1
    fi
}

start_resolver() {
    local pidfile="${state_dir}/resolver.pid"
    if server_pid "${pidfile}" >/dev/null; then
        printf 'Резолвер уже запущен.\n'
        return 0
    fi
    mkdir -p "${state_dir}"
    # Пересылка только для учебной зоны: всё остальное резолверу неизвестно, и
    # стенд не обращается наружу даже при опечатке в имени.
    ip netns exec "${resolver_ns}" dnsmasq --no-daemon --conf-file=/dev/null \
        --no-resolv --no-hosts \
        --log-queries --cache-size=150 \
        --server="/${zone}/198.51.100.54" \
        > "${state_dir}/resolver.log" 2>&1 &
    save_pid $! "${pidfile}"
    sleep 0.4
    if ! server_pid "${pidfile}" >/dev/null; then
        printf 'Резолвер не запустился:\n' >&2
        cat "${state_dir}/resolver.log" >&2
        rm -f "${pidfile}"
        return 1
    fi
}

stop_auth() {
    local pidfile="${state_dir}/auth.pid" pid
    if pid=$(server_pid "${pidfile}"); then
        kill "${pid}"
        rm -f "${pidfile}"
        printf 'Авторитетный сервер остановлен. Резолвер продолжает работать.\n'
        printf 'Предскажите, что ответит резолвер, и проверьте.\n'
    else
        printf 'Авторитетный сервер не запущен.\n'
    fi
}

show_status() {
    local ns
    for ns in "${client_ns}" "${resolver_ns}" "${auth_ns}"; do
        if namespace_exists "${ns}"; then
            printf '=== %s ===\n' "${ns}"
            ip -n "${ns}" -brief addr show | grep -v '^lo'
        else
            printf '=== %s: не существует ===\n' "${ns}"
        fi
    done
    printf '\nСлужбы:\n'
    local name pidfile
    for name in auth resolver; do
        pidfile="${state_dir}/${name}.pid"
        local pid
        if pid=$(server_pid "${pidfile}"); then
            printf '  %-9s работает (pid %s)\n' "${name}" "${pid}"
        else
            printf '  %-9s не запущен\n' "${name}"
        fi
    done
    if [[ -r "${netns_conf}/${client_ns}/resolv.conf" ]]; then
        printf '\nresolv.conf клиента: %s' "$(cat "${netns_conf}/${client_ns}/resolv.conf")"
    fi
}

check_cleanup() {
    if namespace_exists "${check_ns}"; then
        ip netns delete "${check_ns}" >/dev/null 2>&1 || true
    fi
}

run_check() {
    local tool

    if namespace_exists "${check_ns}"; then
        printf 'A check object already exists. Run "%s down" first.\n' "$0" >&2
        return 1
    fi

    trap check_cleanup EXIT
    printf 'Checking the environment required by this lab.\n\n'

    for tool in dig dnsmasq; do
        if command -v "${tool}" >/dev/null 2>&1; then
            check_ok "command available: ${tool}"
        else
            check_fail "command not found: ${tool}"
        fi
    done
    if command -v getent >/dev/null 2>&1; then
        check_ok "command available: getent"
    else
        check_fail "command not found: getent (шаг 4 не выполнить)"
    fi

    if ip netns add "${check_ns}" >/dev/null 2>&1; then
        check_ok "network namespace can be created"
    else
        check_fail "network namespace cannot be created"
    fi

    # Стенд подменяет resolv.conf через /etc/netns. Если каталог недоступен на
    # запись, системное разрешение имён в шаге 5 покажет не то, что задумано.
    if mkdir -p "${netns_conf}/${check_ns}" 2>/dev/null; then
        check_ok "каталог ${netns_conf} доступен на запись"
        rmdir "${netns_conf}/${check_ns}" 2>/dev/null || true
    else
        check_fail "нет доступа к ${netns_conf} (шаг 4 не выполнить)"
    fi

    # Главная проверка: поднимается ли dnsmasq внутри namespace и отвечает ли
    # он на запрос. Наличие команды этого ещё не гарантирует.
    ip -n "${check_ns}" link set lo up >/dev/null 2>&1 || true
    ip netns exec "${check_ns}" dnsmasq --no-daemon --conf-file=/dev/null \
        --no-resolv --no-hosts \
        --port=5353 --host-record="probe.${zone},127.0.0.1" \
        > "/tmp/dn6-check.log" 2>&1 &
    local probe=$!
    sleep 0.6
    if kill -0 "${probe}" 2>/dev/null && \
       ip netns exec "${check_ns}" dig -p 5353 @127.0.0.1 "probe.${zone}" +short 2>/dev/null \
       | grep -q '127.0.0.1'; then
        check_ok "dnsmasq отвечает на запрос внутри namespace"
    else
        check_fail "dnsmasq не отвечает внутри namespace"
        sed -n '1,5p' /tmp/dn6-check.log >&2 || true
    fi
    kill "${probe}" 2>/dev/null || true
    wait "${probe}" 2>/dev/null || true
    rm -f /tmp/dn6-check.log

    printf '\n'
    if [[ ${check_failures} -gt 0 ]]; then
        printf 'Environment is not ready: %d check(s) failed.\n' "${check_failures}" >&2
        return 1
    fi
    printf 'Environment is ready: all checks passed.\n'
    return 0
}

usage() {
    printf 'Usage: %s {up|check|status|stop-auth|start-auth|down}\n' "$0" >&2
    printf '\n' >&2
    printf '  up          создать стенд из трёх namespace и запустить серверы\n' >&2
    printf '  check       проверить среду, ничего не создавая\n' >&2
    printf '  status      адреса, состояние служб и resolv.conf клиента\n' >&2
    printf '  stop-auth   остановить авторитетный сервер, резолвер оставить\n' >&2
    printf '  start-auth  вернуть авторитетный сервер\n' >&2
    printf '  down        удалить всё, что создаёт этот скрипт\n' >&2
    exit 2
}

require_tools

case "${1:-}" in
    up)         require_root; create_lab ;;
    check)      require_root; run_check ;;
    status)     show_status ;;
    stop-auth)  require_root; stop_auth ;;
    start-auth) require_root; start_auth && printf 'Авторитетный сервер запущен.\n' ;;
    down)       require_root; cleanup; check_cleanup; printf 'Lab objects were removed if they existed.\n' ;;
    *)          usage ;;
esac
