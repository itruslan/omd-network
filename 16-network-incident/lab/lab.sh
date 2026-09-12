#!/usr/bin/env bash
#
# Генератор артефактов итогового инцидента (глава 16).
#
# ВНИМАНИЕ: этот каталог содержит ответы. Скрипт вносит неисправности, и
# по нему видно, какие именно. Откройте его после того, как оформите разбор.
#
#   bash lab.sh check              # проверка среды
#   bash lab.sh up                 # кластер, край, VPN-шлюз, партнёр, магазин
#   bash lab.sh record <каталог>   # сценарий инцидента и сбор артефактов, ~23 минуты
#   bash lab.sh down               # удалить всё, что создано
#
# Студенту стенд запускать не нужно: артефакты уже собраны и лежат рядом, в
# каталоге artifacts. Генератор приложен, чтобы происхождение каждого файла
# можно было проверить и воспроизвести.
#
# Схема:
#
#   покупатели 203.0.113.100–139
#        │ dn16-inet 203.0.113.0/24
#   край dn16-edge 203.0.113.10 (nginx: кэш и фильтр запросов)
#        │ сеть kind
#   узлы kind: NodePort 30080 (storefront), 30081 (checkout); Cilium
#        │ сеть kind
#   VPN-шлюз dn16-vpngw ── dn16-vpn 192.0.2.0/24 (туннель) ── dn16-prtr
#                                                               │ dn16-partner 198.51.100.0/24
#                                                        API партнёра 198.51.100.10:8080
#
# Объекты стенда имеют префикс dn16.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cluster="dn16"
kubeconfig="${HOME}/.kube/dn16.yaml"
state="${HOME}/.cache/dn16-lab"

node_image="kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
cilium_version="1.20.1"
cilium_cli_version="v0.20.0"
app_image="python:3.14-alpine"
edge_image="nginx:1.29-alpine"
router_image="alpine:3"

# Сценарий: момент каждого события в секундах от начала записи.
t_c1=300          # канал к партнёру переведён на туннель, профиль защиты шлюза
t_c2=600          # выкатка checkout v2
t_c3=780          # включён фильтр запросов на краю
t_snapshot=900    # дежурный снимает состояние кластера
t_rollback=1080   # откат checkout v2
t_end=1320
# Для отладки сценарий можно ускорить: DN16_SPEED=5 проходит его за пять минут.
speed="${DN16_SPEED:-1}"

containers=(dn16-edge dn16-vpngw dn16-prtr dn16-partner dn16-users)
networks=(dn16-inet dn16-vpn dn16-partner)

sudo_prefix=""
if ! docker info >/dev/null 2>&1; then
    sudo_prefix="sudo"
fi
kind_bin="$(command -v kind || true)"

dk()       { ${sudo_prefix} docker "$@"; }
kind_run() { ${sudo_prefix} "${kind_bin}" "$@"; }
kc()       { kubectl --kubeconfig "${kubeconfig}" "$@"; }
cil()      { KUBECONFIG="${kubeconfig}" cilium "$@"; }
pid_of()   { dk inspect -f '{{.State.Pid}}' "$1"; }
nsx()      { local p; p="$(pid_of "$1")"; shift; sudo nsenter -t "${p}" -n "$@"; }
addr_of()  { dk inspect -f "{{(index .NetworkSettings.Networks \"$2\").IPAddress}}" "$1"; }
# Имя интерфейса контейнера по адресу: порядок eth0/eth1 зависит от
# порядка подключения сетей, и полагаться на него нельзя.
ifname()   { nsx "$1" ip -o -4 addr show | awk -v ip="$2" '$4 ~ "^"ip"/" {print $2}'; }

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cluster_exists() { kind_run get clusters 2>/dev/null | grep -qx "${cluster}"; }

# --- проверка среды ---------------------------------------------------------

check_failures=0
ok()   { printf '[ ok ]   %s\n' "$1"; }
bad()  { printf '[ FAIL ] %s\n' "$1"; check_failures=$((check_failures + 1)); }
note() { printf '[ note ] %s\n' "$1"; }

run_check() {
    printf 'Проверка среды генератора.\n\n'
    local tool
    for tool in docker kind kubectl cilium jq python3 curl sudo; do
        if command -v "${tool}" >/dev/null 2>&1; then ok "${tool} найден"; else bad "${tool} не найден"; fi
    done
    for tool in nsenter tcpdump nft nstat; do
        if sudo sh -c "command -v ${tool}" >/dev/null 2>&1; then ok "${tool} доступен через sudo"; else bad "${tool} не найден"; fi
    done
    if command -v cilium >/dev/null 2>&1; then
        local cli
        cli="$(cilium version --client 2>/dev/null | awk '/^cilium-cli:/ {print $2}')"
        [[ ${cli} == "${cilium_cli_version}" ]] || note "cilium-cli ${cli:-неизвестной версии}: генератор проверен с ${cilium_cli_version}"
    fi
    if dk info >/dev/null 2>&1; then ok "docker отвечает"; else bad "docker не отвечает"; fi
    local mem_gb
    mem_gb="$(awk '/MemAvailable/ {printf "%d", $2 / 1024 / 1024}' /proc/meminfo)"
    if (( mem_gb >= 3 )); then ok "свободной памяти ${mem_gb} ГиБ"; else note "свободной памяти ${mem_gb} ГиБ: стенду нужно около 2,5"; fi
    local net
    for net in 203.0.113.0/24 192.0.2.0/24 198.51.100.0/24; do
        if ip route show | grep -q "^${net%/*}"; then bad "диапазон ${net} уже занят на хосте"; else ok "диапазон ${net} свободен"; fi
    done
    cluster_exists && note "кластер ${cluster} уже существует: up создавать его не станет"
    printf '\n'
    if [[ ${check_failures} -eq 0 ]]; then
        printf 'Environment is ready: all checks passed.\n'
        return 0
    fi
    printf 'Проверок провалено: %d.\n' "${check_failures}" >&2
    return 1
}

# --- что разворачивается ----------------------------------------------------

cluster_config() {
    cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${cluster}
networking:
  kubeProxyMode: iptables
  disableDefaultCNI: true
nodes:
  - role: control-plane
    image: ${node_image}
  - role: worker
    image: ${node_image}
EOF
}

deployment() {  # имя роль версия реплик
    cat <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $1
  namespace: shop
spec:
  replicas: $4
  selector:
    matchLabels: {app: $2, version: $3}
  template:
    metadata:
      labels: {app: $2, version: $3}
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: {app: $2}
      tolerations:
        - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
      containers:
        - name: app
          image: ${app_image}
          command: ["python3", "-u", "/app/app.py"]
          env:
            - {name: ROLE, value: $2}
            - {name: VERSION, value: $3}
            - name: POD_NAME
              valueFrom: {fieldRef: {fieldPath: metadata.name}}
          ports:
            - {name: http, containerPort: 8080}
          readinessProbe:
            httpGet: {path: /healthz, port: 8080}
            periodSeconds: 5
          volumeMounts:
            - {name: code, mountPath: /app}
            - {name: logs, mountPath: /var/log/shop}
      volumes:
        - name: code
          configMap: {name: shop-app}
        - name: logs
          hostPath: {path: /var/log/shop, type: DirectoryOrCreate}
EOF
}

service() {  # имя роль nodePort
    cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: $1
  namespace: shop
spec:
  type: NodePort
  selector: {app: $2}
  ports:
    - {name: http, port: 80, targetPort: 8080, nodePort: $3}
EOF
}

# Политики магазина. Выход из namespace закрыт; открыт DNS для всех и
# доступ к партнёру для checkout. Аналитике доступ закрыт намеренно.
policies() {
    cat <<'EOF'
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: shop
spec:
  podSelector: {}
  policyTypes: [Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: shop
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: kube-system}
          podSelector:
            matchLabels: {k8s-app: kube-dns}
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checkout-to-partner
  namespace: shop
spec:
  podSelector:
    matchLabels: {app: checkout, version: v1}
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock: {cidr: 198.51.100.0/24}
      ports:
        - {protocol: TCP, port: 8080}
EOF
}

# --- подъём и разборка ------------------------------------------------------

lab_up() {
    if cluster_exists; then
        echo "Кластер ${cluster} уже существует. Сначала: $0 down" >&2
        exit 1
    fi
    command -v cilium >/dev/null 2>&1 || { echo "Не найден cilium-cli." >&2; exit 1; }
    mkdir -p "${state}" "$(dirname "${kubeconfig}")"

    printf 'Кластер: два узла, без встроенного сетевого плагина.\n'
    cluster_config | kind_run create cluster --config - --kubeconfig "${kubeconfig}" >/dev/null
    [[ -n ${sudo_prefix} ]] && sudo chown "$(id -u)" "${kubeconfig}"

    printf 'Cilium %s с Hubble и метриками агента.\n' "${cilium_version}"
    cil install --version "${cilium_version}" \
        --set ipam.mode=kubernetes \
        --set hubble.enabled=true \
        --set prometheus.enabled=true >/dev/null
    cil status --wait --wait-duration 10m >/dev/null
    kc wait --for=condition=Ready nodes --all --timeout=180s >/dev/null

    printf 'Сети и контейнеры вокруг кластера.\n'
    dk network create --subnet 203.0.113.0/24 --gateway 203.0.113.1 dn16-inet >/dev/null
    dk network create --subnet 192.0.2.0/24 --gateway 192.0.2.1 dn16-vpn >/dev/null
    dk network create --subnet 198.51.100.0/24 --gateway 198.51.100.1 dn16-partner >/dev/null

    local node1 node2 gw
    node1="$(addr_of dn16-control-plane kind)"
    node2="$(addr_of dn16-worker kind)"
    mkdir -p "${state}/edge" "${state}/edge-log"
    sed -e "s/@NODE1@/${node1}/" -e "s/@NODE2@/${node2}/" "${here}/edge.conf" > "${state}/nginx.conf"
    cp "${here}/waf-off.conf" "${state}/edge/waf.conf"

    dk run -d --name dn16-edge --network dn16-inet --ip 203.0.113.10 \
        -v "${state}/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "${state}/edge:/etc/nginx/edge:ro" \
        -v "${state}/edge-log:/var/log/edge" "${edge_image}" >/dev/null
    dk network connect kind dn16-edge

    dk run -d --name dn16-vpngw --network kind --cap-add NET_ADMIN \
        --sysctl net.ipv4.ip_forward=1 "${router_image}" sleep infinity >/dev/null
    dk network connect --ip 192.0.2.10 dn16-vpn dn16-vpngw
    dk run -d --name dn16-prtr --network dn16-vpn --ip 192.0.2.20 --cap-add NET_ADMIN \
        --sysctl net.ipv4.ip_forward=1 "${router_image}" sleep infinity >/dev/null
    dk network connect --ip 198.51.100.254 dn16-partner dn16-prtr
    dk run -d --name dn16-partner --network dn16-partner --ip 198.51.100.10 \
        -v "${here}/partner.py:/partner.py:ro" "${app_image}" python3 -u /partner.py >/dev/null
    dk run -d --name dn16-users --network dn16-inet --ip 203.0.113.100 \
        -v "${here}/users.py:/users.py:ro" "${app_image}" sleep infinity >/dev/null

    # Docker кладёт в namespace контейнера таблицу NAT своего встроенного DNS.
    # Шлюзу и маршрутизатору DNS не нужен, а в снимке правил она только мешает.
    nsx dn16-vpngw nft delete table ip nat 2>/dev/null || true
    nsx dn16-prtr nft delete table ip nat 2>/dev/null || true

    gw="$(addr_of dn16-vpngw kind)"
    nsx dn16-vpngw ip route add 198.51.100.0/24 via 192.0.2.20
    nsx dn16-prtr ip route add 172.16.0.0/12 via 192.0.2.10
    nsx dn16-partner ip route add 172.16.0.0/12 via 198.51.100.254
    local node i users_if
    for node in dn16-control-plane dn16-worker; do
        dk exec "${node}" ip route add 198.51.100.0/24 via "${gw}"
    done
    users_if="$(ifname dn16-users 203.0.113.100)"
    for i in $(seq 101 139); do
        nsx dn16-users ip addr add "203.0.113.${i}/24" dev "${users_if}"
    done

    printf 'Магазин в namespace shop.\n'
    kc create namespace shop >/dev/null
    kc -n shop create configmap shop-app --from-file=app.py="${here}/app.py" >/dev/null
    {
        deployment storefront storefront v1 2
        deployment checkout checkout v1 2
        deployment recommendations recommendations v1 1
        service storefront storefront 30080
        service checkout checkout 30081
        policies
    } | kc apply -f - >/dev/null
    local d
    for d in storefront checkout recommendations; do
        kc -n shop rollout status "deploy/${d}" --timeout=300s >/dev/null
    done

    cat <<EOF

Стенд готов.
  край:          203.0.113.10 (Host: shop.example.com)
  узлы:          ${node1}, ${node2}
  VPN-шлюз:      ${gw} / 192.0.2.10
  API партнёра:  198.51.100.10:8080

Дальше — $0 record <каталог>
EOF
}

lab_down() {
    dk rm -f "${containers[@]}" >/dev/null 2>&1 || true
    dk network rm "${networks[@]}" >/dev/null 2>&1 || true
    if cluster_exists; then
        kind_run delete cluster --name "${cluster}" >/dev/null
    fi
    rm -f "${kubeconfig}"
    sudo rm -rf "${state}"
    printf 'Стенд удалён.\n'
}

# --- сценарий ---------------------------------------------------------------

start_time=0
wait_until() { # секунда сценария
    local target=$(( start_time + $1 / speed ))
    while (( $(date +%s) < target )); do sleep 1; done
}

msk() { TZ=Europe/Moscow date +'%Y-%m-%d %H:%M'; }

change() { # автор описание
    printf '| %s | %s | %s |\n' "$(msk)" "$1" "$2" >> "${out}/changes.md"
}

vpngw_state() { # файл
    {
        printf '# Снято: %s\n# Точка: dn16-vpngw, сетевой namespace шлюза\n' "$(utc)"
        printf '\n$ ip -br addr\n';           nsx dn16-vpngw ip -br addr
        printf '\n$ ip -o link show | mtu\n';  nsx dn16-vpngw ip -o link show | awk '{print $2, $4, $5}'
        printf '\n$ ip route\n';              nsx dn16-vpngw ip route
        printf '\n$ nft list ruleset\n';      nsx dn16-vpngw nft list ruleset
        printf '\n$ nstat -az IpForwDatagrams IpFragFails IcmpOutDestUnreachs\n'
        nsx dn16-vpngw nstat -az IpForwDatagrams IpFragFails IcmpOutDestUnreachs
    } > "$1"
}

lab_record() {
    out="${1:?Укажите каталог для артефактов}"
    cluster_exists || { echo "Стенд не поднят: $0 up" >&2; exit 1; }
    mkdir -p "${out}"
    out="$(cd "${out}" && pwd)"
    local work="${state}/record"
    sudo rm -rf "${work}"; mkdir -p "${work}"

    local gw_inside gw_tunnel prtr_tunnel
    gw_inside="$(ifname dn16-vpngw "$(addr_of dn16-vpngw kind)")"
    gw_tunnel="$(ifname dn16-vpngw 192.0.2.10)"
    prtr_tunnel="$(ifname dn16-prtr 192.0.2.20)"

    cat > "${out}/changes.md" <<'EOF'
# Журнал изменений

Время московское (UTC+3), с точностью до минуты: так записи ведёт команда.

| Время | Кто | Изменение |
|---|---|---|
| 2026-08-14 11:20 | платформа | Договор с сервисом аналитики расторгнут. Выход к 203.0.113.99 закрыт политикой `default-deny-egress`; клиент выгрузки в `recommendations` отключат в следующем релизе |
EOF

    printf 'Сбор: захваты на шлюзе, Hubble на обоих узлах, метрики раз в 15 секунд.\n'
    vpngw_state "${out}/vpngw-state-start.txt"
    # Фоновые процессы запускаются напрямую, без функций-обёрток: иначе $!
    # указывает на подоболочку, и остановить сам процесс по нему нельзя.
    # Захваты пишутся в /tmp: профиль AppArmor для tcpdump в Ubuntu не даёт
    # создавать файлы в скрытых каталогах домашнего, и запись в ~/.cache
    # молча не происходит.
    local filter='host 198.51.100.10 or icmp' gw_pid pcap_dir
    gw_pid="$(pid_of dn16-vpngw)"
    pcap_dir="$(mktemp -d /tmp/dn16-pcap.XXXXXX)"
    sudo nsenter -t "${gw_pid}" -n tcpdump -Z root -i "${gw_inside}" -s 256 -U -w "${pcap_dir}/vpngw-inside.pcap" "${filter}" 2>"${work}/tcpdump-inside.log" &
    local pcap1=$!
    sudo nsenter -t "${gw_pid}" -n tcpdump -Z root -i "${gw_tunnel}" -s 256 -U -w "${pcap_dir}/vpngw-tunnel.pcap" "${filter}" 2>"${work}/tcpdump-tunnel.log" &
    local pcap2=$!
    local agent hubble_pids=()
    for agent in $(kc -n kube-system get pods -l k8s-app=cilium -o name); do
        kubectl --kubeconfig "${kubeconfig}" -n kube-system exec "${agent}" -c cilium-agent -- \
            hubble observe --follow -o json --namespace shop > "${work}/hubble-${agent##*/}.json" 2>/dev/null &
        hubble_pids+=($!)
    done
    sudo python3 "${here}/sampler.py" --out "${work}/metrics.txt" --interval 15 --stop "${work}/stop" &
    local sampler=$!

    local duration=$(( t_end / speed ))
    dk exec -d dn16-users sh -c "python3 /users.py --edge 203.0.113.10 --duration $((duration - 30)) > /tmp/users.log 2>&1"
    start_time=$(date +%s)
    printf 'Запись началась: %s, продлится %d с.\n' "$(utc)" "${duration}"

    wait_until "${t_c1}"
    nsx dn16-vpngw ip link set "${gw_tunnel}" mtu 1400
    nsx dn16-prtr ip link set "${prtr_tunnel}" mtu 1400
    nsx dn16-vpngw nft -f - <<'EOF'
table inet hardening {
    chain output {
        type filter hook output priority filter; policy accept;
        icmp type destination-unreachable counter drop
    }
}
EOF
    change "сеть" "Канал к партнёру доставки переведён с выделенной линии на IPsec-туннель. На шлюзе dn16-vpngw применён базовый профиль защиты"
    printf '%s  канал к партнёру переведён на туннель\n' "$(utc)"

    wait_until "${t_c2}"
    deployment checkout-v2 checkout v2 1 | kc apply -f - >/dev/null
    change "разработка" "Выкатка checkout v2 канарейкой, одна реплика: повтор обращения к партнёру, если соединение не установилось. Повод — жалобы на ошибки оформления заказа"
    printf '%s  выкатка checkout v2\n' "$(utc)"

    wait_until "${t_c3}"
    cp "${here}/waf-on.conf" "${state}/edge/waf.conf"
    dk exec dn16-edge nginx -s reload 2>/dev/null
    change "безопасность" "На пограничном узле включён набор правил sqli-lite в режиме блокировки"
    printf '%s  включён фильтр запросов\n' "$(utc)"

    wait_until "${t_snapshot}"
    {
        printf '# Снято дежурным: %s\n# Точка: kubectl с правами на namespace shop\n' "$(utc)"
        printf '\n$ kubectl -n shop get pods -o wide --show-labels\n'; kc -n shop get pods -o wide --show-labels
        printf '\n$ kubectl -n shop get endpointslices\n';            kc -n shop get endpointslices
        printf '\n$ kubectl -n shop get networkpolicy -o yaml\n'
        kc -n shop get networkpolicy -o yaml | grep -vE '^\s+(creationTimestamp|generation|resourceVersion|uid):|kubectl.kubernetes.io/last-applied|^\s+\{"apiVersion'
    } > "${out}/k8s-shop.txt"
    printf '%s  снимок состояния кластера\n' "$(utc)"

    wait_until "${t_rollback}"
    kc -n shop delete deployment checkout-v2 >/dev/null
    change "дежурный" "Откат checkout v2: Deployment checkout-v2 удалён"
    printf '%s  откат checkout v2\n' "$(utc)"

    wait_until "${t_end}"
    printf 'Остановка сбора.\n'
    touch "${work}/stop"; wait "${sampler}" || true
    kill "${hubble_pids[@]}" 2>/dev/null || true
    # Не pkill -f: шаблон совпал бы с командной строкой самого sudo pkill.
    # sudo передаёт полученный сигнал запущенной команде.
    sudo kill -INT "${pcap1}" "${pcap2}" 2>/dev/null || true
    wait "${pcap1}" "${pcap2}" 2>/dev/null || true
    vpngw_state "${out}/vpngw-state-end.txt"

    printf 'Сборка артефактов.\n'
    sudo cat "${state}/edge-log/access.log" > "${out}/edge-access.log"
    cp "${state}/edge/waf.conf" "${out}/edge-waf.conf"
    for node in dn16-control-plane dn16-worker; do
        dk exec "${node}" sh -c 'cat /var/log/shop/*.log'
    done | sort > "${out}/app.log"
    dk logs dn16-partner 2>/dev/null | sort > "${out}/partner.log"
    sudo cp "${pcap_dir}/vpngw-inside.pcap" "${pcap_dir}/vpngw-tunnel.pcap" "${out}/"
    sudo chown "$(id -u):$(id -g)" "${out}"/*.pcap
    sudo rm -rf "${pcap_dir}"
    python3 "${here}/flowlog.py" "${out}/vpngw-inside.pcap" > "${out}/flowlog-vpngw.txt"
    cp "${work}/metrics.txt" "${out}/metrics.txt"
    # Из потока Hubble оставлены отказы и начала соединений с партнёром:
    # полный поток за двадцать минут весит десятки мегабайт.
    cat "${work}"/hubble-*.json \
        | jq -c 'select(.flow != null)
                 | select(.flow.verdict == "DROPPED"
                          or ((.flow.IP.destination == "198.51.100.10")
                              and (.flow.l4.TCP.flags.SYN == true)
                              and (.flow.l4.TCP.flags.ACK != true)))' \
        | sort > "${out}/hubble-shop.json"
    dk exec dn16-users cat /tmp/users.log > "${work}/users.log"

    printf '\nГотово: %s\n' "${out}"
    ls -la "${out}"
}

case "${1:-}" in
    check)  run_check ;;
    up)     lab_up ;;
    record) shift; lab_record "$@" ;;
    down)   lab_down ;;
    *)      printf 'Usage: %s check|up|record <каталог>|down\n' "$0" >&2; exit 2 ;;
esac
