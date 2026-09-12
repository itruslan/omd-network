#!/usr/bin/env python3
"""API партнёра по доставке для стенда главы 16.

Принимает POST /v1/shipments и отвечает номером отправления. Каждый принятый
запрос пишется одной строкой JSON: по журналу партнёра видно, какие заказы
до него дошли.
"""

import datetime
import http.server
import json
import uuid


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "partner"
    sys_version = ""

    def do_POST(self) -> None:  # noqa: N802 - имя задано базовым классом
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        order = {}
        if self.path != "/v1/shipments":
            status, data = 404, {"error": "not found"}
        else:
            order = json.loads(body or b"{}")
            status, data = 201, {"shipment_id": "SHP-" + uuid.uuid4().hex[:8].upper(),
                                 "order_id": order.get("order_id")}
        answer = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)
        print(json.dumps({"time": now(), "client": self.client_address[0],
                          "request_id": self.headers.get("X-Request-Id"),
                          "order_id": order.get("order_id"), "shipment_id": data.get("shipment_id"),
                          "path": self.path, "status": status, "bytes": length}), flush=True)

    def log_message(self, fmt: str, *args) -> None:
        pass


def main() -> None:
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
