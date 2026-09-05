#!/usr/bin/env bash
#
# Учебный стенд главы 7: HTTP, TLS, обратный прокси и балансировка.
#
#   sudo bash 07-http-tls-proxy/lab.sh check       # проверка среды
#   sudo bash 07-http-tls-proxy/lab.sh up          # поднять стенд
#   sudo bash 07-http-tls-proxy/lab.sh status      # что сейчас запущено
#   sudo bash 07-http-tls-proxy/lab.sh stop-app a  # погасить один бэкенд
#   sudo bash 07-http-tls-proxy/lab.sh slow-app a  # заменить его медленным
#   sudo bash 07-http-tls-proxy/lab.sh start-app a # вернуть обычный
#   sudo bash 07-http-tls-proxy/lab.sh down        # убрать всё
#
# Все объекты имеют префикс dn7-; чужого стенд не трогает.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_dir="/run/dn7-lab"
tls_dir="${state_dir}/tls"

bridge="dn7-br0"
ns_client="dn7-client"
ns_proxy="dn7-proxy"
ns_app_a="dn7-app-a"
ns_app_b="dn7-app-b"

ip_client="198.51.100.10"
ip_proxy="198.51.100.20"
ip_app_a="198.51.100.31"
ip_app_b="198.51.100.32"

cert_name="shop.lab.example"

check_ns="dn7-check-ns"
check_bridge="dn7-check-br0"

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo "Нужны права root: запустите через sudo." >&2
        exit 1
    fi
}

namespace_exists() { ip netns list | awk '{print $1}' | grep -qx "$1"; }
link_exists() { ip link show "$1" >/dev/null 2>&1; }

ns_of() {
    case "$1" in
        a) echo "${ns_app_a}" ;;
        b) echo "${ns_app_b}" ;;
        *) echo "Бэкенд задаётся буквой a или b." >&2; exit 1 ;;
    esac
}

# --- проверка среды ---------------------------------------------------------

check_failures=0
ok()   { printf '[ ok ]   %s\n' "$1"; }
fail() { printf '[ FAIL ] %s\n' "$1"; check_failures=$((check_failures + 1)); }

check_cleanup() {
    namespace_exists "${check_ns}" && ip netns delete "${check_ns}" >/dev/null 2>&1 || true
    link_exists "${check_bridge}" && ip link delete "${check_bridge}" >/dev/null 2>&1 || true
}

run_check() {
    if namespace_exists "${check_ns}" || link_exists "${check_bridge}"; then
        echo "Проверочный объект уже существует. Выясните его происхождение, затем: $0 down" >&2
        return 1
    fi
    trap check_cleanup EXIT
    printf 'Проверка среды, нужной этой практике.\n\n'

    local tool
    for tool in ip nginx openssl curl tcpdump python3; do
        if command -v "${tool}" >/dev/null 2>&1; then
            ok "${tool} найден"
        else
            fail "${tool} не найден"
        fi
    done

    if ip netns add "${check_ns}" >/dev/null 2>&1; then
        ok "network namespace создаётся"
    else
        fail "network namespace создать не удалось"
    fi

    if ip link add "${check_bridge}" type bridge >/dev/null 2>&1; then
        ok "bridge создаётся"
    else
        fail "bridge создать не удалось"
    fi

    # Сертификат выпускается на месте: без него практика не начнётся.
    local probe="${state_dir}/probe"
    mkdir -p "${probe}"
    if openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj "/CN=probe" -keyout "${probe}/k.pem" -out "${probe}/c.pem" \
        >/dev/null 2>&1; then
        ok "openssl выпускает сертификат"
    else
        fail "openssl не смог выпустить сертификат"
    fi
    rm -rf "${probe}"

    # Конфигурация проверяется до выпуска сертификата, поэтому единственная
    # ожидаемая жалоба — на отсутствующий файл сертификата. Вывод берётся в
    # переменную: при pipefail неуспех самой nginx -t погасил бы весь конвейер.
    mkdir -p "${state_dir}"
    local nginx_out
    nginx_out="$(nginx -t -c "${here}/nginx.conf" -p "${state_dir}" 2>&1 || true)"
    if grep -q 'test is successful' <<<"${nginx_out}"; then
        ok "nginx принимает конфигурацию стенда"
    elif grep -q 'cannot load certificate' <<<"${nginx_out}"; then
        ok "nginx принимает конфигурацию стенда (сертификат появится при up)"
    else
        fail "nginx отверг конфигурацию стенда"
        printf '%s\n' "${nginx_out}" | head -3 >&2
    fi

    printf '\n'
    if [[ ${check_failures} -eq 0 ]]; then
        printf 'Environment is ready: all checks passed.\n'
        return 0
    fi
    printf 'Проверок провалено: %d. Установите недостающее и повторите.\n' "${check_failures}" >&2
    return 1
}

# --- выпуск сертификатов ----------------------------------------------------

issue_certs() {
    mkdir -p "${tls_dir}"
    # Своя мини-инфраструктура доверия: удостоверяющий центр стенда и один
    # сертификат сервера. Так студент видит обе стороны проверки — и подпись,
    # и имя, — не выходя в интернет.
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -subj "/CN=DevOps Course Lab CA" \
        -keyout "${tls_dir}/ca.key" -out "${tls_dir}/ca.crt" >/dev/null 2>&1

    openssl req -newkey rsa:2048 -nodes \
        -subj "/CN=${cert_name}" \
        -keyout "${tls_dir}/server.key" -out "${tls_dir}/server.csr" >/dev/null 2>&1

    # Имя сервиса объявляется в subjectAltName: по RFC 9525 проверять имя по
    # Common Name запрещено, поэтому сертификат без этого расширения негоден.
    printf 'subjectAltName=DNS:%s\n' "${cert_name}" > "${tls_dir}/server.ext"
    openssl x509 -req -in "${tls_dir}/server.csr" -days 2 \
        -CA "${tls_dir}/ca.crt" -CAkey "${tls_dir}/ca.key" -CAcreateserial \
        -extfile "${tls_dir}/server.ext" \
        -out "${tls_dir}/server.crt" >/dev/null 2>&1

    chmod 644 "${tls_dir}/ca.crt" "${tls_dir}/server.crt"
}

# --- запуск и остановка приложений ------------------------------------------

app_pidfile() { echo "${state_dir}/app-$1.pid"; }
app_logfile() { echo "${state_dir}/app-$1.log"; }

start_app() {
    local letter="$1"
    local delay="${2:-0}"
    local ns
    ns="$(ns_of "${letter}")"
    local pidfile
    pidfile="$(app_pidfile "${letter}")"
    local logfile
    logfile="$(app_logfile "${letter}")"

    stop_app "${letter}" quiet
    ip netns exec "${ns}" python3 "${here}/app.py" \
        --name "${letter}" --port 8080 --delay "${delay}" \
        >>"${logfile}" 2>&1 &
    echo $! > "${pidfile}"
    sleep 0.3
}

stop_app() {
    local letter="$1"
    local quiet="${2:-}"
    local pidfile
    pidfile="$(app_pidfile "${letter}")"
    # Ветка не должна заканчиваться проверкой: при set -e ложное условие
    # последней командой возвращает ненулевой код и обрывает весь скрипт.
    if [[ -f ${pidfile} ]]; then
        kill "$(cat "${pidfile}")" >/dev/null 2>&1 || true
        rm -f "${pidfile}"
        if [[ -z ${quiet} ]]; then
            echo "Бэкенд ${letter} остановлен."
        fi
    elif [[ -z ${quiet} ]]; then
        echo "Бэкенд ${letter} и так не запущен."
    fi
}

# --- стенд ------------------------------------------------------------------

add_node() {
    local ns="$1" host_if="$2" ns_if="$3" addr="$4"
    ip netns add "${ns}"
    ip link add "${host_if}" type veth peer name "${ns_if}"
    ip link set "${host_if}" master "${bridge}"
    ip link set "${host_if}" up
    ip link set "${ns_if}" netns "${ns}"
    ip -n "${ns}" link set "${ns_if}" name eth0
    ip -n "${ns}" link set lo up
    ip -n "${ns}" link set eth0 up
    ip -n "${ns}" addr add "${addr}/24" dev eth0
}

lab_up() {
    if namespace_exists "${ns_client}" || link_exists "${bridge}"; then
        echo "Объекты стенда уже существуют. Сначала: $0 down" >&2
        exit 1
    fi

    mkdir -p "${state_dir}" "${state_dir}/body" "${state_dir}/proxy" \
        "${state_dir}/fastcgi" "${state_dir}/uwsgi" "${state_dir}/scgi"

    ip link add "${bridge}" type bridge
    ip link set "${bridge}" up

    add_node "${ns_client}" dn7-c-host dn7-c-ns "${ip_client}"
    add_node "${ns_proxy}"  dn7-p-host dn7-p-ns "${ip_proxy}"
    add_node "${ns_app_a}"  dn7-a-host dn7-a-ns "${ip_app_a}"
    add_node "${ns_app_b}"  dn7-b-host dn7-b-ns "${ip_app_b}"

    issue_certs
    start_app a
    start_app b

    ip netns exec "${ns_proxy}" nginx -c "${here}/nginx.conf" -p "${state_dir}"
    sleep 0.3

    cat <<EOF
Стенд поднят.

  клиент   ${ip_client}
  прокси   ${ip_proxy}   (TLS для ${cert_name})
  бэкенд a ${ip_app_a}:8080
  бэкенд b ${ip_app_b}:8080

Корневой сертификат стенда: ${tls_dir}/ca.crt
Журнал прокси:              ${state_dir}/access.log
EOF
}

show_status() {
    printf 'Namespace:\n'
    local ns
    for ns in "${ns_client}" "${ns_proxy}" "${ns_app_a}" "${ns_app_b}"; do
        if namespace_exists "${ns}"; then
            printf '  %-12s есть\n' "${ns}"
        else
            printf '  %-12s нет\n' "${ns}"
        fi
    done

    printf '\nБэкенды:\n'
    local letter pidfile
    for letter in a b; do
        pidfile="$(app_pidfile "${letter}")"
        if [[ -f ${pidfile} ]] && kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
            printf '  %s: работает, pid %s\n' "${letter}" "$(cat "${pidfile}")"
        else
            printf '  %s: остановлен\n' "${letter}"
        fi
    done

    printf '\nПрокси:\n'
    if [[ -f ${state_dir}/nginx.pid ]] && kill -0 "$(cat "${state_dir}/nginx.pid")" 2>/dev/null; then
        printf '  nginx работает, pid %s\n' "$(cat "${state_dir}/nginx.pid")"
    else
        printf '  nginx не работает\n'
    fi
}

lab_down() {
    stop_app a quiet
    stop_app b quiet

    if [[ -f ${state_dir}/nginx.pid ]]; then
        ip netns exec "${ns_proxy}" nginx -c "${here}/nginx.conf" -p "${state_dir}" -s quit \
            >/dev/null 2>&1 || kill "$(cat "${state_dir}/nginx.pid")" >/dev/null 2>&1 || true
        sleep 0.3
    fi

    local ns
    for ns in "${ns_client}" "${ns_proxy}" "${ns_app_a}" "${ns_app_b}"; do
        namespace_exists "${ns}" && ip netns delete "${ns}" >/dev/null 2>&1 || true
    done
    local host_if
    for host_if in dn7-c-host dn7-p-host dn7-a-host dn7-b-host; do
        link_exists "${host_if}" && ip link delete "${host_if}" >/dev/null 2>&1 || true
    done
    link_exists "${bridge}" && ip link delete "${bridge}" >/dev/null 2>&1 || true
    check_cleanup

    rm -rf "${state_dir}"
    echo "Объекты стенда удалены, если они существовали."
}

case "${1:-}" in
    check)     require_root; run_check ;;
    up)        require_root; lab_up ;;
    status)    show_status ;;
    stop-app)  require_root; stop_app "${2:-}" ;;
    slow-app)  require_root; start_app "${2:-}" 5; echo "Бэкенд ${2:-} отвечает с задержкой 5 с." ;;
    start-app) require_root; start_app "${2:-}" 0; echo "Бэкенд ${2:-} отвечает как обычно." ;;
    down)      require_root; lab_down ;;
    *)
        sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        ;;
esac
