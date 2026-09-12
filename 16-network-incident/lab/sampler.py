#!/usr/bin/env python3
"""Снимки метрик стенда главы 16 раз в интервал.

Каждая строка — время снимка, ряд и значение:

    2026-09-11T21:00:15Z cilium_drop_count_total{node="dn16-worker",direction="EGRESS",reason="Policy denied"} 42

Значения читаются из настоящих источников: метрик агентов Cilium, счётчиков
ядра через nstat, счётчика правила nftables, /proc/<pid>/net/snmp процессов
приложения, stub_status nginx и числа записей conntrack. Запускается от
root: нужны nsenter и чужие /proc.

    sampler.py --out metrics.txt --interval 15 --stop /tmp/stop
"""

import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import time
import urllib.request

NODES = ["dn16-control-plane", "dn16-worker"]


def sh(*cmd: str) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout


def inspect(name: str, fmt: str) -> str:
    return sh("docker", "inspect", "-f", fmt, name).strip()


def cilium_drops(node: str, ip: str):
    try:
        text = urllib.request.urlopen(f"http://{ip}:9962/metrics", timeout=5).read().decode()
    except OSError:
        return
    for line in text.splitlines():
        m = re.match(r'^cilium_drop_count_total\{(.*)\} (\S+)$', line)
        if m:
            yield f'cilium_drop_count_total{{node="{node}",{m.group(1)}}}', m.group(2)


def nstat(pid: str, names: list[str], label: str):
    out = sh("nsenter", "-t", pid, "-n", "nstat", "-az", *names)
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] in names:
            yield f'netstat_{parts[0]}{{{label}}}', parts[1]


def nft_counter(pid: str):
    out = sh("nsenter", "-t", pid, "-n", "nft", "-j", "list", "table", "inet", "hardening")
    if not out.strip():
        return
    for item in json.loads(out)["nftables"]:
        rule = item.get("rule")
        if not rule:
            continue
        for expr in rule["expr"]:
            if "counter" in expr:
                yield ('nftables_rule_packets_total{host="vpngw",table="inet hardening",'
                       f'chain="{rule["chain"]}",rule="icmp type destination-unreachable drop"}}',
                       str(expr["counter"]["packets"]))


def app_retrans():
    for proc in pathlib.Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            env = dict(x.split("=", 1) for x in (proc / "environ").read_bytes().decode().split("\0") if "=" in x)
            if env.get("ROLE") != "checkout" or "POD_NAME" not in env:
                continue
            snmp = (proc / "net" / "snmp").read_text().splitlines()
        except (OSError, UnicodeDecodeError, ValueError):
            continue
        tcp = [l.split() for l in snmp if l.startswith("Tcp:")]
        values = dict(zip(tcp[0][1:], tcp[1][1:]))
        yield f'netstat_TcpRetransSegs{{pod="{env["POD_NAME"]}"}}', values["RetransSegs"]


def edge_active(pid: str):
    out = sh("nsenter", "-t", pid, "-n", "curl", "-s", "-m", "3", "http://127.0.0.1:8081/status")
    m = re.search(r"Active connections:\s+(\d+)", out)
    if m:
        yield 'nginx_connections_active{host="edge"}', m.group(1)


def conntrack(node: str, pid: str):
    out = sh("nsenter", "-t", pid, "-n", "cat", "/proc/sys/net/netfilter/nf_conntrack_count").strip()
    if out:
        yield f'conntrack_entries{{node="{node}"}}', out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--interval", type=float, default=15)
    parser.add_argument("--stop", required=True)
    args = parser.parse_args()

    nodes = {n: (inspect(n, "{{.NetworkSettings.Networks.kind.IPAddress}}"),
                 inspect(n, "{{.State.Pid}}")) for n in NODES}
    gw = inspect("dn16-vpngw", "{{.State.Pid}}")
    edge = inspect("dn16-edge", "{{.State.Pid}}")

    with open(args.out, "a", buffering=1) as out:
        while not os.path.exists(args.stop):
            started = time.monotonic()
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            series = []
            for node, (ip, pid) in nodes.items():
                series += cilium_drops(node, ip)
                series += conntrack(node, pid)
            series += nstat(gw, ["IpFragFails", "IcmpOutDestUnreachs"], 'host="vpngw"')
            series += nft_counter(gw)
            series += app_retrans()
            series += edge_active(edge)
            for name, value in sorted(series):
                out.write(f"{stamp} {name} {value}\n")
            time.sleep(max(0.0, args.interval - (time.monotonic() - started)))


if __name__ == "__main__":
    main()
