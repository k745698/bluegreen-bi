"""Unit tests for the portal. Run from the repo root: pytest -q"""
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
import app as portal  # noqa: E402

GOOD_URL = "https://app.powerbi.com/reportEmbed?reportId=abc&autoAuth=true"


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(portal, "EMBED_URL", GOOD_URL)
    monkeypatch.setattr(portal, "BREAK_RELEASE", False)
    monkeypatch.setattr(portal, "COLOR", "blue")
    monkeypatch.setattr(portal, "VERSION", "v9")
    monkeypatch.setattr(portal, "REPORT_ID", "")
    monkeypatch.setattr(portal, "REPORT_PAGE", "")
    monkeypatch.setattr(portal, "_cache", {"at": 0.0, "result": None})
    return portal.app.test_client()


@pytest.fixture
def no_network(monkeypatch):
    """Fail the test if anything tries to reach the network."""
    def boom(*args, **kwargs):
        raise AssertionError("unexpected network call")
    monkeypatch.setattr(portal, "urlopen", boom)


class FakeResponse:
    def __init__(self, status):
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_healthz(client):
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_readyz_ok_without_network(client, no_network):
    resp = client.get("/readyz")
    assert resp.status_code == 200
    assert resp.get_json()["ready"] is True


def test_readyz_stays_ready_when_powerbi_is_down(client, monkeypatch):
    monkeypatch.setattr(portal, "check_reachable", lambda url: (False, "unreachable"))
    assert client.get("/readyz").status_code == 200


def test_readyz_break_release(client, no_network, monkeypatch):
    monkeypatch.setattr(portal, "BREAK_RELEASE", True)
    resp = client.get("/readyz")
    assert resp.status_code == 503
    assert "BREAK_RELEASE" in resp.get_json()["checks"]["release"]


@pytest.mark.parametrize("url, reason", [
    ("", "not set"),
    ("http://app.powerbi.com/reportEmbed?reportId=abc", "not https"),
    ("https://example.com/reportEmbed?reportId=abc", "unexpected embed host"),
    ("https://powerbi.com.evil.example/reportEmbed", "unexpected embed host"),
    ("not a url", "not https"),
])
def test_readyz_invalid_embed_url(client, no_network, monkeypatch, url, reason):
    monkeypatch.setattr(portal, "EMBED_URL", url)
    resp = client.get("/readyz")
    assert resp.status_code == 503
    assert reason in resp.get_json()["checks"]["embed_url"]


def test_powerbi_check_reachable(client, monkeypatch):
    monkeypatch.setattr(portal, "urlopen", lambda req, timeout: FakeResponse(200))
    resp = client.get("/powerbi-check")
    assert resp.status_code == 200
    assert resp.get_json()["checks"]["powerbi_reachable"] == "HTTP 200"


def test_powerbi_check_signin_redirect_counts_as_reachable(client, monkeypatch):
    def forbidden(req, timeout):
        raise HTTPError(req.full_url, 403, "Forbidden", {}, None)
    monkeypatch.setattr(portal, "urlopen", forbidden)
    assert client.get("/powerbi-check").status_code == 200


@pytest.mark.parametrize("error", [
    HTTPError(GOOD_URL, 503, "Service Unavailable", {}, None),
    URLError("name resolution failed"),
    TimeoutError("timed out"),
])
def test_powerbi_check_unreachable(client, monkeypatch, error):
    def fail(req, timeout):
        raise error
    monkeypatch.setattr(portal, "urlopen", fail)
    resp = client.get("/powerbi-check")
    assert resp.status_code == 503
    assert resp.get_json()["reachable"] is False


def test_powerbi_check_invalid_url_skips_network(client, no_network, monkeypatch):
    monkeypatch.setattr(portal, "EMBED_URL", "https://example.com/x")
    assert client.get("/powerbi-check").status_code == 503


def test_powerbi_check_is_cached(client, monkeypatch):
    calls = []

    def fake(req, timeout):
        calls.append(req.full_url)
        return FakeResponse(200)
    monkeypatch.setattr(portal, "urlopen", fake)
    client.get("/powerbi-check")
    client.get("/powerbi-check")
    assert len(calls) == 1


def test_version(client):
    resp = client.get("/version")
    assert resp.status_code == 200
    assert resp.get_json() == {"color": "blue", "version": "v9", "report_id": "", "report_page": ""}


def test_report_page_and_id_change_the_embed(client, no_network, monkeypatch):
    monkeypatch.setattr(portal, "REPORT_ID", "xyz")
    monkeypatch.setattr(portal, "REPORT_PAGE", "ReportSection2")
    body = client.get("/version").get_json()
    assert body["report_id"] == "xyz" and body["report_page"] == "ReportSection2"
    url = portal.embed_url()
    assert "reportId=xyz" in url and "pageName=ReportSection2" in url
    assert "autoAuth=true" in url and "reportId=abc" not in url
    page = client.get("/").get_data(as_text=True)
    assert "report xyz / ReportSection2" in page
    assert client.get("/readyz").status_code == 200


def test_index_shows_colour_and_release(client):
    page = client.get("/").get_data(as_text=True)
    assert "BLUE" in page and "release v9" in page and "report " not in page
