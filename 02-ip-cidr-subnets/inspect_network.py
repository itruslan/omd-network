#!/usr/bin/env python3

import argparse
import ipaddress


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Show network boundaries and test address membership."
    )
    parser.add_argument("cidr", help="IPv4 or IPv6 interface in CIDR notation")
    parser.add_argument("targets", nargs="*",
                        help="addresses to test, or CIDR ranges to compare")
    args = parser.parse_args()

    interface = ipaddress.ip_interface(args.cidr)
    network = interface.network

    print(f"input: {args.cidr}")
    print(f"network: {network}")
    print(f"netmask: {network.netmask}")
    print(f"addresses: {network.num_addresses}")
    print(f"first: {network.network_address}")
    print(f"last: {network[-1]}")
    if network.version == 4:
        print(f"broadcast: {network.broadcast_address}")

    for value in args.targets:
        # Диапазон и одиночный адрес требуют разных отношений: адрес либо
        # входит, либо нет, а две сети могут ещё и пересекаться частично.
        if "/" in value:
            other = ipaddress.ip_network(value, strict=False)
            # Два корректных CIDR одной версии не пересекаются частично: либо
            # они не пересекаются вовсе, либо один целиком внутри другого.
            if other.version != network.version:
                state = "other family"
            elif other.subnet_of(network):
                state = "inside"
            elif other.supernet_of(network):
                state = "contains"
            else:
                state = "disjoint"
            print(f"{other}: {state}")
            continue
        address = ipaddress.ip_address(value)
        state = "inside" if address.version == network.version and address in network else "outside"
        print(f"{address}: {state}")


if __name__ == "__main__":
    main()
