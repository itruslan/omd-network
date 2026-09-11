#!/usr/bin/env bash
#
# Учебный стенд главы 12: Service, DNS, Ingress и Gateway API.
#
#   bash 12-service-dns-ingress/lab.sh check          # проверка среды
#   bash 12-service-dns-ingress/lab.sh up             # кластер, приложение, балансировщик, клиент
#   bash 12-service-dns-ingress/lab.sh show           # версии, Service, EndpointSlice, адреса входа
#   bash 12-service-dns-ingress/lab.sh pod CMD...     # команда в Pod probe внутри кластера
#   bash 12-service-dns-ingress/lab.sh client CMD...  # команда во внешнем клиенте
#   bash 12-service-dns-ingress/lab.sh break [NAME]   # сломать один участок пути
#   bash 12-service-dns-ingress/lab.sh fix            # вернуть исправное состояние
#   bash 12-service-dns-ingress/lab.sh verify         # проверки всех путей
#   bash 12-service-dns-ingress/lab.sh single         # кластер только с IPv4 для сравнения
#   bash 12-service-dns-ingress/lab.sh manifest       # манифесты приложения, Service и Gateway
#   bash 12-service-dns-ingress/lab.sh down           # удалить всё
#
# Кластер поднимает kind, как в главе 11. Внешний балансировщик и Gateway
# реализует cloud-provider-kind: он запускается отдельным контейнером и для
# каждого LoadBalancer, Ingress и Gateway создаёт контейнер с Envoy в сети
# kind. Внешний клиент — ещё один контейнер в той же сети: запросы с хоста
# зависели бы от его маршрутов и VPN, а клиент в сети kind у всех одинаков.
#
# Объекты стенда имеют префикс dn12, контейнеры Envoy — kindccm-.

set -euo pipefail

cluster="dn12"
single_cluster="dn12-v4"
state_dir="${HOME}/.kube"
kubeconfig="${state_dir}/dn12.yaml"
single_kubeconfig="${state_dir}/dn12-v4.yaml"
break_state="${state_dir}/dn12.break"

cpk_name="dn12-cpk"
client_name="dn12-client"
# Версии закреплены: от них зависит, что именно реализует балансировщик.
# В частности, у этой версии Gateway публикует адрес IPv6, но не слушает
# на нём, и глава на это наблюдение опирается.
cpk_image="registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v0.11.1"
app_image="registry.k8s.io/e2e-test-images/agnhost:2.53"
# Без явного образа kind берёт образ по умолчанию своей версии, и с новым kind
# стенд молча стал бы другим: версия Kubernetes, CoreDNS, а с ними и цепочки
# KUBE-SVC и KUBE-SEP, которые разбирает глава. Режим kube-proxy — туда же.
node_image="kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"

faults=(selector port ready route dns)

sudo_prefix=""
if ! docker info >/dev/null 2>&1; then
    sudo_prefix="sudo"
fi
kind_bin="$(command -v kind || true)"

dk()       { ${sudo_prefix} docker "$@"; }
kind_run() { ${sudo_prefix} "${kind_bin}" "$@"; }
kc()       { kubectl --kubeconfig "${kubeconfig}" "$@"; }

cluster_exists() { kind_run get clusters 2>/dev/null | grep -qx "$1"; }
container_running() { [[ "$(dk inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# --- проверка среды ---------------------------------------------------------

check_failures=0
ok()   { printf '[ ok ]   %s\n' "$1"; }
bad()  { printf '[ FAIL ] %s\n' "$1"; check_failures=$((check_failures + 1)); }
note() { printf '[ note ] %s\n' "$1"; }

run_check() {
    printf 'Проверка среды, нужной этой практике.\n\n'

    local tool
    for tool in docker kind kubectl nsenter tcpdump; do
        if command -v "${tool}" >/dev/null 2>&1; then
            ok "${tool} найден"
        else
            bad "${tool} не найден"
        fi
    done

    if dk info >/dev/null 2>&1; then
        if [[ -z ${sudo_prefix} ]]; then
            ok "docker отвечает без sudo"
        else
            ok "docker отвечает через sudo"
        fi
    else
        bad "docker не отвечает: демон не запущен или нет прав"
    fi

    # Замер работающего стенда: узлы, балансировщик, клиент и контейнеры
    # Envoy — около 1,1 ГиБ, кластер сравнения из шага 11 — ещё около 0,7.
    local mem_gb
    mem_gb="$(awk '/MemAvailable/ {printf "%d", $2 / 1024 / 1024}' /proc/meminfo)"
    if (( mem_gb >= 3 )); then
        ok "свободной памяти ${mem_gb} ГиБ"
    else
        note "свободной памяти ${mem_gb} ГиБ: вместе с кластером сравнения стенду нужно около двух"
    fi

    # cloud-provider-kind обслуживает все кластеры kind на машине, а не
    # только этот: чужие LoadBalancer тоже получат контейнеры Envoy.
    local others
    others="$(kind_run get clusters 2>/dev/null | grep -vxE "${cluster}|${single_cluster}" || true)"
    if [[ -n ${others} ]]; then
        note "есть другие кластеры kind ($(tr '\n' ' ' <<< "${others}")): балансировщик стенда увидит и их; кластер главы 11 удаляется командой её стенда down"
    fi

    if cluster_exists "${cluster}"; then
        note "кластер ${cluster} уже существует: up создавать его не станет"
    fi

    printf '\n'
    if [[ ${check_failures} -eq 0 ]]; then
        printf 'Environment is ready: all checks passed.\n'
        return 0
    fi
    printf 'Проверок провалено: %d. Установите недостающее и повторите.\n' "${check_failures}" >&2
    return 1
}

# --- что разворачивается ----------------------------------------------------

cluster_config() {
    local name=$1 family=$2 workers=$3
    printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nname: %s\n' "${name}"
    printf 'networking:\n  ipFamily: %s\n  kubeProxyMode: iptables\nnodes:\n' "${family}"
    printf '  - role: control-plane\n    image: %s\n' "${node_image}"
    local i
    for (( i = 0; i < workers; i++ )); do
        printf '  - role: worker\n    image: %s\n' "${node_image}"
    done
}

app_manifest() {
    cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: dn12
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dn12
spec:
  replicas: 2
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: web
          image: ${app_image}
          args: ["netexec", "--http-port=8080"]
          ports:
            - {name: http, containerPort: 8080}
          readinessProbe:
            tcpSocket: {port: 8080}
            periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: dn12
spec:
  ipFamilyPolicy: PreferDualStack
  selector: {app: web}
  ports:
    - {name: http, port: 80, targetPort: 8080}
---
apiVersion: v1
kind: Service
metadata:
  name: web-lb
  namespace: dn12
spec:
  type: LoadBalancer
  ipFamilyPolicy: PreferDualStack
  selector: {app: web}
  ports:
    - {name: http, port: 80, targetPort: 8080}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gw
  namespace: dn12
spec:
  gatewayClassName: cloud-provider-kind
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: {from: Same}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web
  namespace: dn12
spec:
  parentRefs:
    - name: gw
  hostnames: ["web.example.com"]
  rules:
    - backendRefs:
        - {name: web, port: 80}
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: default
spec:
  containers:
    - name: probe
      image: ${app_image}
      args: ["pause"]
EOF
}

# --- подъём -----------------------------------------------------------------

fix_owner() {
    local file=$1
    if [[ -n ${sudo_prefix} && -n ${SUDO_USER:-} ]]; then
        sudo chown "${SUDO_USER}" "${file}"
    elif [[ -n ${sudo_prefix} ]]; then
        sudo chown "$(id -u)" "${file}"
    fi
}

start_cpk() {
    if container_running "${cpk_name}"; then
        return 0
    fi
    dk rm -f "${cpk_name}" >/dev/null 2>&1 || true
    # Контроллеру нужен сокет Docker: балансировщики он создаёт контейнерами.
    dk run -d --name "${cpk_name}" --network host \
        -v /var/run/docker.sock:/var/run/docker.sock "${cpk_image}" >/dev/null
}

wait_for() {
    local what=$1 seconds=$2
    shift 2
    local i
    for (( i = 0; i < seconds; i += 3 )); do
        if [[ -n "$("$@" 2>/dev/null)" ]]; then
            return 0
        fi
        sleep 3
    done
    printf 'Не дождался: %s\n' "${what}" >&2
    return 1
}

lb_addr() { kc -n dn12 get svc web-lb -o "jsonpath={.status.loadBalancer.ingress[$1].ip}"; }
gw_addr() { kc -n dn12 get gateway gw -o "jsonpath={.status.addresses[$1].value}"; }
cip()     { kc -n dn12 get svc web -o "jsonpath={.spec.clusterIPs[$1]}"; }
client_addr4() { dk inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${client_name}"; }
client_addr6() { dk inspect -f '{{.NetworkSettings.Networks.kind.GlobalIPv6Address}}' "${client_name}"; }

lab_up() {
    mkdir -p "${state_dir}"
    if cluster_exists "${cluster}"; then
        echo "Кластер ${cluster} уже существует. Сначала: $0 down" >&2
        exit 1
    fi

    printf 'Создаю кластер: два узла, dual-stack. Это занимает пару минут.\n\n'
    cluster_config "${cluster}" dual 1 | kind_run create cluster --config - --kubeconfig "${kubeconfig}"
    fix_owner "${kubeconfig}"

    printf '\nЗапускаю балансировщик cloud-provider-kind и внешний клиент.\n'
    start_cpk
    dk rm -f "${client_name}" >/dev/null 2>&1 || true
    dk run -d --name "${client_name}" --network kind "${app_image}" \
        netexec --http-port=8080 >/dev/null

    # CRD Gateway API ставит сам контроллер; без них манифест не применится.
    wait_for "CRD Gateway API" 120 kc get crd gateways.gateway.networking.k8s.io -o name

    printf 'Разворачиваю приложение, Service, Gateway и Pod probe.\n'
    app_manifest | kc apply -f - >/dev/null
    kc -n dn12 rollout status deploy/web --timeout=180s
    kc -n default wait --for=condition=Ready pod/probe --timeout=180s
    wait_for "адрес LoadBalancer" 120 lb_addr 0
    wait_for "адрес Gateway" 120 gw_addr 0
    rm -f "${break_state}"

    cat <<EOF

Стенд готов. Настройте доступ к кластеру:

  export KUBECONFIG=${kubeconfig}

Дальше — $0 show
EOF
}

lab_single() {
    mkdir -p "${state_dir}"
    if cluster_exists "${single_cluster}"; then
        echo "Кластер ${single_cluster} уже существует."
    else
        printf 'Создаю кластер %s: один узел, только IPv4.\n\n' "${single_cluster}"
        cluster_config "${single_cluster}" ipv4 0 \
            | kind_run create cluster --config - --kubeconfig "${single_kubeconfig}"
        fix_owner "${single_kubeconfig}"
    fi
    cat <<EOF

Команды к этому кластеру отдавайте с его kubeconfig:

  kubectl --kubeconfig ${single_kubeconfig} get nodes

Удаляется он вместе со стендом: $0 down
EOF
}

lab_down() {
    # Сначала объекты, пока контроллер жив: контейнеры Envoy убирает он.
    if cluster_exists "${cluster}"; then
        kc delete ns dn12 --wait=true --timeout=120s >/dev/null 2>&1 || true
        sleep 5
    fi
    dk rm -f "${cpk_name}" "${client_name}" >/dev/null 2>&1 || true

    local name
    for name in "${cluster}" "${single_cluster}"; do
        if cluster_exists "${name}"; then
            kind_run delete cluster --name "${name}"
        fi
    done
    rm -f "${kubeconfig}" "${single_kubeconfig}" "${break_state}"

    # Контроллер помечает свои контейнеры именем кластера. Если он был
    # остановлен раньше объектов, контейнеры остаются — убираем по метке,
    # не задевая балансировщики других кластеров kind.
    local left
    for name in "${cluster}" "${single_cluster}"; do
        left="$(dk ps -aq --filter "label=io.x-k8s.cloud-provider-kind.cluster=${name}")"
        if [[ -n ${left} ]]; then
            # shellcheck disable=SC2086
            dk rm -f ${left} >/dev/null
        fi
    done
    echo "Объекты стенда удалены, если они существовали."
}

# --- что получилось ---------------------------------------------------------

lab_show() {
    printf '### Версии\n'
    printf 'Kubernetes:          %s\n' "$(kc get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
    printf 'CoreDNS:             %s\n' "$(kc -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')"
    printf 'режим kube-proxy:    %s\n' "$(kc -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | awk '/^mode:/ {print $2}')"
    printf 'cloud-provider-kind: %s\n' "${cpk_image##*:}"

    printf '\n### Service\n'
    kc -n dn12 get svc -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,POLICY:.spec.ipFamilyPolicy,CLUSTER-IPS:.spec.clusterIPs,EXTERNAL:.status.loadBalancer.ingress[*].ip,PORTS:.spec.ports[*].port'

    printf '\n### EndpointSlice\n'
    kc -n dn12 get endpointslices -o custom-columns='NAME:.metadata.name,SERVICE:.metadata.labels.kubernetes\.io/service-name,FAMILY:.addressType,ENDPOINTS:.endpoints[*].addresses[0],READY:.endpoints[*].conditions.ready'

    printf '\n### Pod приложения\n'
    kc -n dn12 get pods -l app=web -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IPS:.status.podIPs[*].ip'

    printf '\n### Вход извне\n'
    kc -n dn12 get gateway gw -o custom-columns='GATEWAY:.metadata.name,ADDRESSES:.status.addresses[*].value'
    kc -n dn12 get httproute web -o custom-columns='HTTPROUTE:.metadata.name,HOSTNAMES:.spec.hostnames'

    printf '\n### Узлы и внешний клиент (сеть kind)\n'
    kc get nodes -o custom-columns='NAME:.metadata.name,ADDRESSES:.status.addresses[*].address'
    printf '%-20s %s %s\n' "${client_name}" "$(client_addr4)" "$(client_addr6)"
}

# --- доступ -----------------------------------------------------------------

lab_pod() {
    [[ $# -gt 0 ]] || { echo "Укажите команду: $0 pod cat /etc/resolv.conf" >&2; exit 1; }
    kc -n default exec probe -- "$@"
}

lab_client() {
    [[ $# -gt 0 ]] || { echo "Укажите команду: $0 client curl -s http://<адрес>/hostname" >&2; exit 1; }
    dk exec "${client_name}" "$@"
}

# --- неисправности ----------------------------------------------------------

# Прокси держит пул соединений к бэкенду. Уже открытые соединения conntrack
# продолжает транслировать по-старому, и Gateway какое-то время отвечает 200
# через сломанный Service — замерено на этом стенде. Чтобы неисправность
# проявлялась сразу и одинаково, Pod перезапускаются и старые соединения рвутся.
restart_web() {
    kc -n dn12 rollout restart deploy/web >/dev/null
    kc -n dn12 rollout status deploy/web --timeout=180s >/dev/null 2>&1 || true
}

lab_break() {
    local fault="${1:-}"
    if [[ -f ${break_state} ]]; then
        echo "Стенд уже сломан. Сначала: $0 fix" >&2
        exit 1
    fi
    local hidden=0
    if [[ -z ${fault} ]]; then
        fault="${faults[RANDOM % ${#faults[@]}]}"
        hidden=1
    fi

    case "${fault}" in
        selector)
            kc -n dn12 patch svc web --type merge -p '{"spec":{"selector":{"app":"wbe"}}}' >/dev/null
            restart_web ;;
        port)
            kc -n dn12 patch svc web --type json \
                -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9090}]' >/dev/null
            restart_web ;;
        ready)
            # При обычном обновлении старые Pod живут, пока новые не готовы, и
            # Service продолжает работать. Recreate убирает старые сразу.
            # Патч стратегический: он сливает контейнеры по имени, а не
            # заменяет список целиком.
            kc -n dn12 patch deploy web -p \
                '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null},"template":{"spec":{"containers":[{"name":"web","readinessProbe":{"tcpSocket":{"port":9999}}}]}}}}' >/dev/null ;;
        route)
            kc -n dn12 patch httproute web --type json \
                -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"web-v2"}]' >/dev/null ;;
        dns)
            kc -n kube-system scale deploy coredns --replicas=0 >/dev/null
            kc -n kube-system wait --for=delete pod -l k8s-app=kube-dns --timeout=60s >/dev/null 2>&1 || true ;;
        *)
            printf 'Неизвестная неисправность: %s. Есть: %s\n' "${fault}" "${faults[*]}" >&2
            exit 1 ;;
    esac
    printf '%s\n' "${fault}" > "${break_state}"
    sleep 5

    if (( hidden )); then
        echo "Один участок пути сломан. Какой — выясните сами; ответ записан в ${break_state}."
    else
        echo "Сломано: ${fault}."
    fi
}

lab_fix() {
    app_manifest | kc apply -f - >/dev/null
    kc -n dn12 patch deploy web -p '{"spec":{"strategy":{"type":"RollingUpdate"}}}' >/dev/null
    kc -n kube-system scale deploy coredns --replicas=2 >/dev/null
    kc -n dn12 rollout status deploy/web --timeout=180s >/dev/null
    kc -n kube-system rollout status deploy/coredns --timeout=180s >/dev/null
    rm -f "${break_state}"
    echo "Исправное состояние восстановлено."
}

# --- проверки ---------------------------------------------------------------

pass() { printf '[ ok ]   %s\n' "$1"; }
miss() { printf '[  -  ]  %s\n' "$1"; verify_missing=$((verify_missing + 1)); }

# Проверка по коду ответа, а не по наличию текста: прокси на отказ бэкенда
# отвечает страницей с текстом ошибки, и непустой ответ ничего не доказывает.
code_from_pod()    { kc -n default exec probe -- curl -s -m 5 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }
code_from_client() { dk exec "${client_name}" curl -s -m 5 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }

# dig пишет сообщения об отказе в тот же поток, что и ответ, поэтому
# засчитывается только строка, похожая на адрес.
dig_addr() {
    kc -n default exec probe -- dig +short +time=2 +tries=1 "$1" "$2" 2>/dev/null \
        | grep -E '^[0-9a-f.:]+$' | head -1 || true
}

# go-template, а не jsonpath: фильтр jsonpath падает на EndpointSlice без
# конечных точек, а это ровно то состояние, которое нужно распознать.
ready_count() {
    kc -n dn12 get endpointslices -l kubernetes.io/service-name=web -o go-template \
        --template '{{range .items}}{{$t := .addressType}}{{range .endpoints}}{{if .conditions.ready}}{{$t}}{{"\n"}}{{end}}{{end}}{{end}}' \
        | grep -cx "$1" || true
}

verify_lab() {
    local verify_missing=0
    printf 'Проверки путей, которые разбирает глава.\n\n'

    if [[ -f ${break_state} ]]; then
        printf '[ note ] стенд в сломанном состоянии; после разбора: %s fix\n\n' "$0"
    fi

    # Имя должно разрешаться именно в адреса Service. Любой другой ответ, даже
    # похожий на адрес, означает, что цепочка «имя → Service» порвана.
    local name="web.dn12.svc.cluster.local"
    local a aaaa c4 c6 code
    c4="$(cip 0)"; c6="$(cip 1)"
    a="$(dig_addr "${name}" A)"
    aaaa="$(dig_addr "${name}" AAAA)"
    if [[ -n ${a} && ${a} == "${c4}" && ${aaaa} == "${c6}" ]]; then
        pass "DNS: ${name} → ${a} и ${aaaa}"
    else
        miss "DNS: ${name} → A ${a:-нет}, AAAA ${aaaa:-нет}; у Service ${c4:-нет} и ${c6:-нет}"
    fi

    local ready4 ready6
    ready4="$(ready_count IPv4)"
    ready6="$(ready_count IPv6)"
    if (( ready4 > 0 && ready6 > 0 )); then
        pass "EndpointSlice: готовых конечных точек IPv4 ${ready4}, IPv6 ${ready6}"
    else
        miss "EndpointSlice: готовых конечных точек IPv4 ${ready4}, IPv6 ${ready6}"
    fi

    code="$(code_from_pod "http://${c4}/hostname")"
    if [[ ${code} == 200 ]]; then
        pass "ClusterIP, IPv4: probe → ${c4}:80"
    else
        miss "ClusterIP, IPv4: probe → ${c4}:80, код ${code:-нет ответа}"
    fi
    code="$(code_from_pod -g "http://[${c6}]/hostname")"
    if [[ -n ${c6} && ${code} == 200 ]]; then
        pass "ClusterIP, IPv6: probe → [${c6}]:80"
    else
        miss "ClusterIP, IPv6: probe → [${c6:-нет адреса}]:80, код ${code:-нет ответа}"
    fi

    local l4 l6
    l4="$(lb_addr 0)"; l6="$(lb_addr 1)"
    code="$(code_from_client "http://${l4}/hostname")"
    if [[ -n ${l4} && ${code} == 200 ]]; then
        pass "LoadBalancer, IPv4: клиент → ${l4}:80"
    else
        miss "LoadBalancer, IPv4: клиент → ${l4:-нет адреса}:80, код ${code:-нет ответа}"
    fi
    code="$(code_from_client -g "http://[${l6}]/hostname")"
    if [[ -n ${l6} && ${code} == 200 ]]; then
        pass "LoadBalancer, IPv6: клиент → [${l6}]:80"
    else
        miss "LoadBalancer, IPv6: клиент → [${l6:-нет адреса}]:80, код ${code:-нет ответа}"
    fi

    local g4 g6
    g4="$(gw_addr 0)"; g6="$(gw_addr 1)"
    code="$(code_from_client -H 'Host: web.example.com' "http://${g4}/hostname")"
    if [[ -n ${g4} && ${code} == 200 ]]; then
        pass "Gateway, IPv4: клиент → ${g4}:80, Host: web.example.com"
    else
        miss "Gateway, IPv4: клиент → ${g4:-нет адреса}:80, Host: web.example.com, код ${code:-нет ответа}"
    fi
    if [[ -n ${g6} ]]; then
        printf '[ note ] Gateway публикует и адрес IPv6 %s — проверьте сами, слушает ли он его\n' "${g6}"
    fi

    # Выход наружу: внешний сервер видит не адрес Pod, а адрес узла. Засчитывается
    # только успешный ответ, в котором стоит адрес узла Pod: «непустой и не адрес
    # Pod» пропустил бы и текст ошибки.
    local resp seen probe_ip node_ip
    probe_ip="$(kc -n default get pod probe -o jsonpath='{.status.podIP}')"
    node_ip="$(kc -n default get pod probe -o jsonpath='{.status.hostIP}')"
    resp="$(kc -n default exec probe -- curl -s -m 5 -w ' %{http_code}' \
        "http://$(client_addr4):8080/clientip" 2>/dev/null || true)"
    code="${resp##* }"
    seen="${resp% *}"
    seen="${seen%:*}"
    if [[ ${code} == 200 && ${seen} == "${node_ip}" ]]; then
        pass "выход наружу: клиент видит probe как ${seen}, а не ${probe_ip}"
    else
        miss "выход наружу: код ${code:-нет ответа}, клиент видит ${seen:-ничего} вместо адреса узла ${node_ip}"
    fi

    printf '\n'
    if [[ ${verify_missing} -eq 0 ]]; then
        printf 'Все пути работают.\n'
        return 0
    fi
    printf 'Не работает проверок: %d. Найдите участок, на котором путь обрывается.\n' "${verify_missing}"
    return 1
}

case "${1:-}" in
    check)    run_check ;;
    up)       lab_up ;;
    show)     lab_show ;;
    pod)      shift; lab_pod "$@" ;;
    client)   shift; lab_client "$@" ;;
    break)    lab_break "${2:-}" ;;
    fix)      lab_fix ;;
    verify)   verify_lab ;;
    single)   lab_single ;;
    manifest) app_manifest ;;
    down)     lab_down ;;
    *)        sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
