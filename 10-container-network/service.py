#!/usr/bin/env python3
"""Служба на сервере учебного стенда главы 10.

В ответе называет адрес, с которого пришло соединение: по нему видно,
дошёл ли трафик контейнера как есть или был транслирован на хосте.

    service.py --address 0.0.0.0 --port 8080     # доступна из сети
    service.py --address 127.0.0.1 --port 8080   # только внутри сервера
"""

import argparse
import http.server


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - имя задано базовым классом
        body = f"service ok\nclient={self.client_address[0]}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            self.log_message("клиент отключился до ответа")

    def log_message(self, fmt: str, *args) -> None:
        print(f"[service] {self.address_string()} {fmt % args}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Lab service for chapter 10.")
    parser.add_argument("--address", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    server = http.server.ThreadingHTTPServer((args.address, args.port), Handler)
    print(f"service listening on {args.address}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
