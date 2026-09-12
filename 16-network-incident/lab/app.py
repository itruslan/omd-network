#!/usr/bin/env python3
"""Приложение магазина для стенда главы 16.

Одна программа в трёх ролях, роль задаёт переменная ROLE:

    storefront       GET /catalog, GET /search?q=...
    checkout         POST /api/checkout — передаёт заказ в API партнёра
    recommendations  фоновая выгрузка в систему аналитики

Каждый запрос пишется одной строкой JSON в стандартный вывод и в файл
LOG_DIR/<имя Pod>.log. Файл лежит на узле и переживает удаление Pod —
журнал удалённой версии иначе пропал бы вместе с ней.
"""

import datetime
import http.client
import http.server
import json
import os
import pathlib
import socket
import threading
import time
import urllib.parse
import uuid

ROLE = os.environ.get("ROLE", "storefront")
VERSION = os.environ.get("VERSION", "v1")
POD = os.environ.get("POD_NAME", socket.gethostname())
PARTNER_HOST, PARTNER_PORT = os.environ.get("PARTNER", "198.51.100.10:8080").split(":")
ANALYTICS = os.environ.get("ANALYTICS", "203.0.113.99:443")
LOG_DIR = pathlib.Path(os.environ.get("LOG_DIR", "/var/log/shop"))

# Тайм-ауты обращения к партнёру: на установление соединения и на ответ.
CONNECT_TIMEOUT = 2.0
READ_TIMEOUT = 2.5
# Версия v2 повторяет обращение, если соединение не установилось.
CONNECT_ATTEMPTS = 2 if VERSION == "v2" else 1

CATALOG = [
    {"sku": f"SKU-{n:05d}", "name": name, "price": price}
    for n, (name, price) in enumerate([
        ("Кружка керамическая 350 мл", 490),
        ("Лампа настольная Drop", 3990),
        ("Стол обеденный Drop Table", 18900),
        ("Чайник заварочный 600 мл", 1290),
        ("Набор ложек, 6 шт.", 790),
        ("Плед шерстяной 140×200", 4590),
        ("Подушка декоративная", 1190),
        ("Ваза стеклянная", 1490),
    ], start=101)
]

_log_lock = threading.Lock()
LOG_DIR.mkdir(parents=True, exist_ok=True)
_log_file = open(LOG_DIR / f"{POD}.log", "a", buffering=1, encoding="utf-8")


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def log(**fields) -> None:
    line = json.dumps({"time": now(), "pod": POD, "version": VERSION, **fields}, ensure_ascii=False)
    with _log_lock:
        print(line, flush=True)
        _log_file.write(line + "\n")


class PartnerError(Exception):
    """Ошибка обращения к партнёру. Фаза названа явно: по тексту сообщения её
    определять нельзя — «connect» встречается и в ошибках после установления
    соединения, и повтор тогда отправит заказ дважды."""

    def __init__(self, status: int, message: str, phase: str):
        super().__init__(message)
        self.status = status
        self.phase = phase


def call_partner(body: bytes, request_id: str) -> dict:
    """Одно обращение к API партнёра. Фазы разделены, чтобы журнал называл,
    на чём именно истекло время: на установлении соединения или на ответе."""
    try:
        sock = socket.create_connection((PARTNER_HOST, int(PARTNER_PORT)), timeout=CONNECT_TIMEOUT)
    except TimeoutError:
        raise PartnerError(502, "partner connect timeout", "connect")
    except OSError as exc:
        raise PartnerError(502, f"partner connect error: {exc.strerror or exc}", "connect")
    sock.settimeout(READ_TIMEOUT)
    conn = http.client.HTTPConnection(PARTNER_HOST, int(PARTNER_PORT))
    conn.sock = sock
    try:
        conn.request("POST", "/v1/shipments", body=body, headers={
            "Content-Type": "application/json",
            "X-Request-Id": request_id,
        })
        resp = conn.getresponse()
        payload = resp.read()
    except TimeoutError:
        raise PartnerError(504, "partner read timeout", "response")
    except OSError as exc:
        raise PartnerError(502, f"partner connection error: {exc.strerror or exc}", "response")
    finally:
        conn.close()
    if resp.status >= 300:
        raise PartnerError(502, f"partner status {resp.status}", "response")
    return json.loads(payload)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "shop"
    sys_version = ""

    def reply(self, status: int, data: dict, cache: str = "no-store") -> None:
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        self.wfile.write(body)

    def request_id(self) -> str:
        return self.headers.get("X-Request-Id") or uuid.uuid4().hex

    def do_GET(self) -> None:  # noqa: N802 - имя задано базовым классом
        url = urllib.parse.urlsplit(self.path)
        if url.path == "/healthz":
            return self.reply(200, {"status": "ok"})
        if ROLE != "storefront":
            return self.reply(404, {"error": "not found"})
        started = time.monotonic()
        rid = self.request_id()
        if url.path == "/catalog":
            status, cache = 200, "public, max-age=30"
            self.reply(status, {"items": CATALOG}, cache)
        elif url.path == "/search":
            q = urllib.parse.parse_qs(url.query).get("q", [""])[0].lower()
            found = [p for p in CATALOG if any(w in p["name"].lower() for w in q.split())]
            status = 200
            self.reply(status, {"query": q, "items": found})
        else:
            status = 404
            self.reply(status, {"error": "not found"})
        log(request_id=rid, method="GET", path=url.path, status=status,
            duration_ms=round((time.monotonic() - started) * 1000),
            client=self.headers.get("X-Forwarded-For", self.client_address[0]))

    def do_POST(self) -> None:  # noqa: N802
        if ROLE != "checkout" or self.path != "/api/checkout":
            return self.reply(404, {"error": "not found"})
        started = time.monotonic()
        rid = self.request_id()
        cart = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        items = cart.get("items", [])
        order_id = "ORD-" + uuid.uuid4().hex[:10].upper()
        shipment = json.dumps({"order_id": order_id, "items": items}, ensure_ascii=False).encode()
        status, error, attempts = 201, None, 0
        for attempts in range(1, CONNECT_ATTEMPTS + 1):
            try:
                answer = call_partner(shipment, rid)
                status, error = 201, None
                break
            except PartnerError as exc:
                status, error = exc.status, str(exc)
                # Повторяем только неустановленное соединение: заказ,
                # который партнёр мог уже принять, отправлять второй раз нельзя.
                if exc.phase != "connect":
                    break
        if error:
            self.reply(status, {"error": error, "request_id": rid})
        else:
            self.reply(status, {"order_id": order_id, "shipment_id": answer.get("shipment_id")})
        log(request_id=rid, method="POST", path=self.path, status=status,
            duration_ms=round((time.monotonic() - started) * 1000), order_id=order_id,
            items=len(items), partner_request_bytes=len(shipment), attempts=attempts,
            error=error, client=self.headers.get("X-Forwarded-For", self.client_address[0]))

    def log_message(self, fmt: str, *args) -> None:
        pass


def analytics_loop() -> None:
    """Выгрузка в аналитику раз в 20 секунд. Отправлять ей нечего: важна
    попытка соединения, которая оставляет след в телеметрии."""
    host, port = ANALYTICS.split(":")
    while True:
        started = time.monotonic()
        try:
            socket.create_connection((host, int(port)), timeout=3.0).close()
            result = None
        except OSError as exc:
            result = "timeout" if isinstance(exc, TimeoutError) else (exc.strerror or str(exc))
        if result:
            log(event="analytics export failed", target=ANALYTICS, error=result,
                duration_ms=round((time.monotonic() - started) * 1000))
        time.sleep(20)


def main() -> None:
    if ROLE == "recommendations":
        threading.Thread(target=analytics_loop, daemon=True).start()
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    log(event="started", role=ROLE)
    server.serve_forever()


if __name__ == "__main__":
    main()
