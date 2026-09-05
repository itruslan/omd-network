#!/usr/bin/env python3
"""Учебный слушатель TCP или UDP для практики главы 5.

    listener.py tcp 8080          # принимает соединения и держит их открытыми
    listener.py udp 9090          # принимает датаграммы
    listener.py tcp 8080 --once   # обслуживает одно соединение и выходит

Почему не `nc`: его версии различаются между дистрибутивами вплоть до набора
ключей, а курс обещает студенту воспроизводимый вывод. Здесь используется
только стандартная библиотека Python, одинаковая везде.

Слушатель намеренно ничего не делает с данными. Задача практики — наблюдать
состояния сокетов и обмен на транспортном уровне, а не передавать содержимое.
"""

import argparse
import socket
import sys


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("proto", choices=["tcp", "udp"])
    ap.add_argument("port", type=int)
    ap.add_argument("--host", default="::",
                    help="адрес прослушивания; по умолчанию все интерфейсы")
    ap.add_argument("--once", action="store_true",
                    help="обслужить одно обращение и завершиться")
    opts = ap.parse_args()

    family = socket.AF_INET6 if ":" in opts.host else socket.AF_INET
    kind = socket.SOCK_STREAM if opts.proto == "tcp" else socket.SOCK_DGRAM
    s = socket.socket(family, kind)
    # Без этого повторный запуск на том же порту упрётся в сокет в TIME_WAIT.
    # Практика специально приводит к этому состоянию, поэтому переиспользование
    # адреса здесь не удобство, а условие воспроизводимости шагов.
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        # Двойной стек: один сокет принимает и IPv6, и IPv4. Именно так ведёт
        # себя большинство серверов, и именно это студент увидит в `ss`.
        try:
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass

    try:
        s.bind((opts.host, opts.port))
    except OSError as e:
        print(f"не удалось занять порт {opts.port}: {e}", file=sys.stderr)
        return 1

    if opts.proto == "tcp":
        s.listen(8)
        print(f"слушаю TCP {opts.host}:{opts.port}", flush=True)
        held = []
        while True:
            conn, peer = s.accept()
            print(f"соединение от {peer[0]} порт {peer[1]}", flush=True)
            # Соединение не закрывается: студент должен успеть увидеть его в
            # состоянии ESTABLISHED с обеих сторон.
            held.append(conn)
            if opts.once:
                return 0
    else:
        print(f"слушаю UDP {opts.host}:{opts.port}", flush=True)
        while True:
            data, peer = s.recvfrom(65535)
            print(f"датаграмма {len(data)} байт от {peer[0]} порт {peer[1]}",
                  flush=True)
            if opts.once:
                return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
