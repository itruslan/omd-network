#!/usr/bin/env bash

set -euo pipefail

client_ns="dn-client"
server_ns="dn-server"
bridge_name="dn-br0"
client_host_if="dn-c-host"
client_ns_if="dn-c-ns"
server_host_if="dn-s-host"
server_ns_if="dn-s-ns"
observer_ns="dn-observer"
observer_host_if="dn-o-host"

check_ns="dn-check-ns"
check_bridge="dn-check-br0"
check_host_if="dn-check-h"
check_ns_if="dn-check-p"
check_failures=0

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        printf 'Run this command with sudo.\n' >&2
        exit 1
    fi
}

require_tools() {
    local tool
    for tool in ip bridge; do
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

cleanup() {
    if namespace_exists "${observer_ns}"; then
        ip netns delete "${observer_ns}" >/dev/null 2>&1 || true
    fi
    if namespace_exists "${client_ns}"; then
        ip netns delete "${client_ns}" >/dev/null 2>&1 || true
    fi
    if namespace_exists "${server_ns}"; then
        ip netns delete "${server_ns}" >/dev/null 2>&1 || true
    fi
    if link_exists "${client_host_if}"; then
        ip link delete "${client_host_if}" >/dev/null 2>&1 || true
    fi
    if link_exists "${server_host_if}"; then
        ip link delete "${server_host_if}" >/dev/null 2>&1 || true
    fi
    if link_exists "${client_ns_if}"; then
        ip link delete "${client_ns_if}" >/dev/null 2>&1 || true
    fi
    if link_exists "${server_ns_if}"; then
        ip link delete "${server_ns_if}" >/dev/null 2>&1 || true
    fi
    if link_exists "${observer_host_if}"; then
        ip link delete "${observer_host_if}" >/dev/null 2>&1 || true
    fi
    if link_exists "${bridge_name}"; then
        ip link delete "${bridge_name}" >/dev/null 2>&1 || true
    fi
}

create_lab() {
    if namespace_exists "${client_ns}" || namespace_exists "${server_ns}" || namespace_exists "${observer_ns}" || \
        link_exists "${bridge_name}" || link_exists "${client_host_if}" || link_exists "${server_host_if}" || \
        link_exists "${client_ns_if}" || link_exists "${server_ns_if}" || link_exists "${observer_host_if}"; then
        printf 'A lab object already exists. Run "%s down" after checking its names.\n' "$0" >&2
        exit 1
    fi

    trap 'trap - ERR; printf "Setup failed; removing partially created lab.\n" >&2; cleanup' ERR

    ip netns add "${client_ns}"
    ip netns add "${server_ns}"
    ip link add "${client_host_if}" type veth peer name "${client_ns_if}"
    ip link add "${server_host_if}" type veth peer name "${server_ns_if}"
    ip link add "${bridge_name}" type bridge

    ip link set "${client_host_if}" master "${bridge_name}"
    ip link set "${server_host_if}" master "${bridge_name}"
    ip link set "${bridge_name}" up
    ip link set "${client_host_if}" up
    ip link set "${server_host_if}" up

    ip link set "${client_ns_if}" netns "${client_ns}"
    ip link set "${server_ns_if}" netns "${server_ns}"
    ip -n "${client_ns}" link set "${client_ns_if}" name eth0
    ip -n "${server_ns}" link set "${server_ns_if}" name eth0
    ip -n "${client_ns}" link set lo up
    ip -n "${server_ns}" link set lo up
    ip -n "${client_ns}" link set eth0 up
    ip -n "${server_ns}" link set eth0 up

    ip -n "${client_ns}" addr add 192.0.2.10/24 dev eth0
    ip -n "${server_ns}" addr add 192.0.2.20/24 dev eth0
    ip -6 -n "${client_ns}" addr add 2001:db8:3::10/64 dev eth0
    ip -6 -n "${server_ns}" addr add 2001:db8:3::20/64 dev eth0

    trap - ERR
    printf 'Lab is ready.\n'
    printf 'Client: 192.0.2.10/24, 2001:db8:3::10/64\n'
    printf 'Server: 192.0.2.20/24, 2001:db8:3::20/64\n'
}

show_status() {
    printf 'Namespaces:\n'
    ip netns list
    printf '\nBridge and host-side links:\n'
    ip -br link show "${bridge_name}" 2>/dev/null || true
    ip -br link show "${client_host_if}" 2>/dev/null || true
    ip -br link show "${server_host_if}" 2>/dev/null || true
    if namespace_exists "${client_ns}"; then
        printf '\nClient addresses:\n'
        ip -n "${client_ns}" -br addr
    fi
    if namespace_exists "${server_ns}"; then
        printf '\nServer addresses:\n'
        ip -n "${server_ns}" -br addr
    fi
}

check_ok() {
    printf '[ ok ]   %s\n' "$1"
}

check_fail() {
    printf '[ FAIL ] %s\n' "$1"
    check_failures=$((check_failures + 1))
}

check_cleanup() {
    if namespace_exists "${check_ns}"; then
        ip netns delete "${check_ns}" >/dev/null 2>&1 || true
    fi
    if link_exists "${check_ns_if}"; then
        ip link delete "${check_ns_if}" >/dev/null 2>&1 || true
    fi
    if link_exists "${check_host_if}"; then
        ip link delete "${check_host_if}" >/dev/null 2>&1 || true
    fi
    if link_exists "${check_bridge}"; then
        ip link delete "${check_bridge}" >/dev/null 2>&1 || true
    fi
}

run_check() {
    local tool
    local bridge_ready=0
    local namespace_ready=0
    local port_ready=0

    if namespace_exists "${check_ns}" || link_exists "${check_bridge}" || \
        link_exists "${check_host_if}" || link_exists "${check_ns_if}"; then
        printf 'A check object already exists. Run "%s down" after checking its names.\n' "$0" >&2
        return 1
    fi

    trap check_cleanup EXIT
    printf 'Checking the environment required by this lab.\n\n'

    for tool in ping tcpdump; do
        if command -v "${tool}" >/dev/null 2>&1; then
            check_ok "command available: ${tool}"
        else
            check_fail "command not found: ${tool}"
        fi
    done

    if ip netns add "${check_ns}" >/dev/null 2>&1; then
        check_ok "network namespace can be created"
        namespace_ready=1
    else
        check_fail "network namespace cannot be created"
    fi

    if ip link add "${check_host_if}" type veth peer name "${check_ns_if}" >/dev/null 2>&1; then
        check_ok "veth pair can be created"
        port_ready=1
    else
        check_fail "veth pair cannot be created"
    fi

    if ip link add "${check_bridge}" type bridge >/dev/null 2>&1; then
        check_ok "bridge can be created"
        bridge_ready=1
    else
        check_fail "bridge cannot be created"
    fi

    # The lab breaks and repairs connectivity with VLAN filtering, so a silent
    # no-op here would make step 4 impossible to interpret. Read the value back
    # instead of trusting the exit status.
    if [[ ${bridge_ready} -eq 1 ]]; then
        ip link set "${check_bridge}" type bridge vlan_filtering 1 >/dev/null 2>&1 || true
        if ip -d link show "${check_bridge}" 2>/dev/null | grep -q 'vlan_filtering 1'; then
            check_ok "bridge VLAN filtering can be enabled"
        else
            check_fail "bridge VLAN filtering is not available (step 4 will not work)"
        fi
    fi

    if [[ ${bridge_ready} -eq 1 && ${port_ready} -eq 1 ]]; then
        ip link set "${check_host_if}" master "${check_bridge}" >/dev/null 2>&1 || true
        bridge vlan add dev "${check_host_if}" vid 10 pvid untagged >/dev/null 2>&1 || true
        if bridge vlan show dev "${check_host_if}" 2>/dev/null | grep -qw '10'; then
            check_ok "a port can be assigned to an access VLAN"
        else
            check_fail "VLAN membership cannot be assigned to a bridge port"
        fi
    fi

    if [[ ${namespace_ready} -eq 1 && ${port_ready} -eq 1 ]]; then
        ip link set "${check_ns_if}" netns "${check_ns}" >/dev/null 2>&1 || true
        ip -n "${check_ns}" link set lo up >/dev/null 2>&1 || true
        ip -n "${check_ns}" link set "${check_ns_if}" up >/dev/null 2>&1 || true
        ip -6 -n "${check_ns}" addr add 2001:db8:3::1/64 dev "${check_ns_if}" >/dev/null 2>&1 || true
        if ip -6 -n "${check_ns}" addr show dev "${check_ns_if}" 2>/dev/null | grep -q '2001:db8:3::1' && \
            ip netns exec "${check_ns}" ping -6 -c 1 ::1 >/dev/null 2>&1; then
            check_ok "IPv6 and ping work inside a namespace"
        else
            check_fail "IPv6 or ping is unavailable inside the namespace (steps 2 and 3 will not work)"
        fi
    fi

    printf '\n'
    if [[ ${check_failures} -gt 0 ]]; then
        printf 'Environment is not ready: %d check(s) failed.\n' "${check_failures}" >&2
        return 1
    fi

    printf 'Environment is ready: all checks passed.\n'
    return 0
}

usage() {
    printf 'Usage: %s {up|check|status|down}\n' "$0" >&2
    exit 2
}

require_tools

case "${1:-}" in
    up)
        require_root
        create_lab
        ;;
    check)
        require_root
        run_check
        ;;
    status)
        show_status
        ;;
    down)
        require_root
        cleanup
        check_cleanup
        printf 'Lab objects were removed if they existed.\n'
        ;;
    *)
        usage
        ;;
esac
