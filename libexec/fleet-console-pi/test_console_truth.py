"""Console-truth tests for the Pi console.

Ports the intent of fleet1's console-truth suite (which encoded real incidents):
- a tile whose source is missing/unreadable renders "—", never 0
- a tile whose source is STALE renders "—", never a stale number
- Prometheus down or omitted family -> "—", never a frozen last value
- every tile carries the freshness contract (observed_at, stale_after_s, source)
- the generator path makes zero GitHub API calls
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate as G


def test_unknown_tile_shape():
    t = G._unknown("prometheus:fleet_merged_prs_24h", 900, "metric family absent")
    assert t["ok"] is False
    assert t["observed_at"] is None
    assert t["stale_after_s"] == 900
    assert t["source"] == "prometheus:fleet_merged_prs_24h"
    assert t["reason"] == "metric family absent"
    assert "count" not in t


def test_ok_tile_carries_freshness_contract():
    t = G._tile("prometheus:fleet_merged_prs_24h", 900, True, time.time(),
                count=5, items=[])
    assert t["ok"] is True
    assert t["observed_at"] is not None
    assert t["stale_after_s"] == 900
    assert t["source"] == "prometheus:fleet_merged_prs_24h"
    assert t["count"] == 5


def test_prom_down_makes_tile_unknown(monkeypatch):
    def boom(*args, **kwargs):
        raise G.PromError("simulated prom outage")
    monkeypatch.setattr(G, "_prom_query", boom)
    monkeypatch.setattr(G, "_prom_alerts", boom)
    monkeypatch.setattr(G, "_textfile_mtime", lambda: time.time())
    op = G.collect_open_prs()
    assert op["ok"] is False and op["observed_at"] is None
    assert "count" not in op
    sh = G.collect_shipped()
    assert sh["ok"] is False and sh["observed_at"] is None
    assert "count" not in sh
    ci = G.collect_main_ci()
    assert ci["ok"] is False and ci["observed_at"] is None
    assert "red_count" not in ci
    al = G.collect_firing_alerts()
    assert al["ok"] is False and al["observed_at"] is None
    assert "count" not in al


def test_absent_family_renders_dash_not_zero(monkeypatch):
    """Omitted metric family (stale gh cache) must not coerce to 0."""
    def q(expr, timeout=5):
        return []
    monkeypatch.setattr(G, "_prom_query", q)
    monkeypatch.setattr(G, "_textfile_mtime", lambda: time.time())
    sh = G.collect_shipped()
    assert sh["ok"] is False
    assert "count" not in sh
    assert "absent" in sh["reason"] or "omit" in sh["reason"].lower() or "family" in sh["reason"]
    op = G.collect_open_prs()
    assert op["ok"] is False
    assert "count" not in op
    ci = G.collect_main_ci()
    assert ci["ok"] is False
    assert "red_count" not in ci


def test_zero_is_ok_when_cache_fresh(monkeypatch):
    """A fresh cache with no series is a real zero, not an omitted family."""
    now = time.time()

    def q(expr, timeout=5):
        if "fleet_gh_cache_fresh" in expr and "merged_prs" in expr:
            return [{"metric": {"kind": "merged_prs"}, "value": 1}]
        if "fleet_gh_cache_fresh" in expr and "repo_snapshot" in expr:
            return [{"metric": {"kind": "repo_snapshot"}, "value": 1}]
        return []

    monkeypatch.setattr(G, "_prom_query", q)
    monkeypatch.setattr(G, "_textfile_mtime", lambda: now)
    sh = G.collect_shipped()
    assert sh["ok"] is True
    assert sh["count"] == 0
    op = G.collect_open_prs()
    assert op["ok"] is True
    assert op["count"] == 0
    ci = G.collect_main_ci()
    assert ci["ok"] is True
    assert ci["red_count"] == 0


def test_stale_textfile_hides_number(monkeypatch):
    """Frozen fleet.prom must not display its last scrape as live truth."""
    def q(expr, timeout=5):
        if "fleet_gh_cache_fresh" in expr:
            return [{"metric": {"kind": "merged_prs"}, "value": 1}]
        return [{"metric": {"repo": "Nishfleet/0509"}, "value": 76}]

    monkeypatch.setattr(G, "_prom_query", q)
    monkeypatch.setattr(G, "_textfile_mtime", lambda: time.time() - 99999)
    sh = G.collect_shipped()
    assert sh["ok"] is False
    assert "count" not in sh


def test_generated_doc_has_freshness_contract_on_every_tile():
    doc = G.generate()
    expected = {
        "open_prs", "shipped_24h", "main_ci", "firing_alerts",
        "repairs_inflight", "running_pi", "fleet_state",
    }
    assert expected <= set(doc["tiles"])
    for name, tile in doc["tiles"].items():
        assert "source" in tile, f"{name} missing source"
        assert "stale_after_s" in tile, f"{name} missing stale_after_s"
        assert "observed_at" in tile, f"{name} missing observed_at"
        assert "ok" in tile, f"{name} missing ok"
        assert "explain" in tile, f"{name} missing honesty explain"
        assert "verify" in tile, f"{name} missing verify field"
        assert tile["verify"].get("cmd"), f"{name} verify.cmd empty"
        if tile["ok"]:
            assert tile["observed_at"] is not None, f"{name} ok but observed_at null"
        else:
            assert tile["observed_at"] is None, f"{name} not ok but observed_at set"
            assert "reason" in tile, f"{name} unknown but no reason"
            assert "count" not in tile or tile.get("count") is None


def test_stale_tile_renders_dash_in_shell_logic():
    def freshness(t):
        if not t["ok"] or t["observed_at"] is None:
            return "dash"
        if time.time() - t["observed_at"] > t["stale_after_s"]:
            return "dash"
        return "ok"
    fresh = {"ok": True, "observed_at": time.time(), "stale_after_s": 900}
    stale = {"ok": True, "observed_at": time.time() - 9999, "stale_after_s": 900}
    dead = {"ok": False, "observed_at": None, "stale_after_s": 900}
    assert freshness(fresh) == "ok"
    assert freshness(stale) == "dash"
    assert freshness(dead) == "dash"


def test_generator_makes_zero_github_calls():
    src = Path(G.__file__).read_text()
    assert "/home/nish/fleet2" not in src
    assert "improvement-loop" not in src
    assert '"gh"' not in src and "'gh'" not in src
    assert "github:" not in src
    # Live seat file is required; the rest of lanes/ is not.
    assert "pi-seat-health.json" in src
    assert "127.0.0.1:9090" in src
    # PI WORK never counts by unit-name prefix (fleet-ops#1155).
    assert "pgrep -c" not in src and "pgrep -f" not in src
    assert "_invokes_pi_print" in src


def test_shell_renders_emdash_not_unknown():
    src = Path(__file__).resolve().parent.joinpath("shell.html").read_text()
    assert ">unknown</div>" not in src
    assert ">—</" in src or ">—</div>" in src or ">—</div>" in src


if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))
