#!/usr/bin/env python3
"""Упрощённая сводка захвата с колонками AWS VPC Flow Logs версии 2.

Облака на стенде нет, поэтому журнал потоков не снят, а получен из
настоящего захвата на интерфейсе шлюза: одна запись на пятёрку «адреса,
порты, протокол» в одном направлении за интервал сведения в 60 секунд.
`start` и `end` — время первого и последнего пакета потока внутри интервала.
Решение фильтров облака на стенде принимать некому, поэтому `action` у всех
записей ACCEPT.

Это не воспроизведение семантики AWS, а сводка в тех же колонках. Главное
отличие: `srcaddr` и `dstaddr` здесь всегда берутся из пакета, тогда как
в AWS для входящего на интерфейс трафика в соответствующем поле стоит адрес
самого интерфейса, а адреса пакета выносятся в поля `pkt-srcaddr` и
`pkt-dstaddr`.

    flowlog.py vpngw-inside.pcap > flowlog-vpngw.txt
"""

import argparse
import collections
import ipaddress
import struct
import sys

ACCOUNT = "123456789010"
INTERFACE = "eni-0f16a7c3e2b1d4a59"
WINDOW = 60


def packets(path: str):
    with open(path, "rb") as f:
        header = f.read(24)
        magic = struct.unpack("<I", header[:4])[0]
        if magic in (0xA1B2C3D4, 0xA1B23C4D):
            endian = "<"
        elif magic in (0xD4C3B2A1, 0x4D3CB2A1):
            endian = ">"
            magic = struct.unpack(">I", header[:4])[0]
        else:
            raise SystemExit(f"{path}: не pcap")
        scale = 1e-9 if magic == 0xA1B23C4D else 1e-6
        linktype = struct.unpack(endian + "I", header[20:24])[0]
        while True:
            rec = f.read(16)
            if len(rec) < 16:
                return
            sec, frac, incl, _orig = struct.unpack(endian + "IIII", rec)
            data = f.read(incl)
            if linktype == 1:            # Ethernet
                if data[12:14] != b"\x08\x00":
                    continue
                ip = data[14:]
            elif linktype == 113:        # Linux cooked capture
                if data[14:16] != b"\x08\x00":
                    continue
                ip = data[16:]
            else:
                raise SystemExit(f"{path}: тип канала {linktype} не поддержан")
            yield sec + frac * scale, ip


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pcap")
    args = parser.parse_args()

    flows = collections.OrderedDict()
    for ts, ip in packets(args.pcap):
        if len(ip) < 20 or ip[0] >> 4 != 4:
            continue
        ihl = (ip[0] & 0x0F) * 4
        total = struct.unpack("!H", ip[2:4])[0]
        proto = ip[9]
        src = str(ipaddress.IPv4Address(ip[12:16]))
        dst = str(ipaddress.IPv4Address(ip[16:20]))
        sport = dport = 0
        if proto in (6, 17) and len(ip) >= ihl + 4:
            sport, dport = struct.unpack("!HH", ip[ihl:ihl + 4])
        window = int(ts // WINDOW) * WINDOW
        key = (window, src, dst, sport, dport, proto)
        flow = flows.get(key)
        if flow is None:
            flows[key] = flow = {"packets": 0, "bytes": 0, "start": int(ts), "end": int(ts)}
        flow["packets"] += 1
        flow["bytes"] += total
        flow["end"] = int(ts)

    out = sys.stdout
    out.write("# Сводка из захвата на интерфейсе шлюза: колонки формата AWS VPC Flow\n"
              "# Logs версии 2, интервал сведения 60 секунд. Адреса и порты взяты из\n"
              "# пакетов; настоящим журналом облачной платформы файл не является.\n")
    out.write("version account-id interface-id srcaddr dstaddr srcport dstport "
              "protocol packets bytes start end action log-status\n")
    for (window, src, dst, sport, dport, proto), flow in sorted(
            flows.items(), key=lambda kv: (kv[0][0], kv[1]["start"])):
        out.write(f"2 {ACCOUNT} {INTERFACE} {src} {dst} {sport} {dport} {proto} "
                  f"{flow['packets']} {flow['bytes']} {flow['start']} {flow['end']} ACCEPT OK\n")


if __name__ == "__main__":
    main()
