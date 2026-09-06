#!/usr/bin/env bash
#
# Учебный стенд главы 9: фильтрация с учётом состояния, NAT и conntrack.
#
#   sudo bash 09-firewall-nat/lab.sh check       # проверка среды
#   sudo bash 09-firewall-nat/lab.sh up          # поднять стенд
#   sudo bash 09-firewall-nat/lab.sh status      # что сейчас включено
#   sudo bash 09-firewall-nat/lab.sh snat on|off # трансляция адреса источника
#   sudo bash 09-firewall-nat/lab.sh dnat on|off # публикация порта наружу
#   sudo bash 09-firewall-nat/lab.sh stateful on|off  # правила по состоянию
#   sudo bash 09-firewall-nat/lab.sh break       # внести скрытое правило
#   sudo bash 09-firewall-nat/lab.sh repair      # снять скрытое правило
#   sudo bash 09-firewall-nat/lab.sh reveal      # что именно было сломано
#   sudo bash 09-firewall-nat/lab.sh evidence <имя>   # срез правил и conntrack
#   sudo bash 09-firewall-nat/lab.sh down        # убрать всё
#
# Все объекты имеют префикс dn9-; чужого стенд не трогает.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_dir="/run/dn9-lab"
# Срезы лежат вне каталога состояния намеренно: `down` удаляет state_dir
# целиком, и раньше очистка стирала ровно те доказательства, ради сохранения
# которых глава и написана. К тому же /run — tmpfs, и срезы там не пережили бы
# перезагрузку.
evidence_root="/var/tmp/dn9-evidence"

ns_client="dn9-client"
ns_gw="dn9-gw"
ns_server="dn9-server"

br_in="dn9-br-in"
br_out="dn9-br-out"

ip_client="10.9.0.10"
ip_gw_in="10.9.0.1"
ip_gw_out="203.0.113.1"
ip_server="203.0.113.20"

check_ns="dn9-check-ns"

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

gw() { ip netns exec "${ns_gw}" "$@"; }

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
    for tool in ip nft conntrack ss curl python3; do
        if command -v "${tool}" >/dev/null 2>&1; then
            ok "${tool} найден"
        else
            bad "${tool} не найден"
        fi
    done

    if ! ip netns add "${check_ns}" >/dev/null 2>&1; then
        bad "network namespace создать не удалось"
        printf '\nПроверок провалено: %d.\n' "${check_failures}" >&2
        return 1
    fi
    ok "network namespace создаётся"

    # Правила по состоянию и трансляция — основа всей главы: без них
    # практика не состоится, и узнать об этом лучше до создания стенда.
    if ip netns exec "${check_ns}" nft -f - >/dev/null 2>&1 <<'RULES'
table inet probe {
    chain c {
        type filter hook input priority 0;
        ct state established accept
    }
}
RULES
    then
        ok "nft принимает правила по состоянию соединения"
    else
        bad "nft не принимает ct state: модуль отслеживания недоступен"
    fi

    if ip netns exec "${check_ns}" nft -f - >/dev/null 2>&1 <<'RULES'
table ip probenat {
    chain c {
        type nat hook postrouting priority 100;
        masquerade
    }
}
RULES
    then
        ok "nft принимает правила трансляции адресов"
    else
        bad "nft не принимает правила nat"
    fi

    if ip netns exec "${check_ns}" conntrack -L >/dev/null 2>&1; then
        ok "таблица отслеживания соединений читается"
    else
        bad "conntrack -L не работает внутри namespace"
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

add_node() {
    local ns="$1" host_if="$2" ns_if="$3" bridge="$4" name="$5" addr="$6"
    ip link add "${host_if}" type veth peer name "${ns_if}"
    ip link set "${host_if}" master "${bridge}"
    ip link set "${host_if}" up
    ip link set "${ns_if}" netns "${ns}"
    ip -n "${ns}" link set "${ns_if}" name "${name}"
    ip -n "${ns}" link set "${name}" up
    ip -n "${ns}" addr add "${addr}" dev "${name}"
}

lab_up() {
    if lab_is_up || link_exists "${br_in}"; then
        echo "Объекты стенда уже существуют. Сначала: $0 down" >&2
        exit 1
    fi
    mkdir -p "${state_dir}"

    ip link add "${br_in}" type bridge
    ip link add "${br_out}" type bridge
    ip link set "${br_in}" up
    ip link set "${br_out}" up

    ip netns add "${ns_client}"
    ip netns add "${ns_gw}"
    ip netns add "${ns_server}"
    local ns
    for ns in "${ns_client}" "${ns_gw}" "${ns_server}"; do
        ip -n "${ns}" link set lo up
    done

    add_node "${ns_client}" dn9-c-host dn9-c-ns "${br_in}"  eth0 "${ip_client}/24"
    add_node "${ns_gw}"     dn9-gi-host dn9-gi-ns "${br_in}"  eth0 "${ip_gw_in}/24"
    add_node "${ns_gw}"     dn9-go-host dn9-go-ns "${br_out}" eth1 "${ip_gw_out}/24"
    add_node "${ns_server}" dn9-s-host dn9-s-ns "${br_out}" eth0 "${ip_server}/24"

    ip -n "${ns_client}" route add default via "${ip_gw_in}"
    gw sysctl -qw net.ipv4.ip_forward=1
    # Сервер знает дорогу в частную сеть: без этого маршрута нельзя показать,
    # что до включения трансляции обратный путь есть, и дело не в нём.
    ip -n "${ns_server}" route add "10.9.0.0/24" via "${ip_gw_out}"

    start_service

    cat <<EOF
Стенд поднят.

  клиент  ${ip_client}      частная сеть 10.9.0.0/24
  шлюз    ${ip_gw_in} / ${ip_gw_out}
  сервер  ${ip_server}:8080

Трансляция и правила пока выключены: путь открыт и адреса не подменяются.
Проверка: sudo ip netns exec ${ns_client} curl -sS -m 5 http://${ip_server}:8080/
EOF
}

# --- служба -----------------------------------------------------------------

service_pidfile="${state_dir}/service.pid"

start_service() {
    stop_service
    ip netns exec "${ns_server}" python3 "${here}/service.py" --port 8080 \
        >>"${state_dir}/service.log" 2>&1 &
    echo $! > "${service_pidfile}"
    sleep 0.3
}

stop_service() {
    if [[ -f ${service_pidfile} ]]; then
        kill "$(cat "${service_pidfile}")" >/dev/null 2>&1 || true
        rm -f "${service_pidfile}"
    fi
}

# --- трансляция и фильтрация ------------------------------------------------

ensure_nat_table() {
    gw nft list table ip dn9nat >/dev/null 2>&1 || gw nft -f - <<'RULES'
table ip dn9nat {
    chain postrouting { type nat hook postrouting priority 100; }
    chain prerouting  { type nat hook prerouting  priority -100; }
}
RULES
}

snat() {
    require_lab
    ensure_nat_table
    case "${1:-}" in
        on)
            gw nft flush chain ip dn9nat postrouting
            gw nft add rule ip dn9nat postrouting ip saddr 10.9.0.0/24 oifname eth1 counter masquerade
            echo "Трансляция адреса источника включена."
            ;;
        off)
            gw nft flush chain ip dn9nat postrouting
            echo "Трансляция адреса источника выключена."
            ;;
        *) echo "Укажите on или off." >&2; exit 1 ;;
    esac
}

dnat() {
    require_lab
    ensure_nat_table
    case "${1:-}" in
        on)
            gw nft flush chain ip dn9nat prerouting
            gw nft add rule ip dn9nat prerouting iifname eth1 tcp dport 8080 counter dnat to "${ip_client}:8080"
            echo "Публикация порта включена: 203.0.113.1:8080 ведёт на клиента."
            ;;
        off)
            gw nft flush chain ip dn9nat prerouting
            echo "Публикация порта выключена."
            ;;
        *) echo "Укажите on или off." >&2; exit 1 ;;
    esac
}

stateful() {
    require_lab
    case "${1:-}" in
        on)
            gw nft list table inet dn9fw >/dev/null 2>&1 && gw nft delete table inet dn9fw
            # Классическая пара правил: ответы на свои обращения пропускаем,
            # чужие новые соединения из внешней сети — нет.
            gw nft -f - <<'RULES'
table inet dn9fw {
    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related counter accept
        iifname "eth0" ct state new counter accept
        counter drop
    }
}
RULES
            echo "Фильтрация по состоянию включена."
            ;;
        off)
            gw nft delete table inet dn9fw >/dev/null 2>&1 || true
            echo "Фильтрация по состоянию выключена."
            ;;
        *) echo "Укажите on или off." >&2; exit 1 ;;
    esac
}

# --- скрытая неисправность --------------------------------------------------

break_lab() {
    require_lab
    gw nft list table inet dn9fw >/dev/null 2>&1 || stateful on >/dev/null
    # Правило вставляется первым и отбрасывает часть трафика молча.
    # Найти его студент должен по счётчикам, а не по подсказке.
    gw nft insert rule inet dn9fw forward tcp dport 8080 ip daddr 203.0.113.20 counter drop
    echo "Скрытое правило добавлено. Ищите его наблюдениями."
}

repair_lab() {
    require_lab
    local handle
    handle="$(gw nft -a list chain inet dn9fw forward 2>/dev/null \
        | awk '/tcp dport 8080/ && /drop/ {print $NF; exit}')" || true
    if [[ -n ${handle:-} ]]; then
        gw nft delete rule inet dn9fw forward handle "${handle}"
        echo "Скрытое правило удалено."
    else
        echo "Скрытого правила нет."
    fi
}

reveal_fault() {
    cat <<'EOF'
Скрытое правило: в цепочку forward первым добавлено

    tcp dport 8080 ip daddr 203.0.113.20 counter drop

Оно отбрасывает обращения именно к порту 8080 сервера и стоит выше
правил по состоянию, поэтому срабатывает раньше них.

Ожидаемые наблюдения:
  - обращение к 203.0.113.20:8080 висит до тайм-аута;
  - ping до того же адреса при этом проходит: правило смотрит на порт;
  - в `nft -a list ruleset` у этого правила растёт счётчик, у остальных нет;
  - в conntrack записи об этом соединении нет вовсе: пакет отброшен
    до подтверждения записи. Само по себе отсутствие записи причиной не
    является — записи ещё и истекают по таймеру, а обращения могло не
    быть вовсе. Здесь оно значимо потому, что отбрасывание уже
    подтверждено выросшим счётчиком правила.
EOF
}

# --- наблюдения -------------------------------------------------------------

collect_evidence() {
    local name="${1:-snapshot}"
    require_lab
    local stamp dir
    stamp="$(date +%Y%m%d-%H%M%S)"
    dir="${evidence_root}/${stamp}-${name}"
    mkdir -p "${dir}"

    {
        printf 'снято: %s\n' "$(date --iso-8601=seconds)"
        printf 'метка: %s\n' "${name}"
    } > "${dir}/meta.txt"

    # Счётчики правил и таблица соединений — то, что просит программа курса
    # сохранять как доказательство: по ним видно, какое правило сработало.
    gw nft -a list ruleset > "${dir}/gw-nftables.txt" 2>&1 || true
    gw conntrack -L > "${dir}/gw-conntrack.txt" 2>&1 || true
    # Глава называет три вида данных, и статистика подсистемы — третий из них.
    # Без -C и -S срез не отвечал на вопрос, не отказывала ли подсистема в
    # создании записей, то есть был неполон ровно там, где обещал полноту.
    {
        printf '### conntrack -C (записей всего)\n'
        gw conntrack -C 2>&1 || true
        printf '\n### conntrack -S (статистика подсистемы)\n'
        gw conntrack -S 2>&1 || true
    } > "${dir}/gw-conntrack-stats.txt"
    ip -n "${ns_gw}" -s link > "${dir}/gw-links.txt" 2>&1 || true

    echo "Срез сохранён: ${dir}"
    ls -1 "${dir}"
}

show_status() {
    if ! lab_is_up; then
        echo "Стенд не поднят."
        return 0
    fi
    printf 'Трансляция источника (postrouting):\n'
    gw nft list chain ip dn9nat postrouting 2>/dev/null | sed -n '/masquerade/p' | sed 's/^/  /' \
        || printf '  нет\n'
    printf 'Публикация порта (prerouting):\n'
    gw nft list chain ip dn9nat prerouting 2>/dev/null | sed -n '/dnat/p' | sed 's/^/  /' \
        || printf '  нет\n'
    printf 'Фильтрация по состоянию:\n'
    if gw nft list table inet dn9fw >/dev/null 2>&1; then
        printf '  включена\n'
    else
        printf '  выключена\n'
    fi
    printf 'Соединений в таблице отслеживания: '
    gw conntrack -C 2>/dev/null || printf '?\n'
}

lab_down() {
    stop_service
    local ns
    for ns in "${ns_client}" "${ns_gw}" "${ns_server}" "${check_ns}"; do
        if namespace_exists "${ns}"; then
            # Удаление имени namespace не завершает работающие в нём процессы:
            # пространство живёт, пока его кто-то держит. В самостоятельном
            # задании студент запускает службу в dn9-client руками, и она
            # переживала очистку вместе с сетью, которую удерживала.
            local pids
            pids="$(ip netns pids "${ns}" 2>/dev/null || true)"
            if [[ -n ${pids} ]]; then
                # shellcheck disable=SC2086
                kill ${pids} >/dev/null 2>&1 || true
                sleep 0.2
                # shellcheck disable=SC2086
                kill -9 ${pids} >/dev/null 2>&1 || true
            fi
            ip netns delete "${ns}" >/dev/null 2>&1 || true
        fi
    done
    local host_if
    for host_if in dn9-c-host dn9-gi-host dn9-go-host dn9-s-host; do
        if link_exists "${host_if}"; then
            ip link delete "${host_if}" >/dev/null 2>&1 || true
        fi
    done
    local br
    for br in "${br_in}" "${br_out}"; do
        if link_exists "${br}"; then
            ip link delete "${br}" >/dev/null 2>&1 || true
        fi
    done
    rm -rf "${state_dir}"
    echo "Объекты стенда удалены, если они существовали."
    if [[ -d ${evidence_root} ]] && [[ -n "$(ls -A "${evidence_root}" 2>/dev/null)" ]]; then
        printf 'Срезы наблюдений сохранены: %s\n' "${evidence_root}"
        printf 'Они не удаляются вместе со стендом. Когда разбор закончен: rm -rf %s\n' \
            "${evidence_root}"
    fi
}

case "${1:-}" in
    check)    require_root; run_check ;;
    up)       require_root; lab_up ;;
    status)   show_status ;;
    snat)     require_root; snat "${2:-}" ;;
    dnat)     require_root; dnat "${2:-}" ;;
    stateful) require_root; stateful "${2:-}" ;;
    break)    require_root; break_lab ;;
    repair)   require_root; repair_lab ;;
    reveal)   reveal_fault ;;
    evidence) require_root; collect_evidence "${2:-}" ;;
    down)     require_root; lab_down ;;
    *)        sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
