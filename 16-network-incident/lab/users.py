#!/usr/bin/env python3
"""Нагрузка пользователей магазина для стенда главы 16.

Сорок покупателей с адресами 203.0.113.100–139 открывают каталог, ищут
товары и оформляют заказы через пограничный узел. Результат каждого
обращения пишется строкой JSON: так генератор проверяет, что сценарий
отработал, но студенту этот журнал не выдаётся — у магазина нет журнала
браузеров своих покупателей.

    users.py --edge 203.0.113.10 --duration 1200
"""

import argparse
import datetime
import http.client
import json
import random
import threading
import time
import urllib.parse

SEARCHES = [
    ("кружка", 30), ("плед", 20), ("чайник", 15), ("ваза", 10),
    ("drop table", 12),         # серия мебели Drop: стол и лампа
    ("лампа drop", 8),
]
ATTACK = "1' or 1=1 --"
ATTACKER = "203.0.113.139"
SKUS = [f"SKU-{n:05d}" for n in range(101, 109)]


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def request(edge: str, source: str, method: str, path: str, body: bytes | None = None) -> dict:
    started = time.monotonic()
    conn = http.client.HTTPConnection(edge, 80, timeout=30, source_address=(source, 0))
    headers = {"Host": "shop.example.com", "User-Agent": "Mozilla/5.0 (lab)"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    try:
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        resp.read()
        result = {"status": resp.status, "request_id": resp.getheader("X-Request-Id")}
    except OSError as exc:
        result = {"status": None, "error": str(exc)}
    finally:
        conn.close()
    result.update(time=now(), client=source, method=method, path=path,
                  elapsed_ms=round((time.monotonic() - started) * 1000))
    return result


def one_visit(edge: str, rng: random.Random) -> dict:
    source = f"203.0.113.{rng.randrange(100, 139)}"
    roll = rng.random()
    if roll < 0.45:
        return request(edge, source, "GET", "/catalog")
    if roll < 0.70:
        words, weights = zip(*SEARCHES)
        q = rng.choices(words, weights)[0]
        return request(edge, source, "GET", "/search?" + urllib.parse.urlencode({"q": q}))
    if roll < 0.72:
        return request(edge, ATTACKER, "GET", "/search?" + urllib.parse.urlencode({"q": ATTACK}))
    items = [{"sku": rng.choice(SKUS), "qty": rng.randrange(1, 4),
              "title": "Товар из корзины покупателя, упаковка стандартная"}
             for _ in range(rng.randrange(1, 15))]
    return request(edge, source, "POST", "/api/checkout",
                   json.dumps({"items": items}, ensure_ascii=False).encode())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--edge", required=True)
    parser.add_argument("--duration", type=float, required=True)
    parser.add_argument("--rate", type=float, default=2.0, help="обращений в секунду")
    parser.add_argument("--seed", type=int, default=16)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    lock = threading.Lock()
    deadline = time.monotonic() + args.duration

    def worker(seed: int) -> None:
        result = one_visit(args.edge, random.Random(seed))
        with lock:
            print(json.dumps(result, ensure_ascii=False), flush=True)

    while time.monotonic() < deadline:
        threading.Thread(target=worker, args=(rng.getrandbits(32),), daemon=True).start()
        time.sleep(rng.expovariate(args.rate))
    time.sleep(31)


if __name__ == "__main__":
    main()
