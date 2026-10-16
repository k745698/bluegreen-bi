"""BI portal: serves a Power BI secure-embed iframe and exposes health endpoints.

Endpoints
  /               portal page with the embedded Power BI report
  /healthz        liveness: the process is up
  /readyz         readiness: this process is fit to receive traffic (no network call)
  /powerbi-check  dependency gate: Power BI answers the embed URL (used by deploy.sh
                  before cutover, never by a Kubernetes probe)
  /version        which colour/version/report answered (used by the load tests)
"""
import os
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse
from urllib.request import Request, urlopen

from flask import Flask, jsonify, render_template_string

app = Flask(__name__)

COLOR = os.getenv("DEPLOY_COLOR", "local")
VERSION = os.getenv("APP_VERSION", "dev")
EMBED_URL = os.getenv("POWERBI_EMBED_URL", "")
# Optional per-release report selection, so a release can change what is embedded.
# REPORT_ID replaces the reportId in the embed link; REPORT_PAGE sets pageName.
REPORT_ID = os.getenv("REPORT_ID", "")
REPORT_PAGE = os.getenv("REPORT_PAGE", "")
# Simulates a defective release so the failed-Green path can be demonstrated.
BREAK_RELEASE = os.getenv("BREAK_RELEASE", "false").lower() == "true"

CHECK_TTL_SECONDS = 10  # avoid hitting Power BI on every /powerbi-check call
_cache = {"at": 0.0, "result": None}


def embed_url():
    """The embed link with this release's REPORT_ID / REPORT_PAGE applied."""
    if not EMBED_URL or not (REPORT_ID or REPORT_PAGE):
        return EMBED_URL
    parsed = urlparse(EMBED_URL)
    query = dict(parse_qsl(parsed.query, keep_blank_values=True))
    if REPORT_ID:
        query["reportId"] = REPORT_ID
    if REPORT_PAGE:
        query["pageName"] = REPORT_PAGE
    return urlunparse(parsed._replace(query=urlencode(query)))


def validate_embed_url(url):
    """The secure-embed link must be an https Power BI URL."""
    if not url:
        return False, "POWERBI_EMBED_URL is not set"
    parsed = urlparse(url)
    host = parsed.hostname or ""
    if parsed.scheme != "https":
        return False, "embed URL is not https"
    if not (host == "powerbi.com" or host.endswith(".powerbi.com")):
        return False, f"unexpected embed host: {host}"
    return True, "embed URL well-formed"


def check_reachable(url):
    """Power BI answers (often with a sign-in redirect) rather than erroring.

    Anything below HTTP 500 counts as reachable. This does NOT prove the report
    renders for a signed-in user: that needs a browser session.
    """
    req = Request(url, method="GET", headers={"User-Agent": "bi-portal-check/1.0"})
    try:
        with urlopen(req, timeout=5) as resp:
            return resp.status < 500, f"HTTP {resp.status}"
    except HTTPError as exc:
        return exc.code < 500, f"HTTP {exc.code}"
    except (URLError, TimeoutError, OSError) as exc:
        return False, f"unreachable: {exc}"


def run_readiness():
    """Process-level checks only. No network call, so a Power BI outage can never
    make healthy live pods unready and empty the Service."""
    if BREAK_RELEASE:
        return {"ready": False, "checks": {"release": "BREAK_RELEASE set (simulated defect)"}}
    valid, detail = validate_embed_url(embed_url())
    return {"ready": valid, "checks": {"embed_url": detail}}


def run_powerbi_check():
    valid, detail = validate_embed_url(embed_url())
    checks = {"embed_url": detail}
    if not valid:
        return {"reachable": False, "checks": checks}
    reachable, detail = check_reachable(embed_url())
    checks["powerbi_reachable"] = detail
    return {"reachable": reachable, "checks": checks}


PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>BI Portal</title>
  <style>
    html, body { height: 100%; margin: 0; font-family: system-ui, sans-serif; }
    header { padding: 8px 16px; color: #fff; background: {{ bar }}; font-size: 14px; }
    iframe { width: 100%; height: calc(100% - 38px); border: 0; }
  </style>
</head>
<body>
  <header>BI Portal &middot; {{ color }} &middot; release {{ version }}
    {%- if report %} &middot; report {{ report }}{% endif %}</header>
  <iframe title="Power BI report" src="{{ embed_url }}" allowfullscreen="true"></iframe>
</body>
</html>"""


def report_label():
    return " / ".join(part for part in (REPORT_ID, REPORT_PAGE) if part)


@app.get("/")
def index():
    bar = {"blue": "#1f5fbf", "green": "#2a8a4a"}.get(COLOR, "#555555")
    resp = app.make_response(
        render_template_string(
            PAGE, bar=bar, color=COLOR.upper(), version=VERSION,
            report=report_label(), embed_url=embed_url(),
        )
    )
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.get("/healthz")
def healthz():
    return jsonify(status="ok")


@app.get("/readyz")
def readyz():
    result = run_readiness()
    return jsonify(result), (200 if result["ready"] else 503)


@app.get("/powerbi-check")
def powerbi_check():
    now = time.time()
    if _cache["result"] is None or now - _cache["at"] > CHECK_TTL_SECONDS:
        _cache["result"] = run_powerbi_check()
        _cache["at"] = now
    result = _cache["result"]
    return jsonify(result), (200 if result["reachable"] else 503)


@app.get("/version")
def version():
    return jsonify(color=COLOR, version=VERSION, report_id=REPORT_ID, report_page=REPORT_PAGE)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
