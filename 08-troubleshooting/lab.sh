#!/usr/bin/env bash
#
# Учебный стенд главы 8: сетевой траблшутинг и наблюдаемость.
#
#   sudo bash 08-troubleshooting/lab.sh check          # проверка среды
#   sudo bash 08-troubleshooting/lab.sh up             # поднять стенд
#   sudo bash 08-troubleshooting/lab.sh status         # что сейчас настроено
#   sudo bash 08-troubleshooting/lab.sh break <номер>  # внести неисправность
#   sudo bash 08-troubleshooting/lab.sh repair         # снять все неисправности
#   sudo bash 08-troubleshooting/lab.sh reveal <номер> # что именно было сломано
#   sudo bash 08-troubleshooting/lab.sh evidence <имя> # снять срез наблюдений
#   sudo bash 08-troubleshooting/lab.sh down           # убрать всё
#
# Номера неисправностей: 1..5. Смотреть reveal до постановки диагноза
# бессмысленно: смысл практики в том, чтобы дойти до причины наблюдениями.
#
# Все объекты имеют префикс dn8-; чужого стенд не трогает.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_dir="/run/dn8-lab"
evidence_root="${state_dir}/evidence"

ns_client="dn8-client"
ns_router="dn8-router"
ns_server="dn8-server"

br_left="dn8-br-l"
br_right="dn8-br-r"

ip_client="198.51.100.10"
ip_router_l="198.51.100.1"
ip_router_r="203.0.113.1"
ip_server="203.0.113.20"

check_ns="dn8-check-ns"

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo "Нужны права root: запустите через sudo." >&2
        exit 1
    fi
}

namespace_exists() { ip netns list | awk '{print $1}' | grep -qx "$1"; }
link_exists() { ip link show "$1" >/dev/null 2>&1; }

lab_is_up() { namespace_exists "${ns_client}"; }

require_lab() {
    if ! lab_is_up; then
        echo "Стенд не поднят. Сначала: $0 up" >&2
        exit 1
    fi
}

# --- проверка среды ---------------------------------------------------------

check_failures=0
ok()   { printf '[ ok ]   %s\n' "$1"; }
bad()  { printf '[ FAIL ] %s\n' "$1"; check_failures=$((check_failures + 1)); }

check_cleanup() {
    if namespace_exists "${check_ns}"; then
        ip netns delete "${check_ns}" >/dev/null 2>&1 || true
    fi
}

run_check() {
    if namespace_exists "${check_ns}"; then
        echo "Проверочный объект уже существует. Выясните его происхождение, затем: $0 down" >&2
        return 1
    fi
    trap check_cleanup EXIT
    printf 'Проверка среды, нужной этой практике.\n\n'

    local tool
    for tool in ip ss nft tcpdump ping curl python3; do
        if command -v "${tool}" >/dev/null 2>&1; then
            ok "${tool} найден"
        else
            bad "${tool} не найден"
        fi
    done

    if ip netns add "${check_ns}" >/dev/null 2>&1; then
        ok "network namespace создаётся"
    else
        bad "network namespace создать не удалось"
        printf '\nПроверок провалено: %d.\n' "${check_failures}" >&2
        return 1
    fi

    if ip netns exec "${check_ns}" nft list ruleset >/dev/null 2>&1; then
        ok "nft работает внутри namespace"
    else
        bad "nft внутри namespace недоступен: практика с фильтрами не пройдёт"
    fi

    if ip netns exec "${check_ns}" sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        ok "пересылка переключается внутри namespace"
    else
        bad "sysctl внутри namespace недоступен"
    fi

    printf '\n'
    if [[ ${check_failures} -eq 0 ]]; then
        printf 'Environment is ready: all checks passed.\n'
        return 0
    fi
    printf 'Проверок провалено: %d. Установите недостающее и повторите.\n' "${check_failures}" >&2
    return 1
}

# --- стенд ------------------------------------------------------------------

lab_up() {
    if lab_is_up || link_exists "${br_left}"; then
        echo "Объекты стенда уже существуют. Сначала: $0 down" >&2
        exit 1
    fi

    mkdir -p "${state_dir}"

    ip link add "${br_left}" type bridge
    ip link add "${br_right}" type bridge
    ip link set "${br_left}" up
    ip link set "${br_right}" up

    ip netns add "${ns_client}"
    ip netns add "${ns_router}"
    ip netns add "${ns_server}"

    # Клиент — левый сегмент.
    ip link add dn8-c-host type veth peer name dn8-c-ns
    ip link set dn8-c-host master "${br_left}"
    ip link set dn8-c-host up
    ip link set dn8-c-ns netns "${ns_client}"
    ip -n "${ns_client}" link set dn8-c-ns name eth0
    ip -n "${ns_client}" link set lo up
    ip -n "${ns_client}" link set eth0 up
    ip -n "${ns_client}" addr add "${ip_client}/24" dev eth0
    ip -n "${ns_client}" route add default via "${ip_router_l}"

    # Маршрутизатор — обе стороны.
    ip link add dn8-rl-host type veth peer name dn8-rl-ns
    ip link set dn8-rl-host master "${br_left}"
    ip link set dn8-rl-host up
    ip link set dn8-rl-ns netns "${ns_router}"
    ip -n "${ns_router}" link set dn8-rl-ns name eth0
    ip -n "${ns_router}" link set lo up
    ip -n "${ns_router}" link set eth0 up
    ip -n "${ns_router}" addr add "${ip_router_l}/24" dev eth0

    ip link add dn8-rr-host type veth peer name dn8-rr-ns
    ip link set dn8-rr-host master "${br_right}"
    ip link set dn8-rr-host up
    ip link set dn8-rr-ns netns "${ns_router}"
    ip -n "${ns_router}" link set dn8-rr-ns name eth1
    ip -n "${ns_router}" link set eth1 up
    ip -n "${ns_router}" addr add "${ip_router_r}/24" dev eth1
    ip netns exec "${ns_router}" sysctl -qw net.ipv4.ip_forward=1

    # Сервер — правый сегмент.
    ip link add dn8-s-host type veth peer name dn8-s-ns
    ip link set dn8-s-host master "${br_right}"
    ip link set dn8-s-host up
    ip link set dn8-s-ns netns "${ns_server}"
    ip -n "${ns_server}" link set dn8-s-ns name eth0
    ip -n "${ns_server}" link set lo up
    ip -n "${ns_server}" link set eth0 up
    ip -n "${ns_server}" addr add "${ip_server}/24" dev eth0
    ip -n "${ns_server}" route add default via "${ip_router_r}"

    start_service 0.0.0.0

    cat <<EOF
Стенд поднят.

  клиент        ${ip_client}
  маршрутизатор ${ip_router_l} / ${ip_router_r}
  сервер        ${ip_server}:8080

Проверка исправного пути:
  sudo ip netns exec ${ns_client} curl -sS -m 5 http://${ip_server}:8080/
EOF
}

# --- служба на сервере ------------------------------------------------------

service_pidfile="${state_dir}/service.pid"

start_service() {
    local bind="$1"
    stop_service
    ip netns exec "${ns_server}" python3 "${here}/service.py" \
        --address "${bind}" --port 8080 \
        >>"${state_dir}/service.log" 2>&1 &
    echo $! > "${service_pidfile}"
    echo "${bind}" > "${state_dir}/service.bind"
    sleep 0.3
}

stop_service() {
    if [[ -f ${service_pidfile} ]]; then
        kill "$(cat "${service_pidfile}")" >/dev/null 2>&1 || true
        rm -f "${service_pidfile}"
    fi
}

# --- неисправности ----------------------------------------------------------

fault_file="${state_dir}/faults"

record_fault() { echo "$1" >> "${fault_file}"; }

break_lab() {
    local n="$1"
    require_lab
    case "${n}" in
        1)
            # Нет маршрута по умолчанию у клиента.
            ip -n "${ns_client}" route del default >/dev/null 2>&1 || true
            ;;
        2)
            # Маршрутизатор не пересылает чужие пакеты.
            ip netns exec "${ns_router}" sysctl -qw net.ipv4.ip_forward=0
            ;;
        3)
            # Сервер молча отбрасывает пакеты к службе.
            ip netns exec "${ns_server}" nft -f - <<'RULES'
table inet dn8 {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport 8080 drop
    }
}
RULES
            ;;
        4)
            # Сервер активно отклоняет обращения к службе.
            ip netns exec "${ns_server}" nft -f - <<'RULES'
table inet dn8 {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport 8080 reject with tcp reset
    }
}
RULES
            ;;
        5)
            # Служба слушает только адрес обратной петли.
            start_service 127.0.0.1
            ;;
        *)
            echo "Неисправности задаются номерами 1..5." >&2
            exit 1
            ;;
    esac
    record_fault "${n}"
    echo "Неисправность внесена. Диагноз ставьте наблюдениями, а не по номеру."
}

repair_lab() {
    require_lab
    ip -n "${ns_client}" route replace default via "${ip_router_l}" >/dev/null 2>&1 || true
    ip netns exec "${ns_router}" sysctl -qw net.ipv4.ip_forward=1
    ip netns exec "${ns_server}" nft delete table inet dn8 >/dev/null 2>&1 || true
    if [[ -f ${state_dir}/service.bind ]] && [[ $(cat "${state_dir}/service.bind") != "0.0.0.0" ]]; then
        start_service 0.0.0.0
    fi
    rm -f "${fault_file}"
    echo "Все неисправности сняты."
}

reveal_fault() {
    local n="$1"
    case "${n}" in
        1) cat <<'EOF'
Неисправность 1: у клиента удалён маршрут по умолчанию.

Ожидаемые наблюдения:
  - обращение завершается сразу, без ожидания;
  - `ip route get <адрес сервера>` не находит маршрут;
  - до маршрутизатора связь при этом есть: он в той же подсети.
EOF
        ;;
        2) cat <<'EOF'
Неисправность 2: на маршрутизаторе выключена пересылка (net.ipv4.ip_forward=0).

Ожидаемые наблюдения:
  - обращение висит до тайм-аута;
  - маршрут у клиента верный, сам маршрутизатор отвечает;
  - на входном интерфейсе маршрутизатора пакеты видны, на выходном нет.
EOF
        ;;
        3) cat <<'EOF'
Неисправность 3: сервер молча отбрасывает пакеты к порту 8080.

Ожидаемые наблюдения:
  - обращение висит до тайм-аута;
  - путь до сервера цел, сам сервер отвечает на другие обращения;
  - на сервере запрос виден в захвате, но ответа нет; служба слушает порт.
EOF
        ;;
        4) cat <<'EOF'
Неисправность 4: сервер активно отклоняет обращения к порту 8080.

Ожидаемые наблюдения:
  - обращение завершается быстро отказом, а не тайм-аутом;
  - служба при этом слушает порт;
  - в захвате на сервере виден ответ с флагом сброса.
EOF
        ;;
        5) cat <<'EOF'
Неисправность 5: служба слушает только 127.0.0.1.

Ожидаемые наблюдения:
  - обращение с клиента завершается быстро отказом;
  - на самом сервере обращение к 127.0.0.1:8080 проходит;
  - `ss -ltn` на сервере показывает адрес привязки 127.0.0.1, а не 0.0.0.0.
EOF
        ;;
        *) echo "Неисправности задаются номерами 1..5." >&2; exit 1 ;;
    esac
}

# --- сохранение доказательств -----------------------------------------------

collect_evidence() {
    local name="${1:-snapshot}"
    require_lab
    local stamp dir
    stamp="$(date +%Y%m%d-%H%M%S)"
    dir="${evidence_root}/${stamp}-${name}"
    mkdir -p "${dir}"

    # Срез снимается целиком и с отметкой времени: наблюдение, записанное
    # позже по памяти, доказательством уже не является.
    {
        printf 'снято: %s\n' "$(date --iso-8601=seconds)"
        printf 'метка: %s\n' "${name}"
    } > "${dir}/meta.txt"

    local ns
    for ns in "${ns_client}" "${ns_router}" "${ns_server}"; do
        {
            printf '### ip -br addr\n'; ip -n "${ns}" -br addr || true
            printf '\n### ip route\n'; ip -n "${ns}" route || true
            printf '\n### ip neigh\n'; ip -n "${ns}" neigh || true
            printf '\n### ss -ltnp\n'; ip netns exec "${ns}" ss -ltnp 2>/dev/null || true
            printf '\n### nft list ruleset\n'; ip netns exec "${ns}" nft list ruleset 2>/dev/null || true
            printf '\n### ip_forward\n'
            ip netns exec "${ns}" sysctl -n net.ipv4.ip_forward 2>/dev/null || true
        } > "${dir}/${ns}.txt"
    done

    echo "Срез сохранён: ${dir}"
    ls -1 "${dir}"
}

show_status() {
    printf 'Namespace:\n'
    local ns
    for ns in "${ns_client}" "${ns_router}" "${ns_server}"; do
        if namespace_exists "${ns}"; then
            printf '  %-12s есть\n' "${ns}"
        else
            printf '  %-12s нет\n' "${ns}"
        fi
    done
    if ! lab_is_up; then
        return 0
    fi
    printf '\nСлужба на сервере:\n'
    if [[ -f ${service_pidfile} ]] && kill -0 "$(cat "${service_pidfile}")" 2>/dev/null; then
        printf '  работает, привязка %s\n' "$(cat "${state_dir}/service.bind" 2>/dev/null || echo '?')"
    else
        printf '  не работает\n'
    fi
    printf '\nСрезы наблюдений:\n'
    if [[ -d ${evidence_root} ]]; then
        ls -1 "${evidence_root}" | sed 's/^/  /'
    else
        printf '  пока нет\n'
    fi
}

lab_down() {
    stop_service
    local ns
    for ns in "${ns_client}" "${ns_router}" "${ns_server}" "${check_ns}"; do
        if namespace_exists "${ns}"; then
            ip netns delete "${ns}" >/dev/null 2>&1 || true
        fi
    done
    local host_if
    for host_if in dn8-c-host dn8-rl-host dn8-rr-host dn8-s-host; do
        if link_exists "${host_if}"; then
            ip link delete "${host_if}" >/dev/null 2>&1 || true
        fi
    done
    local br
    for br in "${br_left}" "${br_right}"; do
        if link_exists "${br}"; then
            ip link delete "${br}" >/dev/null 2>&1 || true
        fi
    done
    rm -rf "${state_dir}"
    echo "Объекты стенда удалены, если они существовали."
}

case "${1:-}" in
    check)    require_root; run_check ;;
    up)       require_root; lab_up ;;
    status)   show_status ;;
    break)    require_root; break_lab "${2:-}" ;;
    repair)   require_root; repair_lab ;;
    reveal)   reveal_fault "${2:-}" ;;
    evidence) require_root; collect_evidence "${2:-}" ;;
    down)     require_root; lab_down ;;
    *)        sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
