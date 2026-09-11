#!/usr/bin/env bash
#
# Учебный стенд главы 13: NetworkPolicy и диагностика сетевого dataplane.
#
#   bash 13-network-policy-dataplane/lab.sh check           # проверка среды
#   bash 13-network-policy-dataplane/lab.sh up              # кластер с Cilium, приложение, клиенты
#   bash 13-network-policy-dataplane/lab.sh show            # версии, Pod, политики, endpoint Cilium
#   bash 13-network-policy-dataplane/lab.sh matrix          # кто до кого доходит прямо сейчас
#   bash 13-network-policy-dataplane/lab.sh policy [NAME]   # манифесты политик практики
#   bash 13-network-policy-dataplane/lab.sh agent POD CMD   # команда в агенте Cilium на узле Pod
#   bash 13-network-policy-dataplane/lab.sh hold            # держать одно соединение batch → api
#   bash 13-network-policy-dataplane/lab.sh break [NAME]    # внести ошибку в политики
#   bash 13-network-policy-dataplane/lab.sh fix             # применить правильный набор политик
#   bash 13-network-policy-dataplane/lab.sh verify          # нужное разрешено, лишнее запрещено
#   bash 13-network-policy-dataplane/lab.sh down            # удалить всё
#
# Кластер поднимает kind, но без встроенного сетевого плагина: его место
# занимает Cilium. Он исполняет NetworkPolicy в eBPF и через Hubble сообщает,
# какой пакет какая политика пропустила или отбросила. Внешний сервер — контейнер
# в сети kind, как клиент в главе 12.
#
# Объекты стенда имеют префикс dn13.

set -euo pipefail

cluster="dn13"
state_dir="${HOME}/.kube"
kubeconfig="${state_dir}/dn13.yaml"
break_state="${state_dir}/dn13.break"
ext_name="dn13-ext"

app_image="registry.k8s.io/e2e-test-images/agnhost:2.53"
# Cilium 1.20 проходит e2e-тесты на Kubernetes 1.33–1.36, версии 1.37 в этом
# списке нет. Поэтому узлы на 1.36, а не на образе kind по умолчанию.
node_image="kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
cilium_version="1.20.1"
cilium_cli_version="v0.20.0"

faults=(or port typo dns family)

sudo_prefix=""
if ! docker info >/dev/null 2>&1; then
    sudo_prefix="sudo"
fi
kind_bin="$(command -v kind || true)"

dk()       { ${sudo_prefix} docker "$@"; }
kind_run() { ${sudo_prefix} "${kind_bin}" "$@"; }
kc()       { kubectl --kubeconfig "${kubeconfig}" "$@"; }
cil()      { KUBECONFIG="${kubeconfig}" cilium "$@"; }

cluster_exists() { kind_run get clusters 2>/dev/null | grep -qx "$1"; }

# --- проверка среды ---------------------------------------------------------

check_failures=0
ok()   { printf '[ ok ]   %s\n' "$1"; }
bad()  { printf '[ FAIL ] %s\n' "$1"; check_failures=$((check_failures + 1)); }
note() { printf '[ note ] %s\n' "$1"; }

run_check() {
    printf 'Проверка среды, нужной этой практике.\n\n'

    local tool
    for tool in docker kind kubectl cilium; do
        if command -v "${tool}" >/dev/null 2>&1; then
            ok "${tool} найден"
        else
            bad "${tool} не найден"
        fi
    done

    if command -v cilium >/dev/null 2>&1; then
        local cli
        cli="$(cilium version --client 2>/dev/null | awk '/^cilium-cli:/ {print $2}')"
        if [[ ${cli} != "${cilium_cli_version}" ]]; then
            note "cilium-cli ${cli:-неизвестной версии}: практика проверена с ${cilium_cli_version}"
        fi
    fi

    if dk info >/dev/null 2>&1; then
        if [[ -z ${sudo_prefix} ]]; then
            ok "docker отвечает без sudo"
        else
            ok "docker отвечает через sudo"
        fi
    else
        bad "docker не отвечает: демон не запущен или нет прав"
    fi

    # Узлы kind — контейнеры, ядро у них общее с хостом. Программы eBPF Cilium
    # загружает в это ядро, и ему нужно ядро не старше 5.10.
    local kv major minor rest
    kv="$(uname -r)"
    major="${kv%%.*}"; rest="${kv#*.}"; minor="${rest%%[!0-9]*}"
    if (( major > 5 || (major == 5 && minor >= 10) )); then
        ok "ядро ${kv}: Cilium нужно не старше 5.10"
    else
        bad "ядро ${kv}: Cilium нужно не старше 5.10"
    fi

    # Замер работающего стенда: два узла с Cilium — около 1,8 ГиБ.
    local mem_gb
    mem_gb="$(awk '/MemAvailable/ {printf "%d", $2 / 1024 / 1024}' /proc/meminfo)"
    if (( mem_gb >= 3 )); then
        ok "свободной памяти ${mem_gb} ГиБ"
    else
        note "свободной памяти ${mem_gb} ГиБ: стенду нужно около двух"
    fi

    local others
    others="$(kind_run get clusters 2>/dev/null | grep -vx "${cluster}" || true)"
    if [[ -n ${others} ]]; then
        note "есть другие кластеры kind ($(tr '\n' ' ' <<< "${others}")): они занимают память; кластеры глав 11 и 12 удаляются командами их стендов down"
        # Лимиты inotify общие для всех контейнеров хоста. При 128 экземплярах
        # и работающем кластере стенда worker второго кластера не дождался
        # kubelet; kind в известных проблемах связывает такие отказы с этим лимитом.
        local instances
        instances="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)"
        if (( instances < 512 )); then
            note "fs.inotify.max_user_instances = ${instances}: с узлами других кластеров kubelet может не запуститься; kind советует 512"
        fi
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
    printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nname: %s\n' "${cluster}"
    # Без встроенного плагина узлы остаются NotReady, пока не встанет Cilium.
    printf 'networking:\n  ipFamily: dual\n  kubeProxyMode: iptables\n  disableDefaultCNI: true\nnodes:\n'
    printf '  - role: control-plane\n    image: %s\n' "${node_image}"
    printf '  - role: worker\n    image: %s\n' "${node_image}"
}

app_manifest() {
    cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: dn13
---
apiVersion: v1
kind: Namespace
metadata:
  name: dn13-mon
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: dn13
spec:
  replicas: 2
  selector:
    matchLabels: {app: api}
  template:
    metadata:
      labels: {app: api}
    spec:
      # По одному Pod на узел: так в практике есть путь и внутри узла, и между узлами.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: {app: api}
      tolerations:
        - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
      containers:
        - name: api
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
  name: api
  namespace: dn13
spec:
  ipFamilyPolicy: PreferDualStack
  selector: {app: api}
  ports:
    - {name: http, port: 80, targetPort: 8080}
EOF
    local ns pod label
    for ns_pod_label in dn13/web/web dn13/batch/batch dn13-mon/scraper/scraper dn13-mon/toolbox/toolbox; do
        IFS=/ read -r ns pod label <<< "${ns_pod_label}"
        cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${ns}
  labels: {app: ${label}}
spec:
  containers:
    - name: ${pod}
      image: ${app_image}
      args: ["pause"]
EOF
    done
}

ext_addr4() { dk inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${ext_name}"; }
ext_addr6() { dk inspect -f '{{.NetworkSettings.Networks.kind.GlobalIPv6Address}}' "${ext_name}"; }
cip()       { kc -n dn13 get svc api -o "jsonpath={.spec.clusterIPs[$1]}"; }

# Правильный набор политик. Разрешено только то, что нужно:
#   web      → api:8080 и внешний сервер dn13-ext:8080 по обоим семействам;
#   scraper  → api:8080 из namespace dn13-mon;
#   все Pod dn13 → DNS кластера.
# Остальное в dn13 запрещено в обе стороны.
policy_manifest() {
    local name="${1:-all}"
    local e4 e6
    case "${name}" in
        deny|dns|api|egress|all) ;;
        *) printf 'Неизвестная политика: %s. Есть: deny dns api egress all\n' "${name}" >&2; exit 1 ;;
    esac

    if [[ ${name} == deny || ${name} == all ]]; then
        cat <<'EOF'
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: dn13
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
    fi
    if [[ ${name} == dns || ${name} == all ]]; then
        cat <<'EOF'
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: dn13
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
EOF
    fi
    if [[ ${name} == api || ${name} == all ]]; then
        cat <<'EOF'
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-ingress
  namespace: dn13
spec:
  podSelector:
    matchLabels: {app: api}
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels: {app: web}
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: dn13-mon}
          podSelector:
            matchLabels: {app: scraper}
      ports:
        - {protocol: TCP, port: 8080}
EOF
    fi
    if [[ ${name} == egress || ${name} == all ]]; then
        e4="$(ext_addr4)"; e6="$(ext_addr6)"
        cat <<EOF
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-egress
  namespace: dn13
spec:
  podSelector:
    matchLabels: {app: web}
  policyTypes: [Egress]
  egress:
    - to:
        - podSelector:
            matchLabels: {app: api}
      ports:
        - {protocol: TCP, port: 8080}
    - to:
        - ipBlock: {cidr: ${e4}/32}
        - ipBlock: {cidr: ${e6}/128}
      ports:
        - {protocol: TCP, port: 8080}
EOF
    fi
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

lab_up() {
    mkdir -p "${state_dir}"
    if cluster_exists "${cluster}"; then
        echo "Кластер ${cluster} уже существует. Сначала: $0 down" >&2
        exit 1
    fi
    command -v cilium >/dev/null 2>&1 || { echo "Не найден cilium-cli: установите его по разделу «Стенд» главы." >&2; exit 1; }

    printf 'Создаю кластер: два узла, dual-stack, без встроенного сетевого плагина.\n\n'
    cluster_config | kind_run create cluster --config - --kubeconfig "${kubeconfig}"
    fix_owner "${kubeconfig}"

    printf '\nСтавлю Cilium %s. Первый раз скачиваются образы, это несколько минут.\n' "${cilium_version}"
    cil install --version "${cilium_version}" \
        --set ipam.mode=kubernetes \
        --set ipv6.enabled=true \
        --set hubble.enabled=true >/dev/null
    cil status --wait --wait-duration 10m >/dev/null
    kc wait --for=condition=Ready nodes --all --timeout=180s >/dev/null

    printf 'Запускаю внешний сервер и приложение.\n'
    dk rm -f "${ext_name}" >/dev/null 2>&1 || true
    dk run -d --name "${ext_name}" --network kind "${app_image}" netexec --http-port=8080 >/dev/null
    app_manifest | kc apply -f - >/dev/null
    kc -n dn13 rollout status deploy/api --timeout=240s >/dev/null
    kc -n dn13 wait --for=condition=Ready pod --all --timeout=180s >/dev/null
    kc -n dn13-mon wait --for=condition=Ready pod --all --timeout=180s >/dev/null
    rm -f "${break_state}"

    cat <<EOF

Стенд готов. Политик пока нет: связность в кластере открыта. Настройте доступ:

  export KUBECONFIG=${kubeconfig}

Дальше — $0 show
EOF
}

lab_down() {
    if cluster_exists "${cluster}"; then
        kind_run delete cluster --name "${cluster}"
    fi
    dk rm -f "${ext_name}" >/dev/null 2>&1 || true
    rm -f "${kubeconfig}" "${break_state}"
    echo "Объекты стенда удалены, если они существовали."
}

# --- что получилось ---------------------------------------------------------

agent_on() {
    kc -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=$1" \
        -o jsonpath='{.items[0].metadata.name}'
}

# Строка endpoint Cilium для Pod: номер, применение политики на вход и на
# выход, identity. Ищется по адресу Pod, а не по метке: первой в строке стоит
# не обязательно app — у Pod с именованным портом там служебная метка gen:.
endpoint_row() {
    local ns=$1 pod=$2 node ip
    node="$(kc -n "${ns}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')"
    ip="$(kc -n "${ns}" get pod "${pod}" -o jsonpath='{.status.podIP}')"
    kc -n kube-system exec "$(agent_on "${node}")" -c cilium-agent -- cilium-dbg endpoint list 2>/dev/null \
        | awk -v ip="${ip}" '$1 ~ /^[0-9]+$/ { for (i = 6; i <= NF; i++) if ($i == ip) { print $1, $2, $3, $4; exit } }'
}

lab_show() {
    printf '### Версии\n'
    printf 'Kubernetes:        %s\n' "$(kc get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
    printf 'Cilium:            %s\n' "$(kc -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*:\(v[0-9.]*\).*/\1/')"
    printf 'режим kube-proxy:  %s\n' "$(kc -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | awk '/^mode:/ {print $2}')"

    printf '\n### Pod практики\n'
    kc get pods -A -l 'app in (api,web,batch,scraper,toolbox)' \
        -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,IPS:.status.podIPs[*].ip'

    printf '\n### Service api и внешний сервер\n'
    printf 'api:       %s %s\n' "$(cip 0)" "$(cip 1)"
    printf '%-10s %s %s\n' "${ext_name}:" "$(ext_addr4)" "$(ext_addr6)"

    printf '\n### NetworkPolicy\n'
    kc get networkpolicy -A 2>/dev/null || true

    printf '\n### Endpoint Cilium: применяется ли политика\n'
    printf '%-9s %-21s %-9s %-9s %-9s %s\n' NAMESPACE POD ENDPOINT INGRESS EGRESS IDENTITY
    local ns pod row
    while read -r ns pod; do
        row="$(endpoint_row "${ns}" "${pod}")"
        # shellcheck disable=SC2086
        printf '%-9s %-21s %-9s %-9s %-9s %s\n' "${ns}" "${pod}" ${row:-? ? ? ?}
    done < <(kc get pods -A -l 'app in (api,web,batch,scraper,toolbox)' \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}')
}

# Один exec на клиента: по запросу curl на каждый адрес, коды через пробел.
codes_from() {
    local ns=$1 pod=$2
    shift 2
    kc -n "${ns}" exec "${pod}" -- sh -c \
        'for u in "$@"; do printf "%s " "$(curl -s -m 3 -o /dev/null -w "%{http_code}" "$u")"; done' \
        sh "$@" 2>/dev/null || true
}

lab_matrix() {
    local c4 c6 e4 e6 client codes
    c4="$(cip 0)"; c6="$(cip 1)"; e4="$(ext_addr4)"; e6="$(ext_addr6)"
    printf 'Код HTTP на новое соединение; 000 — HTTP-ответа нет: пакет отброшен, соединение отвергнуто или имя не разрешилось.\n\n'
    printf '%-18s %-6s %-6s %-9s %-6s %-6s\n' CLIENT API4 API6 API-NAME EXT4 EXT6
    for client in dn13/web dn13/batch dn13-mon/scraper dn13-mon/toolbox; do
        codes="$(codes_from "${client%/*}" "${client#*/}" \
            "http://${c4}/" "http://[${c6}]/" "http://api.dn13.svc.cluster.local/" \
            "http://${e4}:8080/" "http://[${e6}]:8080/")"
        # shellcheck disable=SC2086
        printf '%-18s %-6s %-6s %-9s %-6s %-6s\n' "${client}" ${codes:-? ? ? ? ?}
    done
}

# --- доступ -----------------------------------------------------------------

lab_agent() {
    [[ $# -gt 1 ]] || { echo "Укажите Pod и команду: $0 agent web hubble observe --last 5" >&2; exit 1; }
    local target=$1 ns node
    shift
    ns="$(kc get pods -A --field-selector "metadata.name=${target}" -o jsonpath='{.items[0].metadata.namespace}')"
    [[ -n ${ns} ]] || { echo "Pod ${target} не найден" >&2; exit 1; }
    node="$(kc -n "${ns}" get pod "${target}" -o jsonpath='{.spec.nodeName}')"
    kc -n kube-system exec "$(agent_on "${node}")" -c cilium-agent -- "$@"
}

# Одно TCP-соединение, по которому раз в секунду уходит HTTP-запрос. Новые
# соединения проверяет matrix; здесь видно, что политика делает с уже открытым.
lab_hold() {
    local ip name
    ip="$(kc -n dn13 get pods -l app=api -o jsonpath='{.items[0].status.podIP}')"
    name="$(kc -n dn13 get pods -l app=api -o jsonpath='{.items[0].metadata.name}')"
    # После Ctrl-C kubectl отключается, а цикл внутри Pod продолжает слать
    # запросы — замерено на стенде. Такой хвост засоряет Hubble и счётчики,
    # поэтому цикл помечен, прошлый убирается перед стартом, а сам он живёт
    # не дольше трёх минут.
    kc -n dn13 exec batch -- pkill -f dn13-hold >/dev/null 2>&1 || true
    printf 'Одно соединение batch → %s (%s:8080), запрос раз в секунду.\n' "${name}" "${ip}"
    printf 'Остановить: Ctrl-C; в Pod цикл сам завершится не позже чем через 3 минуты.\n\n'
    kc -n dn13 exec -i batch -- timeout 180 bash -s "${ip}" dn13-hold <<'EOF'
exec 3<>"/dev/tcp/$1/8080" || { echo "соединение не открылось"; exit 1; }
for (( i = 1; i <= 180; i++ )); do
    printf 'GET /hostname HTTP/1.1\r\nHost: api\r\n\r\n' >&3
    if read -t 2 -r status <&3; then
        len=0
        while read -t 2 -r line <&3; do
            line=${line%$'\r'}
            [[ -z ${line} ]] && break
            [[ ${line} == Content-Length:* ]] && len=${line#*: }
        done
        body=""
        read -t 2 -r -N "${len}" body <&3 || true
        code=${status#* }
        printf '%s  запрос %3d: %s от %s\n' "$(date -u +%T)" "${i}" "${code%% *}" "${body}"
    else
        printf '%s  запрос %3d: нет ответа\n' "$(date -u +%T)" "${i}"
    fi
    sleep 1
done
EOF
}

# --- неисправности ----------------------------------------------------------

apply_policies() { policy_manifest all | kc apply -f - >/dev/null; }

lab_break() {
    local fault="${1:-}"
    if [[ -f ${break_state} ]]; then
        echo "Политики уже испорчены. Сначала: $0 fix" >&2
        exit 1
    fi
    local hidden=0
    if [[ -z ${fault} ]]; then
        fault="${faults[RANDOM % ${#faults[@]}]}"
        hidden=1
    fi

    apply_policies
    case "${fault}" in
        or)
            # Селекторы namespace и Pod разнесены в два элемента списка: вместо
            # «scraper из dn13-mon» получается «весь dn13-mon или app=scraper из dn13».
            kc -n dn13 patch networkpolicy api-ingress --type json -p '[
              {"op":"replace","path":"/spec/ingress/0/from/1","value":{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"dn13-mon"}}}},
              {"op":"add","path":"/spec/ingress/0/from/-","value":{"podSelector":{"matchLabels":{"app":"scraper"}}}}
            ]' >/dev/null ;;
        port)
            # Порт Service вместо порта Pod.
            kc -n dn13 patch networkpolicy api-ingress --type json \
                -p '[{"op":"replace","path":"/spec/ingress/0/ports/0/port","value":80}]' >/dev/null ;;
        typo)
            kc -n dn13 patch networkpolicy api-ingress --type json \
                -p '[{"op":"replace","path":"/spec/podSelector/matchLabels/app","value":"apl"}]' >/dev/null ;;
        dns)
            # Метка похожа на правильную, но namespace с таким именем нет.
            kc -n dn13 patch networkpolicy allow-dns --type json \
                -p '[{"op":"replace","path":"/spec/egress/0/to/0/namespaceSelector/matchLabels/kubernetes.io~1metadata.name","value":"kube-dns"}]' >/dev/null ;;
        family)
            kc -n dn13 patch networkpolicy web-egress --type json \
                -p '[{"op":"remove","path":"/spec/egress/1/to/1"}]' >/dev/null ;;
        *)
            printf 'Неизвестная неисправность: %s. Есть: %s\n' "${fault}" "${faults[*]}" >&2
            exit 1 ;;
    esac
    printf '%s\n' "${fault}" > "${break_state}"
    sleep 5

    if (( hidden )); then
        echo "В политиках одна ошибка. Какая — выясните сами; ответ записан в ${break_state}."
    else
        echo "Внесено: ${fault}."
    fi
}

lab_fix() {
    apply_policies
    rm -f "${break_state}"
    sleep 5
    echo "Правильный набор политик применён."
}

# --- проверки ---------------------------------------------------------------

pass() { printf '[ ok ]   %s\n' "$1"; }
miss() { printf '[  -  ]  %s\n' "$1"; verify_missing=$((verify_missing + 1)); }

# Код HTTP и код завершения curl через пробел: «200 0», «000 28».
code_from() {
    kc -n "$1" exec "$2" -- sh -c 'curl -s -m 3 -o /dev/null -w "%{http_code}" "$1"; echo " $?"' sh "$3" 2>/dev/null || true
}

# Разрешённое засчитывается по коду 200. Запрещённое — только по таймауту,
# коду завершения curl 28: Cilium отбрасывает запрещённое молча. Одного кода
# 000 мало — его же дают отвергнутое соединение и ошибка имени. Пустой вывод
# значит, что не отработал сам exec, и о политике тоже ничего не говорит.
expect_open() {
    local what=$1 result code
    result="$(code_from "$2" "$3" "$4")"
    code="${result%% *}"
    if [[ ${code} == 200 ]]; then
        pass "разрешено: ${what}"
    else
        miss "должно быть разрешено: ${what} — код ${code:-не получен}"
    fi
}
expect_closed() {
    local what=$1 result code rc
    result="$(code_from "$2" "$3" "$4")"
    code="${result%% *}"
    rc="${result##* }"
    if [[ ${code} == 000 && ${rc} == 28 ]]; then
        pass "запрещено: ${what}"
    elif [[ ${code} == 000 ]]; then
        miss "должно быть запрещено: ${what} — код 000, но не по таймауту: curl завершился с ${rc:-неизвестным кодом}"
    else
        miss "должно быть запрещено: ${what} — код ${code:-не получен}"
    fi
}

# Применение политики к endpoint по данным самого Cilium: «вход выход».
enforcement() {
    local row
    row="$(endpoint_row "$1" "$2")"
    if [[ -n ${row} ]]; then
        awk '{print $2, $3}' <<< "${row}"
    fi
}

verify_lab() {
    local verify_missing=0
    printf 'Проверки: нужное разрешено, лишнее запрещено.\n\n'

    if [[ -f ${break_state} ]]; then
        printf '[ note ] в политиках внесена ошибка; после разбора: %s fix\n\n' "$0"
    fi

    local c4 c6 e4 e6 api4
    c4="$(cip 0)"; c6="$(cip 1)"; e4="$(ext_addr4)"; e6="$(ext_addr6)"
    api4="$(kc -n dn13 get pods -l app=api -o jsonpath='{.items[0].status.podIP}')"

    expect_open   "web → api по имени"                      dn13 web "http://api.dn13.svc.cluster.local/"
    expect_open   "web → api, IPv4 ${c4}"                   dn13 web "http://${c4}/"
    expect_open   "web → api, IPv6 [${c6}]"                 dn13 web "http://[${c6}]/"
    expect_open   "scraper из dn13-mon → api"               dn13-mon scraper "http://${c4}/"
    expect_open   "web → ${ext_name}, IPv4 ${e4}"           dn13 web "http://${e4}:8080/"
    expect_open   "web → ${ext_name}, IPv6 [${e6}]"         dn13 web "http://[${e6}]:8080/"
    expect_closed "batch → api напрямую, ${api4}:8080"      dn13 batch "http://${api4}:8080/"
    expect_closed "toolbox из dn13-mon → api"               dn13-mon toolbox "http://${c4}/"
    expect_closed "batch → ${ext_name}, IPv4"               dn13 batch "http://${e4}:8080/"

    local pod state
    for pod in web batch $(kc -n dn13 get pods -l app=api -o jsonpath='{.items[*].metadata.name}'); do
        state="$(enforcement dn13 "${pod}")"
        if [[ ${state} == "Enabled Enabled" ]]; then
            pass "Cilium применяет политики к ${pod} на вход и на выход"
        else
            miss "Cilium применяет политики к ${pod}: вход и выход — ${state:-endpoint не найден}"
        fi
    done

    printf '\n'
    if [[ ${verify_missing} -eq 0 ]]; then
        printf 'Связность соответствует замыслу.\n'
        return 0
    fi
    printf 'Не выполнено проверок: %d. Найдите, какое правило разошлось с замыслом.\n' "${verify_missing}"
    return 1
}

case "${1:-}" in
    check)    run_check ;;
    up)       lab_up ;;
    show)     lab_show ;;
    matrix)   lab_matrix ;;
    policy)   policy_manifest "${2:-all}" ;;
    agent)    shift; lab_agent "$@" ;;
    hold)     lab_hold ;;
    break)    lab_break "${2:-}" ;;
    fix)      lab_fix ;;
    verify)   verify_lab ;;
    manifest) app_manifest ;;
    down)     lab_down ;;
    *)        sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
