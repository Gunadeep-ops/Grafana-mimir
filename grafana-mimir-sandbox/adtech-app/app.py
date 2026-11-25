"""
Demo ad-tech exporter for the Mimir alerting PoC.

Simulates per-exchange bidding traffic and exposes Prometheus metrics on :8000/metrics.
Each exchange can be switched into a failure mode from the browser (http://localhost:8000)
or with curl, to reproduce the "silent alert" cases.

Modes per exchange:
  normal     healthy traffic
  drop       traffic falls to 10%                          (control: naive rules already catch this)
  idle       series exist but stop increasing (rate = 0)    (control: naive rules already catch this)
  stopped    series are removed entirely                    (naive rules go silent)
  zero_wins  traffic continues, no bids are won             (silent with lazy counters)
  timeout    every request times out, no responses          (latency/win-rate go NaN -> silent)
  slow       latency rises to 150-400 ms                    (control: naive rules already catch this)
"""
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

EXCHANGES = ["exchange_a", "exchange_b", "exchange_c", "exchange_d"]
MODES = ["normal", "drop", "idle", "stopped", "zero_wins", "timeout", "slow"]
BASE_RPS = 50

LOCK = threading.Lock()
STATE = {
    "modes": {ex: "normal" for ex in EXCHANGES},
    "lazy": False,          # True = counters only appear after their first event
    "campaigns": 25,        # campaigns per exchange (impressions_total cardinality)
    "restarted_at": time.time(),
}

BID_REQUESTS = Counter("bid_requests", "Bid requests received", ["exchange"])
BID_RESPONSES = Counter("bid_responses", "Bid responses sent", ["exchange"])
BIDS_WON = Counter("bids_won", "Bids won", ["exchange"])
BID_TIMEOUTS = Counter("bid_timeouts", "Bid requests that timed out", ["exchange"])
BID_LATENCY = Histogram(
    "bid_latency_seconds", "Bid response latency", ["exchange"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1.0],
)
IMPRESSIONS = Counter("impressions", "Impressions served", ["exchange", "campaign_id"])

PER_EXCHANGE = [BID_REQUESTS, BID_RESPONSES, BIDS_WON, BID_TIMEOUTS, BID_LATENCY]


def campaign_ids(n):
    return [f"cmp-{i:04d}" for i in range(n)]


def init_exchange(ex):
    """Create every series for an exchange at 0 (the 'eager initialization' best practice)."""
    for m in PER_EXCHANGE:
        m.labels(ex)
    for c in campaign_ids(STATE["campaigns"]):
        IMPRESSIONS.labels(ex, c)


def remove_exchange(ex):
    for m in PER_EXCHANGE:
        try:
            m.remove(ex)
        except KeyError:
            pass
    for c in campaign_ids(1000):
        try:
            IMPRESSIONS.remove(ex, c)
        except KeyError:
            pass


def restart(lazy):
    """Simulate a pod restart: all counters reset; series are re-created eagerly unless lazy."""
    for m in PER_EXCHANGE + [IMPRESSIONS]:
        m.clear()
    STATE["lazy"] = lazy
    STATE["restarted_at"] = time.time()
    if not lazy:
        for ex in EXCHANGES:
            if STATE["modes"][ex] != "stopped":
                init_exchange(ex)


def tick():
    for ex in EXCHANGES:
        mode = STATE["modes"][ex]
        if mode == "stopped":
            continue
        if mode == "idle":
            continue  # series stay, values stop increasing

        mult = 0.1 if mode == "drop" else 1.0
        requests = int(BASE_RPS * mult * random.uniform(0.9, 1.1))
        if requests <= 0:
            continue
        BID_REQUESTS.labels(ex).inc(requests)

        if mode == "timeout":
            BID_TIMEOUTS.labels(ex).inc(requests)
            continue

        timeouts = int(requests * 0.02)
        if timeouts:
            BID_TIMEOUTS.labels(ex).inc(timeouts)
        responses = int(requests * 0.9)
        BID_RESPONSES.labels(ex).inc(responses)

        if mode != "zero_wins":
            wins = int(responses * 0.15)
            if wins:
                BIDS_WON.labels(ex).inc(wins)
                for c in random.sample(campaign_ids(STATE["campaigns"]), min(wins, STATE["campaigns"])):
                    IMPRESSIONS.labels(ex, c).inc()

        lo, hi = (0.15, 0.4) if mode == "slow" else (0.02, 0.08)
        for _ in range(min(responses, 20)):
            BID_LATENCY.labels(ex).observe(random.uniform(lo, hi))


def loop():
    while True:
        with LOCK:
            tick()
        time.sleep(1)


PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Ad-tech demo exporter</title>
<style>body{{font-family:system-ui,sans-serif;margin:24px}}table{{border-collapse:collapse}}
td,th{{border:1px solid #ccc;padding:6px 10px}}a.btn{{display:inline-block;margin:2px;padding:3px 8px;
border:1px solid #888;border-radius:4px;text-decoration:none;color:#000}}a.on{{background:#2b6;color:#fff}}</style>
</head><body><h2>Ad-tech demo exporter</h2>
<p>Counter initialization: <b>{lazy_label}</b> &nbsp;
<a class="btn" href="/restart?lazy=false">Restart pod (eager init)</a>
<a class="btn" href="/restart?lazy=true">Restart pod (lazy counters)</a></p>
<p>Campaigns per exchange: <b>{campaigns}</b> ({series} impressions series) &nbsp;
<a class="btn" href="/cardinality?n=25">25</a><a class="btn" href="/cardinality?n=100">100</a>
<a class="btn" href="/cardinality?n=250">250</a></p>
<table><tr><th>Exchange</th><th>Mode</th></tr>{rows}</table>
<p><a href="/metrics">/metrics</a> &middot; <a href="/status">/status</a></p></body></html>"""


def render():
    rows = ""
    for ex in EXCHANGES:
        btns = "".join(
            f'<a class="btn{" on" if STATE["modes"][ex] == m else ""}" href="/control?exchange={ex}&mode={m}">{m}</a>'
            for m in MODES
        )
        rows += f"<tr><td>{ex}</td><td>{btns}</td></tr>"
    return PAGE.format(
        lazy_label="lazy (series appear on first event)" if STATE["lazy"] else "eager (all series start at 0)",
        campaigns=STATE["campaigns"],
        series=STATE["campaigns"] * len(EXCHANGES),
        rows=rows,
    )


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _back(self, msg):
        # Browser: go back to the control page. curl: plain-text confirmation.
        if "text/html" in (self.headers.get("Accept") or ""):
            self.send_response(303)
            self.send_header("Location", "/")
            self.end_headers()
        else:
            self._send(200, msg + "\n")

    def log_message(self, fmt, *args):
        if not self.path.startswith("/metrics"):
            super().log_message(fmt, *args)

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        with LOCK:
            if url.path == "/metrics":
                return self._send(200, generate_latest(), CONTENT_TYPE_LATEST)
            if url.path == "/":
                return self._send(200, render(), "text/html; charset=utf-8")
            if url.path == "/status":
                import json
                return self._send(200, json.dumps(STATE, indent=2), "application/json")
            if url.path == "/control":
                ex, mode = q.get("exchange"), q.get("mode")
                if ex not in EXCHANGES or mode not in MODES:
                    return self._send(400, f"exchange must be one of {EXCHANGES}, mode one of {MODES}\n")
                prev = STATE["modes"][ex]
                STATE["modes"][ex] = mode
                if mode == "stopped":
                    remove_exchange(ex)
                elif prev == "stopped" and not STATE["lazy"]:
                    init_exchange(ex)
                return self._back(f"{ex} -> {mode}")
            if url.path == "/restart":
                lazy = q.get("lazy", "false").lower() == "true"
                restart(lazy)
                return self._back(f"restarted, lazy={lazy}")
            if url.path == "/cardinality":
                n = max(1, min(1000, int(q.get("n", "25"))))
                old = STATE["campaigns"]
                STATE["campaigns"] = n
                if n < old:
                    for ex in EXCHANGES:
                        for c in campaign_ids(old)[n:]:
                            try:
                                IMPRESSIONS.remove(ex, c)
                            except KeyError:
                                pass
                elif not STATE["lazy"]:
                    for ex in EXCHANGES:
                        if STATE["modes"][ex] != "stopped":
                            for c in campaign_ids(n):
                                IMPRESSIONS.labels(ex, c)
                return self._back(f"campaigns per exchange = {n}")
        self._send(404, "not found\n")


if __name__ == "__main__":
    restart(lazy=False)
    threading.Thread(target=loop, daemon=True).start()
    print("ad-tech demo exporter on :8000", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
