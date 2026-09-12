#!/usr/bin/env bash
#
# Стенд главы 17: слепой разбор за ограниченное время.
#
#   sudo bash 17-interview-prep/drill.sh check          # проверка среды
#   sudo bash 17-interview-prep/drill.sh up             # поднять стенд
#   sudo bash 17-interview-prep/drill.sh new            # начать раунд
#   sudo bash 17-interview-prep/drill.sh diagnose "..."  # записать диагноз и увидеть ответ
#   sudo bash 17-interview-prep/drill.sh reveal         # сдаться и увидеть ответ
#   sudo bash 17-interview-prep/drill.sh status         # что поднято и идёт ли раунд
#   sudo bash 17-interview-prep/drill.sh score          # журнал раундов
#   sudo bash 17-interview-prep/drill.sh repair         # снять неисправность без раунда
#   sudo bash 17-interview-prep/drill.sh down           # убрать всё
#
# `new` выбирает неисправность случайно и не говорит какую. Номеров у них нет
# намеренно: на собеседовании и в инциденте номер тоже не выдают.
#
# В скрипте лежат ответы: и список неисправностей, и ожидаемые наблюдения.
# Читать его до разбора бессмысленно. Имя текущей неисправности в файле
# состояния хранится в base64 — это не защита, а защёлка от случайного взгляда.
#
# Если разбор идёт в паре, напарник может выбрать неисправность сам:
# DN17_FAULT=<имя> перед `new`. Имена перечислены в переменной faults ниже —
# то есть тому, кто ставит задачу, а не тому, кто её решает.
#
# Все объекты имеют префикс dn17-; чужого стенд не трогает.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_dir="/run/dn17-drill"
# Журнал раундов лежит вне каталога состояния: `down` удаляет состояние
# целиком, а журнал — единственный след работы, и он нужен после уборки.
# К тому же /run — tmpfs, и перезагрузку журнал там бы не пережил.
log_dir="/var/tmp/dn17-drill"
rounds_log="${log_dir}/rounds.tsv"
netns_conf="/etc/netns"

ns_client="dn17-client"
ns_dns="dn17-dns"
ns_router="dn17-router"
ns_server="dn17-server"

br_left="dn17-br-l"
br_right="dn17-br-r"

ip_client="198.51.100.10"
ip_dns="198.51.100.53"
ip_router_l="198.51.100.1"
ip_router_r="203.0.113.1"
ip_server="203.0.113.20"
service_name="shop.example.com"

check_ns="dn17-check-ns"
# Имя интерфейса в Linux — не длиннее 15 символов, отсюда сокращения.
check_veth="dn17-chk-a"
check_veth_peer="dn17-chk-b"
check_br="dn17-chk-br"

faults="mask arp noroute filter mtu dns"

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
ok()  { printf '[ ok ]   %s\n' "$1"; }
bad() { printf '[ FAIL ] %s\n' "$1"; check_failures=$((check_failures + 1)); }

check_log=""

check_cleanup() {
    namespace_exists "${check_ns}" && ip netns delete "${check_ns}" >/dev/null 2>&1 || true
    rmdir "${netns_conf}/${check_ns}" 2>/dev/null || true
    link_exists "${check_veth}" && ip link delete "${check_veth}" >/dev/null 2>&1 || true
    link_exists "${check_br}" && ip link delete "${check_br}" >/dev/null 2>&1 || true
    [[ -n ${check_log} ]] && rm -f "${check_log}"
    return 0
}

run_check() {
    if namespace_exists "${check_ns}"; then
        echo "Проверочный объект уже существует. Выясните его происхождение, затем: $0 down" >&2
        return 1
    fi
    trap check_cleanup EXIT
    check_log=$(mktemp /tmp/dn17-check.XXXXXX)
    printf 'Проверка среды, нужной этой практике.\n\n'

    local tool
    for tool in ip ss nft tcpdump ping curl dig dnsmasq python3 shuf base64 sysctl; do
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

    # Чтение ruleset ещё не значит, что стенд сможет внести неисправность:
    # ядро может не поддерживать нужное семейство, hook или выражение. Поэтому
    # проверка создаёт правило того же вида, что и сами неисправности.
    if ip netns exec "${check_ns}" nft -f - >/dev/null 2>&1 <<'RULES'
table inet dn17check {
    chain forward {
        type filter hook forward priority 0; policy accept;
        ip saddr 203.0.113.20 tcp sport 8080 counter drop
    }
    chain output {
        type filter hook output priority 0; policy accept;
        icmp type destination-unreachable counter drop
    }
}
RULES
    then
        ok "nft принимает правила стенда внутри namespace"
        ip netns exec "${check_ns}" nft delete table inet dn17check >/dev/null 2>&1 || true
    else
        bad "nft внутри namespace не принял правила стенда: часть неисправностей не воспроизведётся"
    fi

    # Стенд подменяет resolv.conf через /etc/netns: без записи в этот каталог
    # разрешение имени внутри стенда пойдёт к резолверу хозяйской машины.
    if mkdir -p "${netns_conf}/${check_ns}" 2>/dev/null; then
        ok "каталог ${netns_conf} доступен на запись"
    else
        bad "нет доступа к ${netns_conf}: стенд не подменит клиенту resolv.conf и hosts"
    fi

    ip -n "${check_ns}" link set lo up >/dev/null 2>&1 || true
    ip netns exec "${check_ns}" dnsmasq --no-daemon --conf-file=/dev/null \
        --no-resolv --no-hosts --port=5353 \
        --host-record="probe.${service_name},127.0.0.1" \
        > "${check_log}" 2>&1 &
    local probe=$!
    sleep 0.6
    if kill -0 "${probe}" 2>/dev/null && \
       ip netns exec "${check_ns}" dig -p 5353 @127.0.0.1 "probe.${service_name}" +short 2>/dev/null \
       | grep -q '127.0.0.1'; then
        ok "dnsmasq отвечает на запрос внутри namespace"
    else
        bad "dnsmasq не отвечает внутри namespace"
        sed -n '1,5p' "${check_log}" >&2 || true
    fi
    kill "${probe}" >/dev/null 2>&1 || true

    # Namespace и nft могут работать, а создание veth или bridge — оказаться
    # запрещённым сборкой ядра или политикой безопасности. Без этих двух
    # проверок check проходил бы полностью, а up падал на первом интерфейсе.
    if ip link add "${check_veth}" type veth peer name "${check_veth_peer}" >/dev/null 2>&1; then
        ok "veth-пара создаётся"
        ip link delete "${check_veth}" >/dev/null 2>&1 || true
    else
        bad "veth-пару создать не удалось: стенд не поднимется"
    fi
    if ip link add "${check_br}" type bridge >/dev/null 2>&1; then
        ok "bridge создаётся"
        ip link delete "${check_br}" >/dev/null 2>&1 || true
    else
        bad "bridge создать не удалось: стенд не поднимется"
    fi

    # Учебные диапазоны сверяются с маршрутами машины. Стенд живёт в отдельных
    # namespace и маршрутов хозяйской машины не меняет, поэтому речь не о
    # перехвате: совпадение мешает разбору — свои наблюдения станет трудно
    # отличить от настоящего трафика по тем же адресам.
    local net
    for net in 198.51.100.0/24 203.0.113.0/24; do
        if route_conflict "${net}"; then
            bad "диапазон ${net} уже есть в маршрутах машины: наблюдения смешаются"
        else
            ok "диапазон ${net} свободен"
        fi
    done

    printf '\n'
    if [[ ${check_failures} -eq 0 ]]; then
        printf 'Environment is ready: all checks passed.\n'
        return 0
    fi
    printf 'Проверок провалено: %d. Установите недостающее и повторите.\n' "${check_failures}" >&2
    return 1
}

# Пересечение учебного диапазона с маршрутами машины. Читается вся таблица
# маршрутизации, а не только main: маршрут в другой таблице точно так же
# перехватит трафик. Ошибка чтения считается пересечением: неизвестное
# состояние — не то же самое, что свободный диапазон.
route_conflict() {
    local net="$1" routes
    if ! routes=$(ip -4 route show table all 2>/dev/null); then
        return 0
    fi
    printf '%s\n' "${routes}" | python3 -c '
import ipaddress, sys
want = ipaddress.ip_network(sys.argv[1])
for line in sys.stdin:
    parts = line.split()
    if not parts:
        continue
    # Первое поле — либо назначение, либо тип маршрута (blackhole, unreachable,
    # local, broadcast): во втором случае назначение стоит следом.
    dst = parts[1] if parts[0] in {
        "blackhole", "unreachable", "prohibit", "throw",
        "local", "broadcast", "multicast", "anycast", "unicast", "nat",
    } and len(parts) > 1 else parts[0]
    if dst == "default":
        continue
    try:
        have = ipaddress.ip_network(dst, strict=False)
    except ValueError:
        # Нераспознанное назначение трактуем как пересечение: молчаливое
        # "свободен" дороже ложной тревоги.
        sys.exit(0)
    if have.overlaps(want):
        sys.exit(0)
sys.exit(1)
' "${net}"
}

# --- стенд ------------------------------------------------------------------

attach() {
    local ns="$1" tag="$2" bridge="$3" addr="$4"
    ip link add "dn17-${tag}-host" type veth peer name "dn17-${tag}-ns"
    ip link set "dn17-${tag}-host" master "${bridge}"
    ip link set "dn17-${tag}-host" up
    ip link set "dn17-${tag}-ns" netns "${ns}"
    ip -n "${ns}" link set "dn17-${tag}-ns" name "$5"
    ip -n "${ns}" link set lo up
    ip -n "${ns}" link set "$5" up
    ip -n "${ns}" addr add "${addr}" dev "$5"
}

lab_up() {
    if lab_is_up || link_exists "${br_left}"; then
        echo "Объекты стенда уже существуют. Сначала: $0 down" >&2
        exit 1
    fi

    mkdir -p "${state_dir}" "${log_dir}"

    ip link add "${br_left}" type bridge
    ip link add "${br_right}" type bridge
    ip link set "${br_left}" up
    ip link set "${br_right}" up

    ip netns add "${ns_client}"
    ip netns add "${ns_dns}"
    ip netns add "${ns_router}"
    ip netns add "${ns_server}"

    attach "${ns_client}" c  "${br_left}"  "${ip_client}/24" eth0
    ip -n "${ns_client}" route add default via "${ip_router_l}"

    attach "${ns_dns}"    d  "${br_left}"  "${ip_dns}/24"    eth0

    attach "${ns_router}" rl "${br_left}"  "${ip_router_l}/24" eth0
    attach "${ns_router}" rr "${br_right}" "${ip_router_r}/24" eth1
    ip netns exec "${ns_router}" sysctl -qw net.ipv4.ip_forward=1

    attach "${ns_server}" s  "${br_right}" "${ip_server}/24" eth0
    ip -n "${ns_server}" route add default via "${ip_router_r}"

    # Резолвер клиента задаётся файлом вне namespace: ip netns exec подставляет
    # /etc/netns/<ns>/resolv.conf вместо системного.
    mkdir -p "${netns_conf}/${ns_client}"
    printf 'nameserver %s\n' "${ip_dns}" > "${netns_conf}/${ns_client}/resolv.conf"
    # Свой hosts обязателен наравне с resolv.conf: ip netns exec подменяет любой
    # файл из /etc/netns/<ns>, а системный /etc/hosts со строкой про
    # shop.example.com разрешил бы имя вообще без резолвера — и неисправность
    # резолвера не проявилась бы.
    cat > "${netns_conf}/${ns_client}/hosts" <<'HOSTS'
127.0.0.1	localhost
::1	localhost ip6-localhost ip6-loopback
HOSTS

    start_dns "${ip_server}"
    start_service

    cat <<EOF
Стенд поднят.

  клиент        ${ip_client}
  резолвер      ${ip_dns}   (${service_name})
  маршрутизатор ${ip_router_l} / ${ip_router_r}
  сервер        ${ip_server}:8080

Проверка исправного пути:
  sudo ip netns exec ${ns_client} curl -q -sS -m 5 http://${service_name}:8080/

Первый раунд: $0 new
EOF
}

lab_down() {
    stop_service
    stop_dns
    local ns
    for ns in "${ns_client}" "${ns_dns}" "${ns_router}" "${ns_server}" "${check_ns}"; do
        namespace_exists "${ns}" && ip netns delete "${ns}" >/dev/null 2>&1 || true
        rmdir "${netns_conf}/${ns}" 2>/dev/null || true
    done
    rm -f "${netns_conf}/${ns_client}/resolv.conf" "${netns_conf}/${ns_client}/hosts"
    rmdir "${netns_conf}/${ns_client}" 2>/dev/null || true
    local iface
    for iface in dn17-c-host dn17-d-host dn17-rl-host dn17-rr-host dn17-s-host \
                 "${br_left}" "${br_right}"; do
        link_exists "${iface}" && ip link delete "${iface}" >/dev/null 2>&1 || true
    done
    rm -rf "${state_dir}"
    echo "Объекты стенда удалены, если они существовали."
    if [[ -s ${rounds_log} ]]; then
        printf 'Журнал раундов сохранён: %s\n' "${rounds_log}"
        printf 'Он не удаляется вместе со стендом. Когда разбор закончен: sudo rm -rf %s\n' "${log_dir}"
    fi
}

# --- служба и резолвер ------------------------------------------------------

service_pid="${state_dir}/service.pid"
dns_pid="${state_dir}/dns.pid"

start_service() {
    stop_service
    ip netns exec "${ns_server}" python3 "${here}/service.py" \
        --address 0.0.0.0 --port 8080 >>"${state_dir}/service.log" 2>&1 &
    echo $! > "${service_pid}"
    sleep 0.3
}

stop_service() {
    [[ -f ${service_pid} ]] || return 0
    kill "$(cat "${service_pid}")" >/dev/null 2>&1 || true
    rm -f "${service_pid}"
}

# Адрес записи — аргумент: одна из неисправностей подменяет её, и отдельного
# кода для этого не нужно.
start_dns() {
    local answer="$1"
    stop_dns
    # --conf-file=/dev/null, --no-resolv и --no-hosts вместе отрезают сервер от
    # настроек хозяйской машины: он отвечает только заданной здесь записью.
    # Одних --no-resolv и --no-hosts мало: /etc/dnsmasq.conf читается всё равно.
    ip netns exec "${ns_dns}" dnsmasq --no-daemon --conf-file=/dev/null \
        --no-resolv --no-hosts --log-queries --local-ttl=5 \
        --host-record="${service_name},${answer}" \
        >>"${state_dir}/dns.log" 2>&1 &
    echo $! > "${dns_pid}"
    echo "${answer}" > "${state_dir}/dns.answer"
    sleep 0.4
}

stop_dns() {
    [[ -f ${dns_pid} ]] || return 0
    kill "$(cat "${dns_pid}")" >/dev/null 2>&1 || true
    rm -f "${dns_pid}"
}

# --- неисправности ----------------------------------------------------------

apply_fault() {
    case "$1" in
        mask)
            # Маска клиента сужена: шлюз оказывается вне его подсети.
            ip -n "${ns_client}" addr del "${ip_client}/24" dev eth0
            ip -n "${ns_client}" addr add "${ip_client}/29" dev eth0
            ;;
        arp)
            # Постоянная запись соседа с чужим MAC-адресом.
            ip -n "${ns_client}" neigh replace "${ip_router_l}" \
                lladdr 02:00:00:00:00:99 dev eth0 nud permanent
            ;;
        noroute)
            # Серверу некуда отправить ответ: маршрута по умолчанию нет.
            ip -n "${ns_server}" route del default
            ;;
        filter)
            # Маршрутизатор отбрасывает обратное направление.
            ip netns exec "${ns_router}" nft -f - <<RULES
table inet dn17 {
    chain forward {
        type filter hook forward priority 0; policy accept;
        ip saddr ${ip_server} tcp sport 8080 counter drop
    }
}
RULES
            ;;
        mtu)
            # Меньший MTU на дальнем участке и отброшенные ICMP-сообщения о
            # необходимости фрагментации: чёрная дыра Path MTU.
            ip -n "${ns_router}" link set eth1 mtu 1400
            ip netns exec "${ns_router}" nft -f - <<'RULES'
table inet dn17 {
    chain output {
        type filter hook output priority 0; policy accept;
        icmp type destination-unreachable counter drop
    }
}
RULES
            ;;
        dns)
            # Резолвер отвечает адресом, по которому службы нет.
            start_dns 203.0.113.99
            ;;
        *) echo "Неизвестная неисправность: $1" >&2; return 1 ;;
    esac
}

repair_all() {
    require_lab
    # Снимается всё сразу и без условий: состояние стенда после `repair` не
    # должно зависеть от того, какая неисправность была внесена.
    ip -n "${ns_client}" addr del "${ip_client}/29" dev eth0 >/dev/null 2>&1 || true
    ip -n "${ns_client}" addr replace "${ip_client}/24" dev eth0 >/dev/null 2>&1 || true
    ip -n "${ns_client}" neigh del "${ip_router_l}" dev eth0 >/dev/null 2>&1 || true
    ip -n "${ns_client}" route replace default via "${ip_router_l}" >/dev/null 2>&1 || true
    ip -n "${ns_server}" route replace default via "${ip_router_r}" >/dev/null 2>&1 || true
    ip netns exec "${ns_router}" nft delete table inet dn17 >/dev/null 2>&1 || true
    # MTU возвращается всем интерфейсам стенда, а не только тому, который
    # меняет неисправность. Контрпример: MTU 1400 на клиенте оставляет путь
    # рабочим, но обезвреживает неисправность mtu — она перестаёт проявляться,
    # потому что клиент и так не отправляет крупных пакетов.
    local ns iface
    for ns in "${ns_client}" "${ns_dns}" "${ns_router}" "${ns_server}"; do
        for iface in eth0 eth1; do
            ip -n "${ns}" link show "${iface}" >/dev/null 2>&1 || continue
            ip -n "${ns}" link set "${iface}" mtu 1500 >/dev/null 2>&1 || true
        done
    done
    if [[ $(cat "${state_dir}/dns.answer" 2>/dev/null) != "${ip_server}" ]]; then
        start_dns "${ip_server}"
    fi
    rm -f "${state_dir}/current" "${state_dir}/started"
}

# Проверка, что путь исправен до начала раунда: иначе неисправность раунда
# наложилась бы на чужую поломку, и разбор увёл бы не туда.
#
# -q обязателен: curl читает ~/.curlrc, и строка resolve в нём подменяет адрес
# имени. Без -q проверка проходила бы и при подменённой записи DNS, а раунд с
# неисправностью резолвера не проявлялся бы вовсе.
#
# Проверок две, и вторая обязательна. Короткий GET проходит и через чёрную дыру
# Path MTU, и через правило, отбрасывающее крупные пакеты, — то есть по одному
# коду 200 «исправно» утверждать нельзя. Тело в 4000 байт заведомо больше
# любого сегмента на этом пути, и служба отвечает его точным размером.
health_body="${state_dir}/health-body.txt"

path_is_healthy() {
    local code answer
    code=$(ip netns exec "${ns_client}" curl -q -sS -m 5 -o /dev/null \
           -w '%{http_code}' "http://${service_name}:8080/" 2>/dev/null || true)
    [[ ${code} == "200" ]] || return 1
    if [[ ! -s ${health_body} ]]; then
        head -c 4000 /dev/zero | tr '\0' 'x' > "${health_body}"
    fi
    answer=$(ip netns exec "${ns_client}" curl -q -sS -m 5 \
             --data-binary "@${health_body}" \
             "http://${service_name}:8080/" 2>/dev/null || true)
    [[ ${answer} == "received=4000 bytes" ]]
}

# --- раунды -----------------------------------------------------------------

round_active() { [[ -f ${state_dir}/current ]]; }

current_fault() { base64 -d < "${state_dir}/current"; }

# Выбор без возврата: пока в наборе что-то есть, повторов не будет. Опустевший
# набор наполняется заново — все шесть неисправностей встречаются по разу.
#
# Неисправность, выбранная напарником через DN17_FAULT, уходит из набора так же,
# как выбранная скриптом. Иначе показательный раунд не считался бы, и та же
# неисправность могла выпасть следующей — серия из шести обещает шесть разных.
pick_fault() {
    local forced="${1:-}" bag=() rest=() name item last
    if [[ -s ${state_dir}/bag ]]; then
        mapfile -t bag < "${state_dir}/bag"
    fi
    if [[ ${#bag[@]} -eq 0 ]]; then
        mapfile -t bag < <(printf '%s\n' ${faults} | shuf)
        # Наполненный заново набор не должен начинаться с только что
        # разобранной неисправности: подряд одно и то же — не разбор, а
        # узнавание.
        last=$(cat "${state_dir}/last" 2>/dev/null || true)
        if [[ ${#bag[@]} -gt 1 && ${bag[0]} == "${last}" ]]; then
            bag=("${bag[@]:1}" "${bag[0]}")
        fi
    fi
    name="${forced:-${bag[0]}}"
    # Имя, которого в наборе уже нет, означает повтор внутри той же серии.
    # Отказ здесь надёжнее оговорки в тексте: обещание «шесть раундов — шесть
    # разных причин» держит скрипт, а не память ведущего.
    if [[ -n ${forced} ]] && ! printf '%s\n' "${bag[@]}" | grep -qx "${forced}"; then
        echo "Неисправность ${forced} в этой серии уже разобрана." >&2
        echo "Набор хранит остаток серии. Чтобы начать новую: $0 down && $0 up" >&2
        return 3
    fi
    for item in "${bag[@]}"; do
        [[ ${item} == "${name}" ]] || rest+=("${item}")
    done
    if [[ ${#rest[@]} -gt 0 ]]; then
        printf '%s\n' "${rest[@]}" > "${state_dir}/bag"
    else
        : > "${state_dir}/bag"
    fi
    printf '%s' "${name}" > "${state_dir}/last"
    printf '%s' "${name}"
}

new_round() {
    require_lab
    if round_active; then
        echo "Раунд уже идёт. Сначала: $0 diagnose \"...\" или $0 reveal" >&2
        exit 1
    fi
    repair_all
    if ! path_is_healthy; then
        echo "Исходный путь неисправен ещё до раунда: обращение по имени не вернуло 200." >&2
        echo "Разберитесь с состоянием стенда ($0 status) или пересоберите его: $0 down && $0 up" >&2
        exit 1
    fi
    if [[ -n ${DN17_FAULT:-} && " ${faults} " != *" ${DN17_FAULT} "* ]]; then
        echo "Неизвестная неисправность в DN17_FAULT: ${DN17_FAULT}" >&2
        echo "Допустимые имена: ${faults}" >&2
        exit 2
    fi
    local name
    if ! name=$(pick_fault "${DN17_FAULT:-}"); then
        exit 3
    fi
    apply_fault "${name}"
    printf '%s' "${name}" | base64 > "${state_dir}/current"
    date +%s > "${state_dir}/started"
    cat <<EOF
Раунд начат: в стенде одна неисправность.

Начните с обращения клиента и записывайте наблюдения:
  sudo ip netns exec ${ns_client} curl -q -sS -m 5 http://${service_name}:8080/

Когда причина названа:
  sudo bash $0 diagnose "ваш диагноз одной строкой"
EOF
}

elapsed_seconds() {
    local started
    started=$(cat "${state_dir}/started" 2>/dev/null || echo 0)
    echo $(( $(date +%s) - started ))
}

round_count() {
    [[ -f ${rounds_log} ]] || { echo 0; return 0; }
    wc -l < "${rounds_log}"
}

log_round() {
    local fault="$1" seconds="$2" answer="$3" number
    mkdir -p "${log_dir}"
    number=$(( $(round_count) + 1 ))
    printf '%d\t%s\t%s\t%s\t%s\n' "${number}" "$(date --iso-8601=seconds)" \
        "${seconds}" "${fault}" "${answer}" >> "${rounds_log}"
}

finish_round() {
    local answer="$1" fault seconds
    require_lab
    if ! round_active; then
        echo "Раунд не начат. Сначала: $0 new" >&2
        exit 1
    fi
    fault=$(current_fault)
    seconds=$(elapsed_seconds)
    log_round "${fault}" "${seconds}" "${answer}"
    # Состояние раунда снимается до печати разбора, а не после. Иначе вывод,
    # пущенный в head или less, обрывает скрипт сигналом, раунд остаётся
    # открытым, и следующий new отказывается начинать.
    rm -f "${state_dir}/current" "${state_dir}/started"
    printf 'Время раунда: %d мин %02d с\n\n' $((seconds / 60)) $((seconds % 60))
    if [[ ${answer} != "—" ]]; then
        printf 'Ваш диагноз: %s\n\n' "${answer}"
    fi
    explain_fault "${fault}"
    printf '\nСравните свой диагноз с причиной честно: совпадение формулировок\n'
    printf 'значения не имеет, важно, названы ли участок и механизм.\n'
    printf '\nСнять неисправность и начать следующий раунд: %s new\n' "$0"
}

explain_fault() {
    case "$1" in
        mask) cat <<EOF
Причина: у клиента сужена маска — адрес ${ip_client}/29 вместо /24.
Владелец темы: глава 2 «IP-адреса, CIDR и подсети».

Ожидаемые наблюдения:
  - обращение завершается сразу и жалуется на имя: "Could not resolve host".
    Похоже на отказ DNS, но резолвер ${ip_dns} тоже оказался вне суженной
    подсети, и запрос к нему не уходит — симптом называет не причину;
  - шлюз ${ip_router_l} перестал попадать в подсеть клиента, и маршрут
    по умолчанию через него ядро удалило вместе с сужением префикса;
  - ip route get ${ip_dns} и ip route get ${ip_server} отвечают, что сеть
    недостижима: недостижимо всё за пределами /29, а не только сервер;
  - ip -br addr показывает /29 — сравнение с исходным состоянием решает.
EOF
        ;;
        arp) cat <<EOF
Причина: у клиента постоянная запись соседа для ${ip_router_l} с чужим
MAC-адресом 02:00:00:00:00:99.
Владелец темы: глава 3 «Локальная сеть: Ethernet, ARP, NDP и VLAN».

Ожидаемые наблюдения:
  - обращение висит до тайм-аута, ping до шлюза тоже не проходит;
  - маршрут у клиента верный: решение об отправке принято правильно;
  - ip neigh показывает PERMANENT и неожиданный MAC-адрес;
  - в захвате на маршрутизаторе (tcpdump -e) кадры видны, но адресованы не
    ему: интерфейс в режиме promiscuous их показывает, стек отбрасывает.
EOF
        ;;
        noroute) cat <<EOF
Причина: у сервера удалён маршрут по умолчанию, и ответ отправить некуда.
Владелец темы: глава 4 «Маршрутизация, ICMP и Path MTU».

Ожидаемые наблюдения:
  - обращение висит до тайм-аута;
  - в захвате на сервере виден входящий SYN — и ни одного исходящего пакета;
  - ip route get ${ip_client} в namespace сервера отвечает, что сеть
    недостижима;
  - служба при этом слушает порт: ss -ltn это подтверждает.
EOF
        ;;
        filter) cat <<EOF
Причина: маршрутизатор отбрасывает обратное направление — правило в цепочке
forward на пакеты с ${ip_server} и портом источника 8080.
Владелец темы: глава 9 «Firewall, NAT и conntrack».

Ожидаемые наблюдения:
  - обращение висит до тайм-аута;
  - в захвате на сервере видны и входящий SYN, и исходящий SYN-ACK: сервер
    ответил, значит причина не на нём;
  - до клиента SYN-ACK не доходит — захват на клиенте это показывает;
  - nft list ruleset на маршрутизаторе называет правило, счётчик растёт при
    повторном обращении.
EOF
        ;;
        mtu) cat <<EOF
Причина: на дальнем участке маршрутизатора MTU 1400, а ICMP-сообщения о
необходимости фрагментации он отбрасывает — чёрная дыра Path MTU.
Владелец темы: глава 4 «Маршрутизация, ICMP и Path MTU».

Ожидаемые наблюдения:
  - GET проходит, а POST с телом в несколько килобайт висит до тайм-аута:
    отказ зависит от размера, а не от адреса и порта;
  - в захвате на сервере рукопожатие есть, и дальше приходит только
    последний, неполный сегмент тела; полноразмерных сегментов нет, и сервер
    подтверждает пришедшее выборочно (SACK) — потерялись именно большие;
  - ip link на маршрутизаторе показывает MTU 1400 на eth1;
  - ICMP-сообщение о необходимости фрагментации на клиент не приходит,
    поэтому клиент не уменьшает MSS и повторяет тот же размер.

Проверка размером:
  head -c 4000 /dev/zero | tr '\\0' 'x' > /tmp/body.txt
  sudo ip netns exec ${ns_client} curl -q -sS -m 5 --data-binary @/tmp/body.txt \\
      http://${service_name}:8080/
EOF
        ;;
        dns) cat <<EOF
Причина: резолвер отвечает на ${service_name} адресом 203.0.113.99, по
которому службы нет.
Владелец темы: глава 6 «DNS: от имени до IP-адреса».

Ожидаемые наблюдения:
  - обращение по имени не проходит, обращение по адресу ${ip_server}
    проходит — это и есть решающая проверка;
  - curl жалуется не на тайм-аут: примерно через три секунды он сообщает
    "Could not connect to server". Столько уходит на попытки маршрутизатора
    найти .99 в своём сегменте, после чего он отвечает ICMP host unreachable;
  - dig @${ip_dns} ${service_name} +short возвращает 203.0.113.99;
  - в захвате на клиенте SYN уходит к .99, ответа нет, а в конце приходит
    ICMP от ${ip_router_l};
  - служба и путь до сервера исправны, менять на них нечего.
EOF
        ;;
        *) echo "Неизвестная неисправность: $1" >&2; return 1 ;;
    esac
}

show_score() {
    if [[ ! -s ${rounds_log} ]]; then
        printf 'Раундов пока не было.\n'
        return 0
    fi
    printf 'раунд  время причина   диагноз\n'
    awk -F'\t' '{
        m = int($3 / 60); s = $3 % 60;
        printf "%-6s %2d:%02d %-9s %s\n", $1, m, s, $4, $5
    }' "${rounds_log}"
    printf '\nЖурнал: %s\n' "${rounds_log}"
}

show_status() {
    printf 'Namespace:\n'
    local ns
    for ns in "${ns_client}" "${ns_dns}" "${ns_router}" "${ns_server}"; do
        if namespace_exists "${ns}"; then
            printf '  %-12s есть\n' "${ns}"
        else
            printf '  %-12s нет\n' "${ns}"
        fi
    done
    lab_is_up || return 0
    printf '\nСлужба на сервере: '
    if [[ -f ${service_pid} ]] && kill -0 "$(cat "${service_pid}")" 2>/dev/null; then
        printf 'работает\n'
    else
        printf 'не работает\n'
    fi
    printf 'Резолвер: '
    if [[ -f ${dns_pid} ]] && kill -0 "$(cat "${dns_pid}")" 2>/dev/null; then
        printf 'работает\n'
    else
        printf 'не работает\n'
    fi
    # Что именно сломано, status не печатает намеренно: иначе слепой разбор
    # перестал бы быть слепым.
    printf '\nРаунд: '
    if round_active; then
        printf 'идёт, %d с\n' "$(elapsed_seconds)"
    else
        printf 'не начат\n'
    fi
    printf 'Раундов в журнале: %s\n' "$(round_count)"
}

case "${1:-}" in
    check)    require_root; run_check ;;
    up)       require_root; lab_up ;;
    new)      require_root; new_round ;;
    diagnose)
        require_root
        if [[ -z ${2:-} ]]; then
            echo "Нужен диагноз одной строкой: $0 diagnose \"причина и участок\"" >&2
            echo "Если версии нет, раунд закрывается так: $0 reveal" >&2
            exit 2
        fi
        finish_round "$2"
        ;;
    reveal)   require_root; finish_round "—" ;;
    repair)
        require_root
        # Раунд снимается только через diagnose или reveal: они пишут причину в
        # журнал. Молчаливый repair убрал бы причину из серии, не оставив
        # записи, и «шесть раундов — шесть разных причин» перестало бы
        # выполняться.
        if round_active; then
            echo "Идёт раунд: закройте его — $0 diagnose \"...\" или $0 reveal" >&2
            exit 2
        fi
        repair_all
        echo "Неисправности сняты."
        ;;
    score)    show_score ;;
    status)   show_status ;;
    down)     require_root; lab_down ;;
    *)        sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
