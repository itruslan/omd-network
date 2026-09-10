#!/usr/bin/env bash
#
# Учебный стенд главы 11: сетевая модель Kubernetes и CNI.
#
#   bash 11-kubernetes-network/lab.sh check        # проверка среды
#   bash 11-kubernetes-network/lab.sh up           # кластер из двух узлов и три Pod
#   bash 11-kubernetes-network/lab.sh show         # адреса Pod, узлы, диапазоны
#   bash 11-kubernetes-network/lab.sh veth POD     # чей veth на узле и как в него смотреть
#   bash 11-kubernetes-network/lab.sh manifest     # манифест Pod практики
#   bash 11-kubernetes-network/lab.sh verify       # четыре наблюдения связности
#   bash 11-kubernetes-network/lab.sh down         # удалить кластер
#
# Кластер поднимает kind: узлы — контейнеры Docker, поэтому внутрь узла
# заходят теми же инструментами, что в главе 10. Сеть Pod создаёт плагин CNI,
# и именно её путь студент исследует сам.
#
# Все объекты имеют префикс dn11-; чужого стенд не трогает.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cluster="dn11"
state_dir="${HOME}/.kube"
kubeconfig="${state_dir}/dn11.yaml"

# Docker может требовать root, а может не требовать: это зависит от того,
# состоит ли пользователь в группе docker. kind вызывает docker сам, поэтому
# под sudo должен уходить весь kind, а не отдельная команда внутри него.
sudo_prefix=""
if ! docker info >/dev/null 2>&1; then
    sudo_prefix="sudo"
fi

# Путь к kind берётся один раз: под sudo обёртка вида "sudo command kind"
# не работает, потому что command — встроенная команда оболочки, а не файл.
kind_bin="$(command -v kind || true)"

dk()      { ${sudo_prefix} docker "$@"; }
kind_run() { ${sudo_prefix} "${kind_bin}" "$@"; }
kc()      { kubectl --kubeconfig "${kubeconfig}" "$@"; }

# --- проверка среды ---------------------------------------------------------

check_failures=0
ok()   { printf '[ ok ]   %s\n' "$1"; }
bad()  { printf '[ FAIL ] %s\n' "$1"; check_failures=$((check_failures + 1)); }

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

    # Кластер живёт в памяти и на диске хоста: полтора гигабайта образа узла
    # и около двух гигабайт памяти на два узла. Узнать об этом надо до
    # создания, а не по OOM в середине практики.
    local mem_gb
    mem_gb="$(awk '/MemAvailable/ {printf "%d", $2 / 1024 / 1024}' /proc/meminfo)"
    if (( mem_gb >= 3 )); then
        ok "свободной памяти ${mem_gb} ГиБ"
    else
        printf '[ note ] свободной памяти %s ГиБ: двум узлам может не хватить\n' "${mem_gb}"
    fi

    if kind_run get clusters 2>/dev/null | grep -qx "${cluster}"; then
        printf '[ note ] кластер %s уже существует: up создавать его не станет\n' "${cluster}"
    fi

    printf '\n'
    if [[ ${check_failures} -eq 0 ]]; then
        printf 'Environment is ready: all checks passed.\n'
        return 0
    fi
    printf 'Проверок провалено: %d. Установите недостающее и повторите.\n' "${check_failures}" >&2
    return 1
}

# --- кластер ----------------------------------------------------------------

cluster_config() {
    cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${cluster}
networking:
  ipFamily: dual
nodes:
  - role: control-plane
  - role: worker
EOF
}

pod_manifest() {
    cat <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: dn11-a
  labels: {app: dn11}
spec:
  nodeName: dn11-worker
  containers:
    - name: sh
      image: busybox:1.37
      command: ["sh", "-c", "sleep infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: dn11-b
  labels: {app: dn11}
spec:
  nodeName: dn11-worker
  containers:
    - name: sh
      image: busybox:1.37
      command: ["sh", "-c", "sleep infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: dn11-c
  labels: {app: dn11}
spec:
  nodeName: dn11-control-plane
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  containers:
    - name: sh
      image: busybox:1.37
      command: ["sh", "-c", "sleep infinity"]
EOF
}

lab_up() {
    mkdir -p "${state_dir}"
    if kind_run get clusters 2>/dev/null | grep -qx "${cluster}"; then
        echo "Кластер ${cluster} уже существует. Сначала: $0 down" >&2
        exit 1
    fi

    printf 'Создаю кластер: два узла, dual-stack. Это занимает пару минут.\n\n'
    cluster_config | kind_run create cluster --config - --kubeconfig "${kubeconfig}"

    # kind под sudo пишет kubeconfig от root: без этого kubectl студента
    # не сможет его прочитать.
    if [[ -n ${sudo_prefix} && -n ${SUDO_USER:-} ]]; then
        sudo chown "${SUDO_USER}" "${kubeconfig}"
    elif [[ -n ${sudo_prefix} ]]; then
        sudo chown "$(id -u)" "${kubeconfig}"
    fi

    printf '\nЗапускаю три Pod: два на dn11-worker, один на dn11-control-plane.\n'
    pod_manifest | kc apply -f - >/dev/null
    kc wait --for=condition=Ready pod/dn11-a pod/dn11-b pod/dn11-c --timeout=180s

    cat <<EOF

Кластер готов. Настройте доступ к нему:

  export KUBECONFIG=${kubeconfig}

Дальше — $0 show
EOF
}

lab_down() {
    if kind_run get clusters 2>/dev/null | grep -qx "${cluster}"; then
        kind_run delete cluster --name "${cluster}"
    else
        echo "Кластера ${cluster} нет."
    fi
    rm -f "${kubeconfig}"
    echo "Объекты стенда удалены, если они существовали."
}

# --- что получилось ---------------------------------------------------------

lab_show() {
    printf '### Диапазоны кластера\n'
    # Кластерные диапазоны не видны ни в одном объекте Node: их задают при
    # создании кластера, и kubeadm сохраняет их в своей ConfigMap. Без этой
    # строки первый уровень адресации остаётся на слово автора.
    kc -n kube-system get cm kubeadm-config \
        -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null \
        | grep -E 'podSubnet|serviceSubnet' \
        || printf 'ConfigMap kubeadm-config недоступна: кластер создан не kubeadm\n'

    printf '\n### Узлы\n'
    kc get nodes -o custom-columns='NAME:.metadata.name,IP:.status.addresses[0].address,VERSION:.status.nodeInfo.kubeletVersion'

    printf '\n### Диапазоны Pod, выданные узлам\n'
    kc get nodes -o custom-columns='NAME:.metadata.name,PODCIDRS:.spec.podCIDRs'

    printf '\n### Pod практики\n'
    kc get pods -l app=dn11 \
        -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IPS:.status.podIPs[*].ip'

    printf '\n### Сетевой плагин\n'
    kc get pods -n kube-system -o name | grep -Ei 'kindnet|calico|cilium|flannel' \
        || printf 'плагин по этим именам не найден: посмотрите kubectl -n kube-system get pods\n'
}

# --- чей veth на узле -------------------------------------------------------

node_of()  { kc get pod "$1" -o jsonpath='{.spec.nodeName}'; }
podip_of() { kc get pod "$1" -o jsonpath='{.status.podIP}'; }

lab_veth() {
    local pod="${1:-}"
    if [[ -z ${pod} ]]; then
        echo "Укажите Pod: $0 veth dn11-a" >&2
        exit 1
    fi
    local node ip veth npid
    node="$(node_of "${pod}")"
    ip="$(podip_of "${pod}")"
    # Плагин этого стенда не собирает Pod в мост: на каждый Pod на узле стоит
    # отдельный маршрут в его veth. Поэтому интерфейс ищется по маршруту к
    # адресу Pod, а не по членству в мосту.
    veth="$(dk exec "${node}" sh -c "ip route | awk '/^${ip} / {print \$3; exit}'")"
    npid="$(dk inspect -f '{{.State.Pid}}' "${node}")"

    if [[ -z ${veth} ]]; then
        printf 'Маршрута к %s на узле %s нет: возможно, плагин собирает Pod в мост.\n' \
            "${ip}" "${node}" >&2
        printf 'Посмотрите сами: %s exec %s ip route\n' "${sudo_prefix:+sudo }docker" "${node}" >&2
        return 1
    fi

    cat <<EOF
Pod:            ${pod}
Узел:           ${node}
Адрес Pod:      ${ip}
veth на узле:   ${veth}
PID узла:       ${npid}

Захват на этом интерфейсе — хостовым tcpdump в сетевом namespace узла:

  sudo nsenter -t ${npid} -n tcpdump -n -v -i ${veth} icmp
EOF
}

# --- четыре наблюдения ------------------------------------------------------

pass() { printf '[ ok ]   %s\n' "$1"; }
miss() { printf '[  -  ]  %s\n' "$1"; verify_missing=$((verify_missing + 1)); }

ping_from() {
    local pod=$1 flag=$2 addr=$3
    kc exec "${pod}" -- ping ${flag} -c2 -W2 "${addr}" >/dev/null 2>&1
}

verify_lab() {
    local verify_missing=0
    printf 'Четыре проверки связности, которые обещает глава.\n\n'

    local b4 b6 c4 c6
    b4="$(kc get pod dn11-b -o jsonpath='{.status.podIPs[0].ip}')"
    b6="$(kc get pod dn11-b -o jsonpath='{.status.podIPs[1].ip}')"
    c4="$(kc get pod dn11-c -o jsonpath='{.status.podIPs[0].ip}')"
    c6="$(kc get pod dn11-c -o jsonpath='{.status.podIPs[1].ip}')"

    if [[ -z ${b6} || -z ${c6} ]]; then
        miss "у Pod нет второго адреса: кластер поднят не как dual-stack"
    else
        pass "у dn11-b по два адреса: ${b4} и ${b6}"
    fi

    if ping_from dn11-a "" "${b4}"; then
        pass "тот же узел, IPv4: dn11-a → ${b4}"
    else
        miss "тот же узел, IPv4: dn11-a → ${b4} не проходит"
    fi

    if [[ -n ${b6} ]] && ping_from dn11-a "-6" "${b6}"; then
        pass "тот же узел, IPv6: dn11-a → ${b6}"
    else
        miss "тот же узел, IPv6: dn11-a → ${b6:-нет адреса} не проходит"
    fi

    if ping_from dn11-a "" "${c4}"; then
        pass "другой узел, IPv4: dn11-a → ${c4}"
    else
        miss "другой узел, IPv4: dn11-a → ${c4} не проходит"
    fi

    if [[ -n ${c6} ]] && ping_from dn11-a "-6" "${c6}"; then
        pass "другой узел, IPv6: dn11-a → ${c6}"
    else
        miss "другой узел, IPv6: dn11-a → ${c6:-нет адреса} не проходит"
    fi

    printf '\n'
    if [[ ${verify_missing} -eq 0 ]]; then
        printf 'Связность есть во всех четырёх случаях.\n'
        return 0
    fi
    printf 'Не хватает пунктов: %d. Вернитесь к соответствующему шагу.\n' "${verify_missing}"
    return 1
}

case "${1:-}" in
    check)    run_check ;;
    up)       lab_up ;;
    show)     lab_show ;;
    veth)     lab_veth "${2:-}" ;;
    manifest) pod_manifest ;;
    verify)   verify_lab ;;
    down)     lab_down ;;
    *)        sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
