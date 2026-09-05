#!/usr/bin/env bash
#
# Учебный стенд главы 10: сеть контейнера из примитивов Linux.
#
#   sudo bash 10-container-network/lab.sh check    # проверка среды
#   sudo bash 10-container-network/lab.sh peer     # поднять «внешнюю» сторону
#   sudo bash 10-container-network/lab.sh verify   # проверить, что вы собрали
#   sudo bash 10-container-network/lab.sh docker   # что создаёт настоящий Docker
#   sudo bash 10-container-network/lab.sh down     # убрать всё
#
# Сеть контейнера в этой главе студент собирает сам, командами из текста.
# Скрипт её не создаёт: он готовит внешнюю сторону, проверяет собранное
# и показывает, что делает Docker на той же машине.
#
# Все объекты имеют префикс dn10-; чужого стенд не трогает.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_dir="/run/dn10-lab"

ns_app="dn10-app"          # «контейнер», который собирает студент
ns_peer="dn10-peer"        # внешний узел
br_app="dn10-br0"          # мост контейнерной сети
br_out="dn10-br-out"       # внешний сегмент

ip_br_app="10.10.0.1"      # адрес моста на хосте: он же шлюз контейнера
ip_app="10.10.0.2"
ip_host_out="203.0.113.1"
ip_peer="203.0.113.20"

check_ns="dn10-check-ns"

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo "Нужны права root: запустите через sudo." >&2
        exit 1
    fi
}

namespace_exists() { ip netns list | awk '{print $1}' | grep -qx "$1"; }
link_exists() { ip link show "$1" >/dev/null 2>&1; }

# --- проверка среды ---------------------------------------------------------

check_failures=0
ok()  { printf '[ ok ]   %s\n' "$1"; }
bad() { printf '[ FAIL ] %s\n' "$1"; check_failures=$((check_failures + 1)); }

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
    for tool in ip nft tcpdump curl python3; do
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
    fi

    if ip link add dn10-check-h type veth peer name dn10-check-c >/dev/null 2>&1; then
        ok "veth-пара создаётся"
        ip link delete dn10-check-h >/dev/null 2>&1 || true
    else
        bad "veth-пару создать не удалось"
    fi

    # Docker не обязателен: без него глава проходится целиком, теряется
    # только сравнение с настоящим контейнером.
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        ok "docker доступен: сравнение в шаге 8 будет на живой системе"
    else
        printf '[ note ] docker недоступен: шаг 8 пройдите по выводам из главы\n'
    fi

    printf '\n'
    if [[ ${check_failures} -eq 0 ]]; then
        printf 'Environment is ready: all checks passed.\n'
        return 0
    fi
    printf 'Проверок провалено: %d. Установите недостающее и повторите.\n' "${check_failures}" >&2
    return 1
}

# --- внешняя сторона --------------------------------------------------------

peer_up() {
    if namespace_exists "${ns_peer}"; then
        echo "Внешняя сторона уже поднята. Сначала: $0 down" >&2
        exit 1
    fi
    mkdir -p "${state_dir}"

    ip link add "${br_out}" type bridge
    ip link set "${br_out}" up
    ip addr add "${ip_host_out}/24" dev "${br_out}"

    ip netns add "${ns_peer}"
    ip link add dn10-p-host type veth peer name dn10-p-ns
    ip link set dn10-p-host master "${br_out}"
    ip link set dn10-p-host up
    ip link set dn10-p-ns netns "${ns_peer}"
    ip -n "${ns_peer}" link set dn10-p-ns name eth0
    ip -n "${ns_peer}" link set lo up
    ip -n "${ns_peer}" link set eth0 up
    ip -n "${ns_peer}" addr add "${ip_peer}/24" dev eth0
    ip -n "${ns_peer}" route add default via "${ip_host_out}"

    ip netns exec "${ns_peer}" python3 "${here}/service.py" --port 8080 \
        >>"${state_dir}/peer.log" 2>&1 &
    echo $! > "${state_dir}/peer.pid"
    sleep 0.3

    cat <<EOF
Внешняя сторона поднята.

  внешний узел  ${ip_peer}:8080
  адрес хоста в этом сегменте  ${ip_host_out}

Сеть контейнера соберите сами по шагам главы: мост ${br_app} с адресом
${ip_br_app}, namespace ${ns_app} с адресом ${ip_app}.
EOF
}

# --- проверка собранного ----------------------------------------------------

pass() { printf '[ ok ]   %s\n' "$1"; }
miss() { printf '[  -  ]  %s\n' "$1"; verify_missing=$((verify_missing + 1)); }

verify_lab() {
    local verify_missing=0
    printf 'Проверяю сеть, которую вы собрали.\n\n'

    if link_exists "${br_app}"; then
        pass "мост ${br_app} существует"
    else
        miss "моста ${br_app} нет"
    fi

    if ip addr show "${br_app}" 2>/dev/null | grep -q "${ip_br_app}"; then
        pass "у моста есть адрес ${ip_br_app}"
    else
        miss "у моста нет адреса ${ip_br_app}: контейнеру некуда слать пакеты"
    fi

    if namespace_exists "${ns_app}"; then
        pass "namespace ${ns_app} существует"
    else
        miss "namespace ${ns_app} нет"
    fi

    if ip -n "${ns_app}" addr show eth0 2>/dev/null | grep -q "${ip_app}"; then
        pass "внутри namespace есть eth0 с адресом ${ip_app}"
    else
        miss "внутри namespace нет eth0 с адресом ${ip_app}"
    fi

    if ip -n "${ns_app}" route show 2>/dev/null | grep -q "default via ${ip_br_app}"; then
        pass "маршрут по умолчанию ведёт на ${ip_br_app}"
    else
        miss "нет маршрута по умолчанию через ${ip_br_app}"
    fi

    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]]; then
        pass "пересылка на хосте включена"
    else
        miss "пересылка на хосте выключена: хост не станет маршрутизатором"
    fi

    printf '\n'
    if [[ ${verify_missing} -eq 0 ]]; then
        printf 'Сеть собрана полностью.\n'
        return 0
    fi
    printf 'Не хватает пунктов: %d. Вернитесь к соответствующему шагу.\n' "${verify_missing}"
    return 1
}

# --- что делает Docker ------------------------------------------------------

docker_facts() {
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo "Docker недоступен: сравнивайте с выводами, приведёнными в главе." >&2
        return 1
    fi

    printf '### Мост, созданный Docker\n'
    ip -br addr show docker0 2>/dev/null || printf 'моста docker0 нет\n'

    printf '\n### Интерфейсы, подключённые к нему\n'
    bridge link show 2>/dev/null | grep docker0 || printf 'подключённых интерфейсов нет\n'

    printf '\n### Трансляция источника для исходящего трафика\n'
    iptables -t nat -S POSTROUTING 2>/dev/null | grep -i docker || printf 'правил нет\n'

    printf '\n### Публикация портов\n'
    iptables -t nat -S DOCKER 2>/dev/null | grep DNAT || printf 'опубликованных портов нет\n'

    printf '\n### Разрешение ответов и обращений к опубликованной службе\n'
    iptables -S DOCKER-CT 2>/dev/null | grep ctstate || true
    iptables -S DOCKER 2>/dev/null | grep -E 'ACCEPT|DROP' || true
}

# --- очистка ----------------------------------------------------------------

lab_down() {
    if [[ -f ${state_dir}/peer.pid ]]; then
        kill "$(cat "${state_dir}/peer.pid")" >/dev/null 2>&1 || true
    fi
    local ns
    for ns in "${ns_app}" "${ns_peer}" "${check_ns}"; do
        if namespace_exists "${ns}"; then
            ip netns delete "${ns}" >/dev/null 2>&1 || true
        fi
    done
    local link
    for link in dn10-h dn10-p-host dn10-check-h "${br_app}" "${br_out}"; do
        if link_exists "${link}"; then
            ip link delete "${link}" >/dev/null 2>&1 || true
        fi
    done
    # Правила, добавленные студентом вручную, живут в своей таблице.
    nft delete table ip dn10nat >/dev/null 2>&1 || true
    rm -rf "${state_dir}"
    echo "Объекты стенда удалены, если они существовали."
}

case "${1:-}" in
    check)  require_root; run_check ;;
    peer)   require_root; peer_up ;;
    verify) require_root; verify_lab ;;
    docker) require_root; docker_facts ;;
    down)   require_root; lab_down ;;
    *)      sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
