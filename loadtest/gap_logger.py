"""Measure user-visible downtime during a deploy. Python standard library only.

Sends GET <BASE_URL>/version every 50 ms for DURATION seconds (or until stopped
with Ctrl-C / SIGTERM), logs every request to a CSV, then prints a summary and
writes it as JSON next to the CSV (<csv>.summary.json).

  BASE_URL=http://localhost:8080 DURATION=120 OUT=results/run.csv python3 loadtest/gap_logger.py

CSV columns: timestamp (unix seconds), status (HTTP code, 0 = no answer),
color, version, latency_ms.

"Longest gap" is the longest time between two consecutive successful responses.
With nothing failing it stays close to the 50 ms interval; during an outage it
is roughly the outage length, so it is the downtime figure to report.
"""
import csv
import json
import os
import signal
import time
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

BASE_URL = os.getenv("BASE_URL", "http://localhost:8080").rstrip("/")
DURATION = float(os.getenv("DURATION", "120"))
OUT = os.getenv("OUT", "gap_log.csv")
INTERVAL = 0.05
TIMEOUT = 2.0

stop = False


def request_stop(signum, frame):
    global stop
    stop = True


def probe():
    """Return (status, color, version). status 0 means no HTTP answer at all."""
    try:
        with urlopen(f"{BASE_URL}/version", timeout=TIMEOUT) as resp:
            body = json.loads(resp.read().decode())
            return resp.status, body.get("color", ""), body.get("version", "")
    except HTTPError as exc:
        return exc.code, "", ""
    except (URLError, TimeoutError, OSError, ValueError):
        return 0, "", ""


def summarise(rows):
    ok = [r for r in rows if r[1] == 200]
    gaps = [b[0] - a[0] for a, b in zip(ok, ok[1:])]
    per_color = {}
    for r in ok:
        per_color[r[2]] = per_color.get(r[2], 0) + 1
    switch_at = None
    # First response from a different colour or release. The naive baseline keeps
    # the colour "naive", so the version change is what marks its switch.
    for a, b in zip(ok, ok[1:]):
        if b[2:4] != a[2:4]:
            switch_at = b[0]
            break
    return {
        "total": len(rows),
        "failures": len(rows) - len(ok),
        "longest_gap_ms": round(max(gaps) * 1000, 1) if gaps else None,
        "switch_time": switch_at,
        "switch_time_iso": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(switch_at)) if switch_at else None,
        "served_per_color": per_color,
    }


def main():
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)

    rows = []
    start = time.time()
    next_at = start
    with open(OUT, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["timestamp", "status", "color", "version", "latency_ms"])
        while not stop and time.time() - start < DURATION:
            sent = time.time()
            status, color, version = probe()
            done = time.time()
            row = (done, status, color, version, round((done - sent) * 1000, 1))
            rows.append(row)
            writer.writerow([f"{row[0]:.3f}", *row[1:]])
            # Fixed 50 ms cadence; if a request was slow, carry on without bursting.
            next_at = max(next_at + INTERVAL, time.time())
            time.sleep(max(0.0, next_at - time.time()))

    summary = summarise(rows)
    with open(OUT + ".summary.json", "w") as fh:
        json.dump(summary, fh, indent=2)

    print(f"requests:        {summary['total']}")
    print(f"failures:        {summary['failures']}")
    print(f"longest gap:     {summary['longest_gap_ms']} ms between successful responses")
    print(f"colour switch:   {summary['switch_time_iso'] or 'none'} (first answer from the new colour/release)")
    for color, count in sorted(summary["served_per_color"].items()):
        print(f"served by {color or '?'}: {count}")
    print(f"log: {OUT}")


if __name__ == "__main__":
    main()
