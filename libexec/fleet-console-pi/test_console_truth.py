"""Console-truth tests for the Pi console.

Ports the intent of fleet1's console-truth suite (which encoded real incidents):
- a tile whose source is missing/unreadable renders "—", never 0
- a tile whose source is STALE renders "—", never a stale number
- Prometheus down or omitted family -> "—", never a frozen last value
- every tile carries the freshness contract (observed_at, stale_after_s, source)
- the generator path makes zero GitHub API calls
"""
import json
import subprocess
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
        "outcome",
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
                         "collect_running_pi", "collect_fleet_state",
                         "collect_outcome", "collect_findings"}
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


def test_absent_outcome_gauge_renders_dash_not_zero(monkeypatch):
    """fleet-ops#5003 accept bullet 2: an absent outcome gauge is UNKNOWN (the
    shell draws a dash), never a coerced 0. The four gauges are OMITTED by the
    exporter when the 0509 D1 source is unreadable, while a healthy empty table
    exports an explicit 0 — so "0 signups" and "signups not measured" must
    never look the same on the console."""
    now = time.time()
    monkeypatch.setattr(G, "_prom_or_stale",
                        lambda src, explain: (now, None))
    monkeypatch.setattr(G, "_product_slo_mtime", lambda: now)

    def absent(expr, timeout=5):
        return []

    monkeypatch.setattr(G, "_prom_query", absent)
    t = G.collect_outcome()
    assert t["ok"] is False
    assert t["observed_at"] is None
    assert "fleet_product_signups_24h" in t["reason"], t["reason"]
    assert "absent" in t["reason"], t["reason"]
    assert "count" not in t and "signups_24h" not in t

    # The inverse leg: an explicit 0 IS a measurement. Without this the test
    # would also pass if the collector returned unknown unconditionally.
    def explicit_zero(expr, timeout=5):
        return [{"metric": {}, "value": 0}]

    monkeypatch.setattr(G, "_prom_query", explicit_zero)
    z = G.collect_outcome()
    assert z["ok"] is True
    assert z["count"] == 0
    assert z["signups_24h"] == 0 and z["signups_7d"] == 0
    assert z["activated_24h"] == 0 and z["paying_customers"] == 0
    assert z["observed_at"] == now
    assert "UNMEASURED" in z["funnel"]


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
    one answered question, exactly one card renders. The console is read-only:
    no copy button, no write path; each card carries the Q:<repo>#<n> handle
    and the 'answer by telling Claude or Hermes' line."""
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
    assert "q-72h" in src
    assert "for-nish" in src
    # The section renders the Q:<repo>#<n> handle and the answer-by line.
    assert "answer by telling Claude or Hermes" in src
    assert "Q:" in src
    assert "q-handle" in src
    # Read-only by design (fleet-ops#4475 required): no copy button, no write path.
    assert "q-copy" not in src
    assert "data-copy" not in src
    assert "ANSWER_TEMPLATE" not in src
    assert "navigator.clipboard" not in src


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
    items, capped = G._gh_questions()
    assert items == [], "an answered question >24h old must not render"
    assert capped is False, "one row cannot fill the search window"


def test_shell_renders_emdash_not_unknown():
    src = Path(__file__).resolve().parent.joinpath("shell.html").read_text()
    assert ">unknown</div>" not in src
    assert ">—</" in src or ">—</div>" in src or ">—</div>" in src


# --- fleet-ops#4996: gh argv/arity and fail-closed regressions -----------
#
# The console's "Questions for Nish" tile was dark since it landed because
# `_gh_questions()` passed the repo AND the issue number to `gh issue view`,
# which accepts one positional. The tests above monkeypatch `_gh_json`, so
# they never saw the argv — which is exactly how the bug shipped dark. These
# tests monkeypatch the subprocess RUNNER instead and assert on the recorded
# argv.

# Flags whose NEXT token is their value — used to tell flags from positionals.
_VALUE_TAKING_FLAGS = {"-R", "--repo", "--json", "--jq", "--template",
                       "--owner", "--state", "--label", "--limit",
                       "--sort", "--order"}
_SUBCOMMAND_HEADS = (["issue", "view"], ["search", "issues"])


def _positionals(tokens):
    """Tokens that are neither a flag nor the value of a flag."""
    pos, i = [], 0
    while i < len(tokens):
        tok = tokens[i]
        if tok.startswith("-"):
            i += 2 if tok in _VALUE_TAKING_FLAGS else 1
            continue
        pos.append(tok)
        i += 1
    return pos


def _after_subcommand(argv):
    """One argv minus its `gh <subcommand> <subcommand>` head."""
    return argv[3:] if argv[1:3] in _SUBCOMMAND_HEADS else argv[1:]


def _assert_issue_view_argv(calls, rows):
    """Assert the fleet-ops#4996 argv contract over recorded invocations.

    Fails on the form that shipped — `gh issue view Nishfleet/0509 2585
    --json comments`, which gh 2.93.0 rejects with rc=1 `accepts 1 arg(s),
    received 2` — because that invocation has two positionals and passes a
    repo as a positional.
    """
    assert calls, "the questions collector made no gh call"
    repos = {r["repository"]["nameWithOwner"] for r in rows}
    for argv in calls:
        assert argv[0] == "gh", f"not a gh invocation: {argv}"
        pos = _positionals(_after_subcommand(argv))
        assert len(pos) <= 1, f"more than one positional in {argv}: {pos}"
        assert not repos.intersection(pos), \
            f"repo passed as a positional: {argv}"
    search = [a for a in calls if a[1:3] == ["search", "issues"]]
    assert len(search) == 1, f"expected one search call, got {len(search)}"
    views = [a for a in calls if a[1:3] == ["issue", "view"]]
    assert len(views) == len(rows), \
        f"expected one issue view per search row ({len(rows)}), got {len(views)}"
    for view, row in zip(views, rows):
        rest = _after_subcommand(view)
        assert "-R" in rest, f"issue view named no repo via -R: {view}"
        i = rest.index("-R")
        assert i + 1 < len(rest), f"-R carries no value: {view}"
        assert rest[i + 1] == row["repository"]["nameWithOwner"], \
            f"-R value is not the search row's repo: {view}"
        assert _positionals(rest) == [str(row["number"])], \
            f"issue view positionals must be exactly the issue number: {view}"
        # Pin the payload flags too: the issue's other half was --jq
        # ".comments || []" — invalid jq (rc=1) and boolean-or even if it
        # parsed (True -> coerced to [], answers vanish). "//" is required.
        for flag, want in (("--json", "comments"),
                           ("--jq", ".comments // []")):
            assert flag in rest, f"issue view missing {flag}: {view}"
            j = rest.index(flag)
            assert j + 1 < len(rest) and rest[j + 1] == want, \
                f"{flag} value drifted: {view}"


class _FakeGh:
    """Stand-in for `generate`'s subprocess module.

    Records every argv it is asked to run and answers from fixtures. It never
    shells out, so these tests hold with `gh` absent from PATH, make no
    network calls, and do not depend on today's date or the live org.
    """

    def __init__(self, rows, comments=None, view_rc=0, view_stderr="",
                 view_stdout=None):
        self.rows = rows
        self.comments = comments or {}
        self.view_rc = view_rc
        self.view_stderr = view_stderr
        self.view_stdout = view_stdout
        self.calls = []

    def run(self, argv, **kwargs):
        argv = list(argv)
        self.calls.append(argv)
        if argv[1:3] == ["search", "issues"]:
            return subprocess.CompletedProcess(argv, 0, json.dumps(self.rows), "")
        number = next((int(t) for t in argv[3:] if t.isdigit()), None)
        if self.view_rc != 0:                      # a real gh argv error
            stdout = ""
        elif self.view_stdout is not None:
            stdout = self.view_stdout
        else:
            stdout = json.dumps(self.comments.get(number, []))
        return subprocess.CompletedProcess(argv, self.view_rc, stdout,
                                           self.view_stderr)


def _question_rows():
    """Two-or-three issue dicts shaped like `gh search issues --json ...`."""
    return [
        {"number": 2585, "title": "Money question",
         "url": "https://x/2585", "createdAt": "2026-01-01T00:00:00Z",
         "repository": {"nameWithOwner": "Nishfleet/0509"},
         "labels": [{"name": "question"}],
         "body": "question: raise prices?\noptions: a | b"},
        {"number": 2284, "title": "Router choice",
         "url": "https://x/2284", "createdAt": "2026-01-02T00:00:00Z",
         "repository": {"nameWithOwner": "Nishfleet/fleet-ops"},
         "labels": [{"name": "question"}, {"name": "nish-reserved"}],
         "body": "question: router X or Y?\noptions: x | y"},
        {"number": 101, "title": "Color",
         "url": "https://x/101", "createdAt": "2026-01-03T00:00:00Z",
         "repository": {"nameWithOwner": "Nishfleet/siterep"},
         "labels": [{"name": "question"}],
         "body": "question: pick a color?\noptions: red | blue"},
    ]


def test_questions_issue_view_argv_takes_one_positional(monkeypatch):
    """fleet-ops#4996 regression — argv and arity of the per-issue fetch.

    The per-issue `gh issue view` call must carry exactly ONE positional (the
    issue number) and must name its repo only as the value of `-R`. The form
    that shipped passed the repo and the number as two positionals
    (`gh issue view Nishfleet/0509 2585 --json comments`), which exited rc=1
    `accepts 1 arg(s), received 2`, so the tile was dark from the day it
    landed. The runner is patched here — not `_gh_json` — because the
    `_gh_json`-level tests above never see the argv, which is how the bug
    shipped dark.
    """
    rows = _question_rows()
    fake = _FakeGh(rows)
    monkeypatch.setattr(G, "subprocess", fake)
    tile = G.collect_questions()
    assert tile["ok"] is True and tile["count"] == len(rows)
    _assert_issue_view_argv(fake.calls, rows)


def test_questions_nonzero_exit_still_fails_closed(monkeypatch):
    """fleet-ops#4996 acceptance bullet 4 — fail-closed survives the runner
    patch. A non-zero `gh` exit (here the pre-fix argv error itself) must
    leave the tile ok=false with observed_at null and the non-zero exit named
    in the reason — never ok=true with an empty list and count=0."""
    rows = _question_rows()
    fake = _FakeGh(rows, view_rc=1,
                   view_stderr="accepts 1 arg(s), received 2")
    monkeypatch.setattr(G, "subprocess", fake)
    tile = G.collect_questions()
    assert tile["ok"] is False
    assert tile["observed_at"] is None
    assert "github" in tile["reason"]
    assert "rc=1" in tile["reason"]
    assert "accepts 1 arg(s), received 2" in tile["reason"]
    assert not tile.get("count")
    assert "items" not in tile


def test_questions_nonjson_stdout_still_fails_closed(monkeypatch):
    """fleet-ops#4996 acceptance bullet 4, second half: a gh exit of 0 whose
    stdout is not JSON must also leave ok=false with the reason, never
    ok=true with an empty list."""
    rows = _question_rows()
    fake = _FakeGh(rows, view_stdout="not json at all")
    monkeypatch.setattr(G, "subprocess", fake)
    tile = G.collect_questions()
    assert tile["ok"] is False
    assert tile["observed_at"] is None
    assert "github" in tile["reason"]
    assert "JSON" in tile["reason"]
    assert not tile.get("count")


def test_questions_failure_reason_names_the_repo(monkeypatch):
    """fleet-ops#5069 — a failing per-issue fetch must name the repo.

    `_gh_json` built its reason from `args[:3]`. That was fine only while the
    (broken) argv had the repo in position 3; after fleet-ops#4996 the fetch
    is `["issue","view",<number>,"-R",<repo>,...]`, so a dark questions tile
    reported `gh issue view 2585 rc=1: ...` with no repo and the diagnosis
    required reading data.json. The reason must carry the failing repo.
    """
    rows = _question_rows()
    fake = _FakeGh(rows, view_rc=1,
                   view_stderr="accepts 1 arg(s), received 2")
    monkeypatch.setattr(G, "subprocess", fake)
    tile = G.collect_questions()
    assert tile["ok"] is False
    first = rows[0]                 # 2585 in Nishfleet/0509 — fetched first
    assert first["repository"]["nameWithOwner"] == "Nishfleet/0509"
    assert "-R Nishfleet/0509" in tile["reason"], tile["reason"]
    assert f"gh issue view {first['number']} -R Nishfleet/0509 rc=1" \
        in tile["reason"], tile["reason"]
    # The inverse leg: a call with no -R must not grow a phantom repo.
    class _AlwaysRc1:
        def run(self, argv, **kwargs):
            return subprocess.CompletedProcess(list(argv), 1, "", "boom")

    monkeypatch.setattr(G, "subprocess", _AlwaysRc1())
    try:
        G._gh_json(["search", "issues", "--owner", "Nishfleet"])
    except RuntimeError as e:
        assert str(e).startswith("gh search issues --owner rc=1: "), str(e)
    else:
        raise AssertionError("a rc=1 search must raise")


# --- fleet-ops#5469: findings ledger tile ---

def _write_ledger(tmp_path, rows, name="findings-ledger.jsonl"):
    p = tmp_path / name
    p.write_text("".join(json.dumps(r) + "\n" for r in rows))
    return p


def _iso_hours_ago(h):
    import datetime as _dt
    return (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(hours=h)
            ).strftime("%Y-%m-%dT%H:%M:%SZ")


def test_findings_tile_reads_canonical_ledger(monkeypatch, tmp_path):
    """The findings tile counts the canonical vault ledger per disposition,
    newest rows first, and raises the red-banner inputs when a carry-over
    is older than 24h. The ledger jsonl is the truth — no second copy."""
    rows = [
        {"ts": _iso_hours_ago(30), "finding_id": "b", "severity": "high",
         "source_organ": "fleet-blind-audit",
         "title": "old carry", "disposition": "carried_over",
         "ref": "r2", "reason": "y"},
        {"ts": _iso_hours_ago(2), "finding_id": "a", "severity": "info",
         "source_organ": "fleet-blind-audit",
         "title": "fresh carry", "disposition": "carried_over",
         "ref": "r1", "reason": "x"},
        {"ts": _iso_hours_ago(1), "finding_id": "c", "severity": "info",
         "source_organ": "silent-drop-sweep",
         "title": "filed one", "disposition": "filed"},
    ]
    monkeypatch.setattr(G, "FINDINGS_LEDGER", _write_ledger(tmp_path, rows))
    t = G.collect_findings()
    assert t["ok"] is True
    assert t["observed_at"] is not None
    assert t["stale_after_s"] > 0
    assert t["source"] == "vault _system/shared-memory/findings-ledger.jsonl"
    assert t["total"] == 3
    assert t["dispositions"]["carried_over"] == 2
    assert t["dispositions"]["filed"] == 1
    assert t["oldest_carry_h"] > 24
    assert "24h" in t["alert"]          # carried-over > 24h -> red banner
    assert "48h" not in t["alert"]      # appended 1h ago: not silent
    assert len(t["items"]) == 3
    assert t["items"][0]["finding_id"] == "c"   # newest first
    assert t["items"][0]["source_organ"] == "silent-drop-sweep"
    assert t["explain"]

    # A disposition the summary does not name is still counted — never a
    # KeyError that would freeze the whole generated doc.
    rows2 = rows + [{"ts": _iso_hours_ago(0),
                     "disposition": "brand_new_kind"}]
    monkeypatch.setattr(G, "FINDINGS_LEDGER",
                        _write_ledger(tmp_path, rows2, name="l2.jsonl"))
    t2 = G.collect_findings()
    assert t2["ok"] is True and t2["total"] == 4
    assert t2["dispositions"]["brand_new_kind"] == 1


def test_findings_tile_fails_closed(monkeypatch, tmp_path):
    """Missing or unreadable ledger -> ok=false, observed_at null, a named
    reason — never a frozen last value."""
    monkeypatch.setattr(G, "FINDINGS_LEDGER", tmp_path / "absent.jsonl")
    t = G.collect_findings()
    assert t["ok"] is False
    assert t["observed_at"] is None
    assert "ledger" in t["reason"]
    assert t["explain"]

    bad = tmp_path / "bad.jsonl"
    bad.write_text("{not json\n")
    monkeypatch.setattr(G, "FINDINGS_LEDGER", bad)
    t2 = G.collect_findings()
    assert t2["ok"] is False and t2["observed_at"] is None
    assert "unreadable" in t2["reason"]


def test_findings_silent_ledger_is_itself_a_finding(monkeypatch, tmp_path):
    """A ledger with no append for 48h raises the red-banner input even
    when no carried-over row is old."""
    rows = [{"ts": _iso_hours_ago(72), "finding_id": "z",
             "disposition": "filed", "title": "old filed"}]
    monkeypatch.setattr(G, "FINDINGS_LEDGER", _write_ledger(tmp_path, rows))
    t = G.collect_findings()
    assert t["ok"] is True
    assert "48h" in t["alert"]
    assert "silent ledger" in t["alert"]


def test_shell_renders_findings_section():
    """The shell carries the Findings ledger section, its red banner
    element, and reads tiles.findings with ref-as-link (fleet-ops#5469)."""
    src = Path(__file__).resolve().parent.joinpath("shell.html").read_text()
    assert "section-findings" in src
    assert "Findings ledger" in src
    assert "findings-banner" in src
    assert "findings-body" in src
    assert "findings-summary" in src
    assert "t.findings" in src
    assert "source_organ" in src
    assert "github.com/Nishfleet/$1/issues/$2" in src  # ref renders as a link


if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))
