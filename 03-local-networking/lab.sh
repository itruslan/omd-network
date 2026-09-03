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
        ip netns delete "${observer_ns}"
    fi
    if namespace_exists "${client_ns}"; then
        ip netns delete "${client_ns}"
    fi
    if namespace_exists "${server_ns}"; then
        ip netns delete "${server_ns}"
    fi
    if link_exists "${client_host_if}"; then
        ip link delete "${client_host_if}"
    fi
    if link_exists "${server_host_if}"; then
        ip link delete "${server_host_if}"
    fi
    if link_exists "${client_ns_if}"; then
        ip link delete "${client_ns_if}"
    fi
    if link_exists "${server_ns_if}"; then
        ip link delete "${server_ns_if}"
    fi
    if link_exists "${observer_host_if}"; then
        ip link delete "${observer_host_if}"
    fi
    if link_exists "${bridge_name}"; then
        ip link delete "${bridge_name}"
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

usage() {
    printf 'Usage: %s {up|status|down}\n' "$0" >&2
    exit 2
}

require_tools

case "${1:-}" in
    up)
        require_root
        create_lab
        ;;
    status)
        show_status
        ;;
    down)
        require_root
        cleanup
        printf 'Lab objects were removed if they existed.\n'
        ;;
    *)
        usage
        ;;
esac
