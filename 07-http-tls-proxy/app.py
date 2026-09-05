#!/usr/bin/env python3
"""Учебное приложение за обратным прокси.

Отвечает так, чтобы по телу ответа было видно, какой экземпляр ответил:
это и есть способ отличить ответ приложения от ответа посредника.

    app.py --name a --port 8080            # обычный ответ
    app.py --name a --port 8080 --delay 5  # ответ дольше тайм-аута прокси

Выбран Python, а не готовый веб-сервер: он есть в любой Linux-среде курса,
и поведение задаётся явно, без разбора чужой конфигурации.
"""

import argparse
import http.server
import time


def make_handler(name: str, delay: float) -> type:
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:  # noqa: N802 - имя задано базовым классом
            if delay:
                time.sleep(delay)
            # Заголовки запроса показывают, что именно донёс прокси: Host он
            # передаёт по своей настройке, X-Forwarded-For добавляет сам.
            body = (
                f"app={name}\n"
                f"path={self.path}\n"
                f"host={self.headers.get('Host', '-')}\n"
                f"x-forwarded-for={self.headers.get('X-Forwarded-For', '-')}\n"
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-App", name)
            self.end_headers()
            try:
                self.wfile.write(body)
            except BrokenPipeError:
                # Прокси разрывает соединение по своему тайм-ауту раньше, чем
                # медленный ответ готов. Это штатная часть сценария с 504, и
                # трассировка в журнале только сбивала бы с толку.
                self.log_message("клиент отключился до ответа")

        def log_message(self, fmt: str, *args) -> None:
            # Формат журнала фиксирован: студент сверяет его с журналом прокси.
            print(f"[app {name}] {self.address_string()} {fmt % args}", flush=True)

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description="Lab HTTP application.")
    parser.add_argument("--name", required=True, help="instance name shown in body")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--address", default="0.0.0.0")
    parser.add_argument("--delay", type=float, default=0.0,
                        help="seconds to wait before answering")
    args = parser.parse_args()

    server = http.server.ThreadingHTTPServer(
        (args.address, args.port), make_handler(args.name, args.delay))
    print(f"app {args.name} listening on {args.address}:{args.port}, "
          f"delay {args.delay}s", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
