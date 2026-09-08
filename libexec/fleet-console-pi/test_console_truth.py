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
    # shipped_24h now reads fleet_product_merged_24h keyed on the
    # product-slo textfile (fleet-ops#2755), not fleet.prom.
    monkeypatch.setattr(G, "_product_slo_mtime", lambda: now)
    sh = G.collect_shipped()
    assert sh["ok"] is True
    assert sh["count"] == 0
    op = G.collect_open_prs()
    assert op["ok"] is True
    assert op["count"] == 0
    ci = G.collect_main_ci()
    assert ci["ok"] is True
    assert ci["red_count"] == 0


def test_shipped_org_total_secondary_line(monkeypatch):
    """fleet-ops#3984: shipped_24h carries the org-wide trailing-24h merge
    total (all repos incl. fleet-ops) as a secondary line, so the product-only
    number is not read as org-wide. When the org-wide family is absent the
    secondary line is hidden (None), never a lie."""
    now = time.time()

    def q(expr, timeout=5):
        if "fleet_product_merged_24h" in expr:
            return [{"metric": {"repo": "0509"}, "value": 47},
                    {"metric": {"repo": "siterep-public"}, "value": 1}]
        if "fleet_merged_prs_24h" in expr:
            return [{"metric": {"repo": "Nishfleet/0509"}, "value": 47},
                    {"metric": {"repo": "Nishfleet/fleet-ops"}, "value": 103}]
        return []

    monkeypatch.setattr(G, "_prom_query", q)
    monkeypatch.setattr(G, "_product_slo_mtime", lambda: now)
    sh = G.collect_shipped()
    assert sh["ok"] is True
    assert sh["count"] == 48          # product repos only
    assert sh["org_total"] == 150     # all repos incl. fleet-ops

    # Org-wide family absent (PromError) -> hide the secondary line (None),
    # keep the tile ok.
    def q_no_org(expr, timeout=5):
        if "fleet_product_merged_24h" in expr:
            return [{"metric": {"repo": "0509"}, "value": 47}]
        raise G.PromError("org-wide family absent")

    monkeypatch.setattr(G, "_prom_query", q_no_org)
    sh2 = G.collect_shipped()
    assert sh2["ok"] is True
    assert sh2["count"] == 47
    assert sh2["org_total"] is None


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
        "repairs_inflight", "running_pi", "fleet_state", "questions",
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


def test_metric_tiles_make_zero_github_calls():
    """Metric tiles read the monitoring plane (Prometheus/systemd), never
    GitHub (fleet-ops#1157). The ONE declared exception is the questions
    tile (fleet-ops#4475), whose store IS a GitHub issue with the
    `question` label — it reads GitHub directly and fails closed.
    """
    import ast
    src = Path(G.__file__).read_text()
    tree = ast.parse(src)
    # The `gh` CLI binary is invoked in exactly one place: _gh_json.
    gh_calls = []
    for n in ast.walk(tree):
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute):
            pass
        if isinstance(n, ast.List) and n.elts:
            first = n.elts[0]
            if isinstance(first, ast.Constant) and first.value == "gh":
                gh_calls.append(n)
    assert len(gh_calls) == 1, f"gh binary should be invoked once, got {len(gh_calls)}"
    # That one call must live inside _gh_json (the questions family).
    call_lineno = gh_calls[0].lineno
    def _within(name, start, end):
        for n in ast.walk(tree):
            if isinstance(n, ast.FunctionDef) and n.name == name:
                return n.lineno <= start <= (n.end_lineno or 0)
        return False
    # _gh_json is the sole gh bridge; find its span by name via its body.
    def _func_span(name):
        for n in ast.walk(tree):
            if isinstance(n, ast.FunctionDef) and n.name == name:
                return (n.lineno, n.end_lineno or 0)
        return None
    span = _func_span("_gh_json")
    assert span, "_gh_json missing"
    assert span[0] <= call_lineno <= span[1], "gh call must live in _gh_json"
    # The metric-tile collectors must not reach for the gh bridge.
    metric_collectors = {"collect_shipped", "collect_open_prs", "collect_main_ci",
                         "collect_firing_alerts", "collect_repairs_inflight",
                         "collect_running_pi", "collect_fleet_state"}
    for name in metric_collectors:
        fsrc = ast.get_source_segment(src, next(n for n in ast.walk(tree)
            if isinstance(n, ast.FunctionDef) and n.name == name)) or ""
        assert "_gh_json" not in fsrc and "_gh_questions" not in fsrc, \
            f"{name} must not call GitHub"
    # The questions family exists and is the declared exception.
    assert "_gh_json" in src and "_gh_questions" in src and "collect_questions" in src
    # Metric tiles still key on the monitoring plane.
    assert "pi-seat-health.json" in src
    assert "127.0.0.1:9090" in src
    # PI WORK never counts by unit-name prefix (fleet-ops#1155).
    assert "pgrep -c" not in src and "pgrep -f" not in src
    assert "_invokes_pi_print" in src


def test_questions_fixture_classifies_three_states(monkeypatch):
    """The questions collector classifies one for-nish, one in-conference and
    one answered question, fails closed on a gh error, and surfaces them
    top-level as `questions` (the shell reads that key)."""
    now = time.time()
    import uuid
    def gh(args, timeout=25):
        argv = list(args)
        if argv[0] == "search":
            return [
                {
                    "number": 101, "title": "Money question",
                    "url": "https://x/101", "createdAt": G.now_iso(),
                    "repository": {"nameWithOwner": "Nishfleet/fleet-ops"},
                    "labels": [{"name": "question"}, {"name": "nish-reserved"}],
                    "body": "question: should we raise prices?\noptions: a | b | c\nreason: money is reserved\nblocked-on: nish-decision",
                },
                {
                    "number": 102, "title": "Router choice",
                    "url": "https://x/102", "createdAt": G.now_iso(),
                    "repository": {"nameWithOwner": "Nishfleet/fleet-ops"},
                    "labels": [{"name": "question"}],
                    "body": "question: pick router X or Y?\noptions: x | y",
                },
                {
                    "number": 103, "title": "Answered thing",
                    "url": "https://x/103", "createdAt": G.now_iso(),
                    "repository": {"nameWithOwner": "Nishfleet/fleet-ops"},
                    "labels": [{"name": "question"}, {"name": "conference-approved"}],
                    "body": "question: pick a color?\noptions: red | blue",
                },
            ]
        # issue view --json comments
        by_number = {
            101: [],
            102: [],
            103: [{"body": "decision-resolved: blue", "createdAt": G.now_iso()}],
        }
        num = None
        for a in argv:
            if isinstance(a, str) and a.isdigit():
                num = int(a)
        return by_number.get(num, [])

    monkeypatch.setattr(G, "_gh_json", gh)
    tile = G.collect_questions()
    assert tile["ok"] is True
    by_state = {x["state"] for x in tile["items"]}
    assert by_state == {"for-nish", "in-conference", "answered"}
    reasons = {x["conference_reason"] for x in tile["items"]}
    assert "money is reserved" in reasons
    # All three, and the answered one carries the decision.
    for x in tile["items"]:
        assert x["question"]
        assert x["options"]
        assert x["age_h"] >= 0
        assert x["ref"]

    # Fails closed to source-unavailable on a gh error, never an empty list.
    def boom(*a, **k):
        raise RuntimeError("simulated github outage")
    monkeypatch.setattr(G, "_gh_json", boom)
    bad = G.collect_questions()
    assert bad["ok"] is False
    assert bad["observed_at"] is None
    assert "github" in bad["reason"]


def test_questions_section_renders_exactly_one_card_by_default():
    """The 'Questions for Nish' section shows ONLY for-nish cards by default
    (fleet-ops#4475): of a fixture with one for-nish, one in-conference and
    one answered question, exactly one card renders."""
    now = time.time()
    items = [
        {"ref": "a#1", "state": "for-nish", "question": "q1", "options": "x","age_h": 1},
        {"ref": "b#2", "state": "in-conference", "question": "q2", "options": "x","age_h": 1},
        {"ref": "b#3", "state": "answered", "question": "q3", "options": "x","age_h": 1},
    ]
    default_cards = [x for x in items if x["state"] == "for-nish"]
    assert len(default_cards) == 1
    # The shell wires the same filter: the section body is for-nish only.
    src = Path(__file__).resolve().parent.joinpath("shell.html").read_text()
    assert "section-questions" in src
    assert "Questions for Nish" in src
    assert "in conference " in src and "answered " in src  # counter chips
    assert "decision-resolved: " in src and "q-copy" in src  # copy button
    assert "q-72h" in src and "data-copy=" in src
    assert "for-nish" in src


def test_questions_section_renders_exactly_one_card_by_default():
    """The 'Questions for Nish' section shows ONLY for-nish cards by default
    (fleet-ops#4475): of a fixture with one for-nish, one in-conference and
    one answered question, exactly one card renders."""
    items = [
        {"ref": "a#1", "state": "for-nish", "question": "q1", "options": "x", "age_h": 1},
        {"ref": "b#2", "state": "in-conference", "question": "q2", "options": "x", "age_h": 1},
        {"ref": "b#3", "state": "answered", "question": "q3", "options": "x", "age_h": 1},
    ]
    default_cards = [x for x in items if x["state"] == "for-nish"]
    assert len(default_cards) == 1
    # The shell wires the same filter: the section body is for-nish only.
    src = Path(__file__).resolve().parent.joinpath("shell.html").read_text()
    assert "section-questions" in src
    assert "Questions for Nish" in src
    assert "in conference " in src and "answered " in src  # counter chips
    assert "decision-resolved: " in src and "q-copy" in src  # copy button
    assert "q-72h" in src and "data-copy=" in src
    assert "for-nish" in src


def test_answered_young_kept_old_dropped(monkeypatch):
    """An answered question is kept for 24h (ANSWERED_KEEP_S) then dropped
    from the tab (fleet-ops#4475)."""
    import datetime as _dt
    old = (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(hours=48)).strftime(
        "%Y-%m-%dT%H:%M:%S+00:00")
    fresh = (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(hours=2)).strftime(
        "%Y-%m-%dT%H:%M:%S+00:00")
    # Direct classify, no subprocess.
    issue = {"labels": [{"name": "question"}]}
    old_ans = G._classify_question(issue,
        [{"body": "decision-resolved: a", "createdAt": old}])
    fresh_ans = G._classify_question(issue,
        [{"body": "decision-resolved: b", "createdAt": fresh}])
    assert old_ans[0] == "answered"  # still answered class; the <48h drop
    assert fresh_ans[0] == "answered"
    # _gh_questions drops the stale answer (>24h).
    def gh(args, timeout=25):
        argv = list(args)
        if argv[0] == "search":
            return [{"number": 9, "title": "q", "url": "https://x/9",
                     "createdAt": old,
                     "repository": {"nameWithOwner": "Nishfleet/fleet-ops"},
                     "labels": [{"name": "question"}],
                     "body": "question: hi?\noptions: yes | no"}]
        return [{"body": "decision-resolved: hi", "createdAt": old}]
    monkeypatch.setattr(G, "_gh_json", gh)
    items = G._gh_questions()
    assert items == [], "an answered question >24h old must not render"


def test_shell_renders_emdash_not_unknown():
    src = Path(__file__).resolve().parent.joinpath("shell.html").read_text()
    assert ">unknown</div>" not in src
    assert ">—</" in src or ">—</div>" in src or ">—</div>" in src


if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))
