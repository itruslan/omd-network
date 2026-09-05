#!/usr/bin/env bash

set -euo pipefail

# Objects use the "dn4-" prefix rather than the "dn-" of chapter 3. The labs are
# torn down independently, and a leftover chapter 3 bench must not collide with
# this one: a name clash would abort setup for a reason the student cannot see.
client_ns="dn4-client"
router_ns="dn4-router"
server_ns="dn4-server"
client_rt_if="dn4-c-rt"
client_ns_if="dn4-c-ns"
server_rt_if="dn4-s-rt"
server_ns_if="dn4-s-ns"

client_net4="198.51.100.0/24"
client_addr4="198.51.100.10/24"
router_left4="198.51.100.1/24"
server_net4="203.0.113.0/24"
server_addr4="203.0.113.20/24"
router_right4="203.0.113.1/24"

client_addr6="2001:db8:4:1::10/64"
router_left6="2001:db8:4:1::1/64"
server_addr6="2001:db8:4:2::20/64"
router_right6="2001:db8:4:2::1/64"

# 1400 is below the 1500 of a normal Ethernet link but above the 1280 IPv6
# minimum, so the same value demonstrates Path MTU for both address families.
narrow_mtu=1400

check_ns="dn4-check-ns"
check_peer_ns="dn4-check-peer"
check_a_if="dn4-check-a"
check_b_if="dn4-check-b"
check_failures=0

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        printf 'Run this command with sudo.\n' >&2
        exit 1
    fi
}

require_tools() {
    local tool
    for tool in ip ping; do
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

check_ok() {
    printf '[ ok ]   %s\n' "$1"
}

check_fail() {
    printf '[ FAIL ] %s\n' "$1" >&2
    check_failures=$((check_failures + 1))
}

cleanup() {
    local ns if_name
    for ns in "${client_ns}" "${router_ns}" "${server_ns}"; do
        if namespace_exists "${ns}"; then
            ip netns delete "${ns}" >/dev/null 2>&1 || true
        fi
    done
    # A veth end that stayed in the root namespace outlives its peer, so the
    # links are removed explicitly rather than assumed gone with the namespace.
    for if_name in "${client_rt_if}" "${client_ns_if}" "${server_rt_if}" "${server_ns_if}"; do
        if link_exists "${if_name}"; then
            ip link delete "${if_name}" >/dev/null 2>&1 || true
        fi
    done
}

create_lab() {
    local ns if_name
    for ns in "${client_ns}" "${router_ns}" "${server_ns}"; do
        if namespace_exists "${ns}"; then
            printf 'A lab object already exists: %s. Run "%s down" after checking its name.\n' \
                "${ns}" "$0" >&2
            exit 1
        fi
    done
    for if_name in "${client_rt_if}" "${client_ns_if}" "${server_rt_if}" "${server_ns_if}"; do
        if link_exists "${if_name}"; then
            printf 'A lab object already exists: %s. Run "%s down" after checking its name.\n' \
                "${if_name}" "$0" >&2
            exit 1
        fi
    done

    trap 'trap - ERR; printf "Setup failed; removing partially created lab.\n" >&2; cleanup' ERR

    ip netns add "${client_ns}"
    ip netns add "${router_ns}"
    ip netns add "${server_ns}"

    ip link add "${client_ns_if}" type veth peer name "${client_rt_if}"
    ip link add "${server_ns_if}" type veth peer name "${server_rt_if}"

    ip link set "${client_ns_if}" netns "${client_ns}"
    ip link set "${client_rt_if}" netns "${router_ns}"
    ip link set "${server_ns_if}" netns "${server_ns}"
    ip link set "${server_rt_if}" netns "${router_ns}"

    for ns in "${client_ns}" "${router_ns}" "${server_ns}"; do
        ip -n "${ns}" link set lo up
    done

    ip -n "${client_ns}" addr add "${client_addr4}" dev "${client_ns_if}"
    ip -n "${client_ns}" -6 addr add "${client_addr6}" dev "${client_ns_if}" nodad
    ip -n "${client_ns}" link set "${client_ns_if}" up

    ip -n "${router_ns}" addr add "${router_left4}" dev "${client_rt_if}"
    ip -n "${router_ns}" -6 addr add "${router_left6}" dev "${client_rt_if}" nodad
    ip -n "${router_ns}" link set "${client_rt_if}" up

    ip -n "${router_ns}" addr add "${router_right4}" dev "${server_rt_if}"
    ip -n "${router_ns}" -6 addr add "${router_right6}" dev "${server_rt_if}" nodad
    ip -n "${router_ns}" link set "${server_rt_if}" up

    ip -n "${server_ns}" addr add "${server_addr4}" dev "${server_ns_if}"
    ip -n "${server_ns}" -6 addr add "${server_addr6}" dev "${server_ns_if}" nodad
    ip -n "${server_ns}" link set "${server_ns_if}" up

    # Forwarding is enabled inside the router namespace only. The host setting
    # is left alone: a lab must not change the machine it runs on.
    ip netns exec "${router_ns}" sysctl -q -w net.ipv4.ip_forward=1
    ip netns exec "${router_ns}" sysctl -q -w net.ipv6.conf.all.forwarding=1

    ip -n "${client_ns}" route add default via "${router_left4%/*}"
    ip -n "${client_ns}" -6 route add default via "${router_left6%/*}"
    ip -n "${server_ns}" route add default via "${router_right4%/*}"
    ip -n "${server_ns}" -6 route add default via "${router_right6%/*}"

    trap - ERR

    printf 'Lab is up.\n\n'
    printf '  %-14s %s\n' "${client_ns}" "${client_addr4%/*} / ${client_addr6%/*}"
    printf '  %-14s %s\n' "${router_ns}" "${router_left4%/*} + ${router_right4%/*} (forwarding on)"
    printf '  %-14s %s\n' "${server_ns}" "${server_addr4%/*} / ${server_addr6%/*}"
    printf '\nStart with: ip -n %s route show\n' "${client_ns}"
}

narrow_link() {
    if ! namespace_exists "${router_ns}"; then
        printf 'Lab is not up. Run "%s up" first.\n' "$0" >&2
        exit 1
    fi
    ip -n "${router_ns}" link set "${server_rt_if}" mtu "${narrow_mtu}"
    ip -n "${server_ns}" link set "${server_ns_if}" mtu "${narrow_mtu}"
    printf 'MTU of the router-server link is now %s bytes.\n' "${narrow_mtu}"
    printf 'The client still sees %s on its own link: that difference is the point.\n' 1500
}

widen_link() {
    if ! namespace_exists "${router_ns}"; then
        printf 'Lab is not up. Run "%s up" first.\n' "$0" >&2
        exit 1
    fi
    ip -n "${router_ns}" link set "${server_rt_if}" mtu 1500
    ip -n "${server_ns}" link set "${server_ns_if}" mtu 1500
    # A learned Path MTU is cached as a route exception and outlives the change
    # that caused it, so the cache is flushed to make the repair observable.
    ip -n "${client_ns}" route flush cache 2>/dev/null || true
    printf 'MTU is back to 1500 and the client route cache was flushed.\n'
}

break_forwarding() {
    if ! namespace_exists "${router_ns}"; then
        printf 'Lab is not up. Run "%s up" first.\n' "$0" >&2
        exit 1
    fi
    ip netns exec "${router_ns}" sysctl -q -w net.ipv4.ip_forward=0
    ip netns exec "${router_ns}" sysctl -q -w net.ipv6.conf.all.forwarding=0
    printf 'Forwarding is disabled on the router.\n'
    printf 'Predict the symptom before you test it, then compare.\n'
}

repair_forwarding() {
    if ! namespace_exists "${router_ns}"; then
        printf 'Lab is not up. Run "%s up" first.\n' "$0" >&2
        exit 1
    fi
    ip netns exec "${router_ns}" sysctl -q -w net.ipv4.ip_forward=1
    ip netns exec "${router_ns}" sysctl -q -w net.ipv6.conf.all.forwarding=1
    printf 'Forwarding is enabled again.\n'
}

show_status() {
    local ns
    for ns in "${client_ns}" "${router_ns}" "${server_ns}"; do
        if namespace_exists "${ns}"; then
            printf '=== %s ===\n' "${ns}"
            ip -n "${ns}" -brief addr show
            printf -- '--- IPv4 routes ---\n'
            ip -n "${ns}" route show
            printf -- '--- IPv6 routes ---\n'
            ip -n "${ns}" -6 route show
            printf '\n'
        else
            printf '=== %s: does not exist ===\n\n' "${ns}"
        fi
    done
    if namespace_exists "${router_ns}"; then
        printf 'Router forwarding: IPv4=%s IPv6=%s\n' \
            "$(ip netns exec "${router_ns}" sysctl -n net.ipv4.ip_forward)" \
            "$(ip netns exec "${router_ns}" sysctl -n net.ipv6.conf.all.forwarding)"
    fi
}

check_cleanup() {
    local ns if_name
    for ns in "${check_ns}" "${check_peer_ns}"; do
        if namespace_exists "${ns}"; then
            ip netns delete "${ns}" >/dev/null 2>&1 || true
        fi
    done
    for if_name in "${check_a_if}" "${check_b_if}"; do
        if link_exists "${if_name}"; then
            ip link delete "${if_name}" >/dev/null 2>&1 || true
        fi
    done
}

run_check() {
    local tool
    local pair_ready=0

    if namespace_exists "${check_ns}" || namespace_exists "${check_peer_ns}" || \
        link_exists "${check_a_if}" || link_exists "${check_b_if}"; then
        printf 'A check object already exists. Run "%s down" after checking its names.\n' "$0" >&2
        return 1
    fi

    trap check_cleanup EXIT
    printf 'Checking the environment required by this lab.\n\n'

    for tool in ping tracepath; do
        if command -v "${tool}" >/dev/null 2>&1; then
            check_ok "command available: ${tool}"
        else
            check_fail "command not found: ${tool}"
        fi
    done
    for tool in traceroute tcpdump; do
        if command -v "${tool}" >/dev/null 2>&1; then
            check_ok "command available: ${tool}"
        else
            printf '[ note ] optional command not found: %s\n' "${tool}"
        fi
    done

    if ip netns add "${check_ns}" >/dev/null 2>&1 && \
        ip netns add "${check_peer_ns}" >/dev/null 2>&1; then
        check_ok "network namespaces can be created"
    else
        check_fail "network namespace cannot be created"
    fi

    if ip link add "${check_a_if}" type veth peer name "${check_b_if}" >/dev/null 2>&1; then
        check_ok "veth pair can be created"
        pair_ready=1
    else
        check_fail "veth pair cannot be created"
    fi

    # The lab turns forwarding on inside a namespace. If the sandbox blocks
    # writes to that sysctl, every routing step silently does nothing.
    if ip netns exec "${check_ns}" sysctl -q -w net.ipv4.ip_forward=1 >/dev/null 2>&1 && \
        [[ $(ip netns exec "${check_ns}" sysctl -n net.ipv4.ip_forward 2>/dev/null) == "1" ]]; then
        check_ok "IPv4 forwarding can be enabled inside a namespace"
    else
        check_fail "IPv4 forwarding cannot be enabled (routing steps will not work)"
    fi

    if ip netns exec "${check_ns}" sysctl -q -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 && \
        [[ $(ip netns exec "${check_ns}" sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null) == "1" ]]; then
        check_ok "IPv6 forwarding can be enabled inside a namespace"
    else
        check_fail "IPv6 forwarding cannot be enabled (IPv6 routing steps will not work)"
    fi

    # Step 4 lowers the MTU of a link. Reading the value back matters: a kernel
    # may accept the command and keep the old value.
    if [[ ${pair_ready} -eq 1 ]]; then
        ip link set "${check_a_if}" mtu "${narrow_mtu}" >/dev/null 2>&1 || true
        if ip link show dev "${check_a_if}" 2>/dev/null | grep -q "mtu ${narrow_mtu}"; then
            check_ok "link MTU can be lowered (Path MTU step will work)"
        else
            check_fail "link MTU cannot be changed (step 4 will not work)"
        fi
    fi

    if [[ ${pair_ready} -eq 1 ]]; then
        ip link set "${check_b_if}" netns "${check_ns}" >/dev/null 2>&1 || true
        ip -n "${check_ns}" link set lo up >/dev/null 2>&1 || true
        ip -n "${check_ns}" -6 addr add 2001:db8:4:9::1/64 dev "${check_b_if}" nodad >/dev/null 2>&1 || true
        if ip -n "${check_ns}" -6 addr show dev "${check_b_if}" 2>/dev/null | grep -q '2001:db8:4:9::1' && \
            ip netns exec "${check_ns}" ping -6 -c 1 ::1 >/dev/null 2>&1; then
            check_ok "IPv6 and ping work inside a namespace"
        else
            check_fail "IPv6 or ping is unavailable inside the namespace"
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
    printf 'Usage: %s {up|check|status|narrow|widen|break|repair|down}\n' "$0" >&2
    printf '\n'
    printf '  up      create the three-namespace bench\n' >&2
    printf '  check   verify the environment before creating anything\n' >&2
    printf '  status  show addresses, routes and forwarding state\n' >&2
    printf '  narrow  lower the router-server MTU to %s bytes\n' "${narrow_mtu}" >&2
    printf '  widen   restore MTU 1500 and flush the client route cache\n' >&2
    printf '  break   disable forwarding on the router\n' >&2
    printf '  repair  enable forwarding on the router\n' >&2
    printf '  down    remove every object this script creates\n' >&2
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
    narrow)
        require_root
        narrow_link
        ;;
    widen)
        require_root
        widen_link
        ;;
    break)
        require_root
        break_forwarding
        ;;
    repair)
        require_root
        repair_forwarding
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
