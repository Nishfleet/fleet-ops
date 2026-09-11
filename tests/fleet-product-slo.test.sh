#!/usr/bin/env bash
# tests/fleet-product-slo.test.sh
#
# fleet-ops#2755: product delivery SLO family. Offline (no live gh).
# Hosted by tests/ci-standards-audit.test.sh so P14 runs it without a
# workflow-file edit.
#
# Proves:
#   (a) throughput_weekly counts non-revert merges in the trailing 7d
#   (b) lead_time_days excludes revert PRs (median of non-revert only)
#   (c) revert_rate = reverts / merges over trailing 28d
#   (d) product repo list = intake-repos.json repos[] minus
#       self-maintenance-repos.json (fleet-ops dropped; 0509 kept)
#   (e) empty window still emits fleet_product_slo_last_run_seconds
#   (f) main() end-to-end writes a textfile with exact metric names
#   (g) MANIFEST installs the helper + exporter drop-in (no new timer)
#   (h) fleet_rules.yml ships FleetProductSloAbsent + ProductThroughputStalled
#       + ProductLeadTimeDegrading + ProductRevertRateHigh
#   (i) config/fleet-organs.json registers the organ
#   (j) console shipped_24h source is fleet_product_merged_24h
#   (o) product OUTCOME gauges (signups/activated/paying/briefs, fleet-ops#4456)
#       are emitted only when the D1 source is reachable — never a fabricated 0
#   (p) business-table census emits all five fleet_product_table_rows lines
#       with the D1 counts (fleet-ops#5000)
#   (q) a failed census read omits the family, never a fabricated 0
#   (r) ProductDataCensusDropped rule contract + promtool fire/silent pair
#   (s) fleet-ops#5001: the 24h outcome windows are TRUE trailing windows. A
#       25h-old row (previous calendar day) is excluded from signups /
#       activated / briefs, and a 23h-old row is counted. The captured real SQL
#       runs against an in-memory sqlite3 fixture pinned to a fixed clock.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
helper="$repo_root/lib/fleet-product-slo.py"
rules="$repo_root/config/fleet_rules.yml"
manifest="$repo_root/MANIFEST"
dropin="$repo_root/systemd/fleet-metrics-export.service.d/product-slo.conf"
organs="$repo_root/config/fleet-organs.json"
intake="$repo_root/config/intake-repos.json"
selfm="$repo_root/config/self-maintenance-repos.json"
generate="$repo_root/libexec/fleet-console-pi/generate.py"
verify="$repo_root/libexec/fleet-console-pi/verify.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$helper" ]] || fail "missing $helper"
[[ -f "$rules" ]] || fail "missing $rules"
[[ -f "$dropin" ]] || fail "missing $dropin"
[[ -f "$organs" ]] || fail "missing $organs"
[[ -f "$intake" ]] || fail "missing $intake"
[[ -f "$selfm" ]] || fail "missing $selfm"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t product-slo-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Fixed "now": 2026-09-02T12:00:00Z
NOW_ISO="2026-09-02T12:00:00Z"
NOW_TS=1788350400

# =========================================================================
# (d) product repos = intake minus self-maintenance
# =========================================================================
python3 - "$helper" "$intake" "$selfm" <<'PY' || fail "product repo list failed"
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["ps"] = m
spec.loader.exec_module(m)

repos = m.load_product_repos(Path(sys.argv[2]), Path(sys.argv[3]))
assert "0509" in repos, repos
assert "fleet-ops" not in repos, repos
# Sanity: intake has both; self-maint drops fleet-ops.
intake = json.loads(Path(sys.argv[2]).read_text())
enrolled = {r["name"] for r in intake["repos"]}
assert "0509" in enrolled and "fleet-ops" in enrolled
print("OK: product repos =", repos)
PY
ok "(d) respects intake-repos.json product repo list (fleet-ops excluded)"

# =========================================================================
# (a)(b)(c) compute_repo_slo: throughput, lead time excludes reverts, rate
# =========================================================================
python3 - "$helper" <<'PY' || fail "compute_repo_slo failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["ps"] = m
spec.loader.exec_module(m)

NOW = 1788350400  # 2026-09-02T12:00:00Z
DAY = 86400

prs = [
    # Non-revert, merged 2d ago, issue filed 5d before merge -> lead=5
    m.MergedPR(number=10, repo="0509", title="feat: landing", head_ref="claim/issue-10",
               merged_ts=NOW - 2 * DAY, issue_created_ts=NOW - 2 * DAY - 5 * DAY),
    # Non-revert, merged 3d ago, issue filed 9d before merge -> lead=9
    m.MergedPR(number=11, repo="0509", title="fix: billing", head_ref="claim/issue-11",
               merged_ts=NOW - 3 * DAY, issue_created_ts=NOW - 3 * DAY - 9 * DAY),
    # Revert of #10, merged 1d ago — MUST NOT count in throughput or lead
    m.MergedPR(number=12, repo="0509", title="Revert \"feat: landing\"", head_ref="revert/10",
               merged_ts=NOW - 1 * DAY, issue_created_ts=NOW - 1 * DAY - 1 * DAY),
    # Non-revert outside the 7d window (10d ago) — still in 28d for revert_rate den
    m.MergedPR(number=13, repo="0509", title="feat: old", head_ref="claim/issue-13",
               merged_ts=NOW - 10 * DAY, issue_created_ts=NOW - 20 * DAY),
    # Revert outside week but inside 28d
    m.MergedPR(number=14, repo="0509", title="Revert \"feat: old\"", head_ref="revert/13",
               merged_ts=NOW - 9 * DAY, issue_created_ts=None),
    # Control-plane merge — ignored for 0509 stats
    m.MergedPR(number=99, repo="fleet-ops", title="fix: exporter", head_ref="claim/issue-99",
               merged_ts=NOW - 1 * DAY, issue_created_ts=NOW - 2 * DAY),
    # Non-revert in last 24h
    m.MergedPR(number=15, repo="0509", title="feat: today", head_ref="claim/issue-15",
               merged_ts=NOW - 0.5 * DAY, issue_created_ts=NOW - 2 * DAY),
    # Auto-restore bot revert: lowercase `revert:` title, head `revert/<sha>`
    # (fleet convention — ConsoleLying live case, fleet-ops#4061). Must be
    # excluded by title even without the head-ref check.
    m.MergedPR(number=16, repo="0509",
               title="revert: auto-restore green main (reverts b498b90)",
               head_ref="revert/b498b90",
               merged_ts=NOW - 4 * 3600, issue_created_ts=None),
]

s = m.compute_repo_slo("0509", prs, now_ts=NOW)

# (a) weekly non-revert: #10, #11, #15 (not #12 revert, not #13 outside week)
assert s.throughput_weekly == 3, f"throughput={s.throughput_weekly}"

# (b) lead time excludes reverts: samples 5 and 9 and (2-0.5? wait #15: merged NOW-0.5d, created NOW-2d -> 1.5d)
# leads: #10=5, #11=9, #15=1.5 -> median = 5
assert abs(s.lead_time_days - 5.0) < 1e-9, f"lead={s.lead_time_days} samples={s.lead_samples}"
assert all(x != 1.0 for x in s.lead_samples), "revert lead must not appear"

# (c) revert_rate over 28d: reverts=#12,#14,#16 (3); merges=all 0509 in
# 28d = #10..#16 = 7
assert s.merges_28d == 7, s.merges_28d
assert s.reverts_28d == 3, s.reverts_28d
assert abs(s.revert_rate - 3 / 7) < 1e-9, s.revert_rate

# 24h non-revert: only #15 (#16 is a bot revert)
assert s.merged_24h == 1, s.merged_24h
assert m.is_revert(prs[-1]) is True, "lowercase `revert:` title must count as a revert"
assert m.is_revert(prs[-2]) is False

print("OK: compute_repo_slo a/b/c")
PY
ok "(a)(b)(c) throughput / lead-time-excludes-reverts / revert_rate"

# =========================================================================
# (e) empty window still emits heartbeat + zeros
# =========================================================================
# export_prom writes to FLEET_PRODUCT_SLO_OUT (like (f)); without it the
# default /var/lib/prometheus/node-exporter path is not writable in hosted
# CI, so the write fails before assertions run (FileNotFoundError, 2026-09-02).
export FLEET_PRODUCT_SLO_OUT="$scratch/heartbeat.prom"
python3 - "$helper" <<'PY' || fail "empty heartbeat failed"
import importlib.util, os, sys
from datetime import datetime, timezone
# fleet-ops#4456: force the offline path so the outcome gauges stay absent;
# without this the test would probe 0509 D1 on a host with a real sanctioned
# CF token and become non-deterministic.
os.environ["FLEET_PRODUCT_OUTCOME"] = "skip"
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["ps"] = m
spec.loader.exec_module(m)

now = datetime(2026, 9, 2, 12, 0, 0, tzinfo=timezone.utc)
body = m.export_prom([m.RepoSLO(repo="0509")], now=now)
assert "fleet_product_slo_last_run_seconds" in body
assert 'fleet_product_throughput_weekly{repo="0509"} 0' in body
assert 'fleet_product_lead_time_days{repo="0509"} 0.000000' in body
assert 'fleet_product_revert_rate{repo="0509"} 0.000000' in body
assert 'fleet_product_merged_24h{repo="0509"} 0' in body
# fleet-ops#4456: an unreachable source must emit NO outcome gauge, never a
# fabricated 0.
assert "fleet_product_signups_24h" not in body, body
assert "fleet_product_activated_24h" not in body, body
assert "fleet_product_paying_customers_total" not in body, body
assert "fleet_product_briefs_delivered_24h" not in body, body
print("OK: empty heartbeat")
PY
ok "(e) empty window emits heartbeat + zeros; unreachable outcome source stays absent"

# =========================================================================
# (o) fleet-ops#4456: product OUTCOME gauges are emitted with real values when
#     the D1 source is reachable, and only then.
# =========================================================================
python3 - "$helper" <<'PY' || fail "outcome emit failed"
import importlib.util, os, sys
from datetime import datetime, timezone
# Reachable source: monkeypatch _product_outcome (the real one hits D1). The
# export path must include exactly the four gauges with the returned values.
os.environ["FLEET_PRODUCT_OUTCOME"] = "skip"  # keep import-side network off
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["ps"] = m
spec.loader.exec_module(m)
m._product_outcome = lambda: {
    "signups_24h": 3,
    "activated_24h": 2,
    "paying_customers": 6,
    "briefs_delivered_24h": 12,
}

now = datetime(2026, 9, 2, 12, 0, 0, tzinfo=timezone.utc)
body = m.export_prom([m.RepoSLO(repo="0509")], now=now)
assert "fleet_product_signups_24h 3" in body, body
assert "fleet_product_activated_24h 2" in body, body
assert "fleet_product_paying_customers_total 6" in body, body
assert "fleet_product_briefs_delivered_24h 12" in body, body
# HELP/TYPE each exactly once
for metric in ("fleet_product_signups_24h", "fleet_product_activated_24h",
               "fleet_product_paying_customers_total", "fleet_product_briefs_delivered_24h"):
    assert body.count("# HELP " + metric) == 1, (metric, body)
    assert body.count("# TYPE " + metric) == 1, (metric, body)
print("OK: outcome gauges emitted from a reachable source")
PY
ok "(o) outcome gauges emitted with real values when the source is reachable"

# =========================================================================
# (p) fleet-ops#5000: the mocked-D1 business-table census emits one
#     fleet_product_table_rows line per table, with the D1 counts, and the
#     HELP/TYPE pair exactly once.
# =========================================================================
python3 - "$helper" <<'PY' || fail "census emit failed"
import importlib.util, os, sys
from datetime import datetime, timezone
# Reachable source: monkeypatch _product_outcome (the real one hits D1) with
# the four outcome scalars PLUS the census row, exactly as _product_outcome
# parses it out of the one compound SELECT (fleet-ops#5000).
os.environ["FLEET_PRODUCT_OUTCOME"] = "skip"  # keep import-side network off
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["ps"] = m
spec.loader.exec_module(m)
m._product_outcome = lambda: {
    "signups_24h": 3,
    "activated_24h": 2,
    "paying_customers": 6,
    "briefs_delivered_24h": 12,
    "table_census": {
        "user_plan": 6,
        "watchlist": 12,
        "delivery_attempt": 4,
        "proof_capture": 4,
        "session": 9,
    },
}

now = datetime(2026, 9, 2, 12, 0, 0, tzinfo=timezone.utc)
body = m.export_prom([m.RepoSLO(repo="0509")], now=now)
want = {
    "user_plan": 6,
    "watchlist": 12,
    "delivery_attempt": 4,
    "proof_capture": 4,
    "session": 9,
}
for table, rows in want.items():
    line = f'fleet_product_table_rows{{table="{table}"}} {rows}'
    assert line in body, (line, body)
# Exactly the five tables — all present, nothing extra in the family.
assert body.count("fleet_product_table_rows{") == len(want), body
# HELP/TYPE each exactly once
assert body.count("# HELP fleet_product_table_rows") == 1, body
assert body.count("# TYPE fleet_product_table_rows") == 1, body
print("OK: census gauges emitted for all five tables")
PY
ok "(p) census gauges emitted for all five tables with the mocked D1 counts"

# =========================================================================
# (q) fleet-ops#5000: a failed census read OMITS the family — never a
#     fabricated 0, which would fire ProductDataCensusDropped on a D1 blip.
# =========================================================================
python3 - "$helper" <<'PY' || fail "census-absent failed"
import importlib.util, os, sys
from datetime import datetime, timezone
os.environ["FLEET_PRODUCT_OUTCOME"] = "skip"  # keep import-side network off
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["ps"] = m
spec.loader.exec_module(m)
# The census-only failure shape: the four scalars read fine, the census
# query raised, so _product_outcome returns no "table_census" key.
m._product_outcome = lambda: {
    "signups_24h": 3,
    "activated_24h": 2,
    "paying_customers": 6,
    "briefs_delivered_24h": 12,
}

now = datetime(2026, 9, 2, 12, 0, 0, tzinfo=timezone.utc)
body = m.export_prom([m.RepoSLO(repo="0509")], now=now)
# The whole family is absent — not zero — so Prometheus absent() surfaces it
# and the dropped-census rule cannot fire on an unreadable source.
assert "fleet_product_table_rows" not in body, body
# A census-only failure must not take the four outcome gauges down with it.
assert "fleet_product_signups_24h 3" in body, body
assert "fleet_product_briefs_delivered_24h 12" in body, body
print("OK: failed census read omits the family (no fabricated 0)")
PY
ok "(q) failed census read omits fleet_product_table_rows instead of zeroing it"

# =========================================================================
# (s) fleet-ops#5001 boundary: the trailing 24h window must be a TRAILING
#     window, not "everything on the cutoff's calendar day".
#
#     Fixture rows are dated 25h / 23h / 8d / 6d23h before a PINNED clock. The
#     25h row sits on the previous CALENDAR day, which is the exact shape the
#     pre-fix TEXT comparison (`createdAt >= datetime('now','-1 day')`, whose
#     right side is a space-separated no-Z string) counted as "inside 24h".
#
#     No network: the helper's real `_D1_QUERIES` literals are captured off the
#     outgoing Request and executed against an in-memory sqlite3 DB, so this is
#     the shipped SQL, not a copy of it. The only substitution is SQLite's
#     clock literal 'now' -> the pinned timestamp (the seam that makes the
#     boundary deterministic); comparators, columns and window arithmetic are
#     untouched.
# =========================================================================
printf 'CLOUDFLARE_API_TOKEN=fake-token-not-used\n' >"$scratch/boundary-cf.env"
export FLEET_PRODUCT_SLO_OUT="$scratch/boundary.prom"
python3 - "$helper" "$scratch/boundary-cf.env" <<'PY' || fail "24h boundary regression failed (fleet-ops#5001)"
import importlib.util, json, os, sqlite3, sys
from datetime import datetime, timedelta, timezone

# Deterministic D1 config: the shipped defaults are valid 32-hex IDs, but the
# environment could override them, so pin both segments here.
os.environ["FLEET_PRODUCT_D1_ACCOUNT"] = "f670a698e17bf160c8e4679823e68916"
os.environ["FLEET_PRODUCT_D1_DATABASE"] = "746c6e3d-782e-443a-82d6-28ca93a16294"
# _read_cf_token()'s first candidate is FLEET_PRODUCT_CF_FILE, so a fake token
# file keeps the real D1 code path AND keeps the host's real token out of the
# test. urlopen is replaced below, so the fake token is never sent anywhere.
os.environ["FLEET_PRODUCT_CF_FILE"] = sys.argv[2]
# Falsy -> OUTCOME_SKIP is falsy, so _product_outcome runs instead of returning
# None immediately. Must be set BEFORE the import (read at module scope).
os.environ["FLEET_PRODUCT_OUTCOME"] = ""

spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["ps"] = m
spec.loader.exec_module(m)
assert not m.OUTCOME_SKIP, "FLEET_PRODUCT_OUTCOME must be falsy for this scenario"

# Pinned clock. 2026-09-02T12:00:00Z -> the SQLite cutoff for '-1 day' is the
# text '2026-09-01 12:00:00'.
PINNED = "2026-09-02T12:00:00Z"


def ago(hours, minutes=0):
    base = datetime.fromisoformat(PINNED.replace("Z", "+00:00"))
    d = base - timedelta(hours=hours, minutes=minutes)
    return d.strftime("%Y-%m-%dT%H:%M:%S.000Z")


# The four fixture ages, in the real stored ISO-8601 shape (T + Z + millis).
T25, T23 = ago(25), ago(23)
T8D, T6D23 = ago(8 * 24), ago(6 * 24 + 23)
assert T25 == "2026-09-01T11:00:00.000Z", T25
assert T23 == "2026-09-01T13:00:00.000Z", T23
assert T8D == "2026-08-25T12:00:00.000Z", T8D
assert T6D23 == "2026-08-26T13:00:00.000Z", T6D23

U25, U23, U8D, U6D23 = "u-25h", "u-23h", "u-8d", "u-6d23h"

conn = sqlite3.connect(":memory:")
conn.executescript(
    "CREATE TABLE user (id TEXT, createdAt TEXT NOT NULL);"
    "CREATE TABLE user_plan (user_id TEXT, plan TEXT);"
    "CREATE TABLE delivery_attempt (user_id TEXT, status TEXT, sent_at TEXT);"
    "CREATE TABLE watchlist (user_id TEXT);"
    "CREATE TABLE proof_capture (id TEXT);"
    "CREATE TABLE session (id TEXT);"
)
conn.executemany(
    "INSERT INTO user (id, createdAt) VALUES (?, ?)",
    [(U25, T25), (U23, T23), (U8D, T8D), (U6D23, T6D23)],
)
conn.executemany(
    "INSERT INTO user_plan (user_id, plan) VALUES (?, ?)",
    [(U23, "pro"), (U8D, "free")],
)
conn.executemany(
    "INSERT INTO delivery_attempt (user_id, status, sent_at) VALUES (?, ?, ?)",
    [
        # First SENT brief 2 min after signup (activation) at 23h and 25h.
        (U23, "sent", ago(23, 2)),
        (U25, "sent", ago(25, 2)),
        # Outside every 24h window, whatever the comparison does.
        (U8D, "sent", ago(8 * 24, 2)),
        (U6D23, "sent", ago(6 * 24 + 23, 2)),
        # Status control: a non-'sent' row is never counted.
        (U23, "queued", ago(23, 3)),
    ],
)

# Guard the premise of the scenario: with the PRE-FIX TEXT comparison these
# two rows textually sort as "inside the window" (they share the cutoff's
# date, and 'T' > ' '). If this ever stops holding, the scenario has stopped
# exercising the bug and the test is worthless — so assert it here.
cutoff_text = conn.execute("SELECT datetime(?, '-1 day')", (PINNED,)).fetchone()[0]
assert cutoff_text == "2026-09-01 12:00:00", cutoff_text
assert T25 >= cutoff_text, (T25, cutoff_text)
assert T23 >= cutoff_text, (T23, cutoff_text)

captured = []


class _FakeResp:
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def fake_urlopen(req, timeout=None):
    """Run the captured real SQL against the fixture DB instead of D1."""
    captured.append(req)
    sql = json.loads(req.data.decode("utf-8"))["sql"]
    # Pin SQLite's clock. 'now' is the only thing rewritten.
    run_sql = sql.replace("'now'", "'%s'" % PINNED)
    cur = conn.execute(run_sql)
    cols = [d[0] for d in cur.description]
    row = dict(zip(cols, cur.fetchone()))
    payload = json.dumps(
        {"success": True, "result": [{"results": [row]}]}
    ).encode("utf-8")
    return _FakeResp(payload)


m.urlopen = fake_urlopen

out = m._product_outcome()
assert out is not None, "_product_outcome returned None: D1 seam unusable"
assert len(captured) == len(m._D1_QUERIES), (
    f"expected {len(m._D1_QUERIES)} D1 queries, captured {len(captured)}"
)
window_sqls = [json.loads(r.data.decode("utf-8"))["sql"] for r in captured]
assert sum("'now'" in s for s in window_sqls) == 3, window_sqls

# The 25h row must NOT be counted anywhere. Pre-fix it was counted in all
# three windows (the value would be 2).
assert out["signups_24h"] == 1, f"signups_24h={out['signups_24h']} (25h row counted?)"
assert out["activated_24h"] == 1, f"activated_24h={out['activated_24h']} (25h row counted?)"
assert out["briefs_delivered_24h"] == 1, (
    f"briefs_delivered_24h={out['briefs_delivered_24h']} (25h row counted?)"
)
# Control: no window comparison anywhere in paying_customers.
assert out["paying_customers"] == 1, out["paying_customers"]

# And the same values must reach the emitted gauge lines.
now = datetime(2026, 9, 2, 12, 0, 0, tzinfo=timezone.utc)
body = m.export_prom([m.RepoSLO(repo="0509")], now=now)
for line in (
    "fleet_product_signups_24h 1",
    "fleet_product_activated_24h 1",
    "fleet_product_briefs_delivered_24h 1",
    "fleet_product_paying_customers_total 1",
):
    assert line in body, (line, body)
print("OK: 24h boundary (25h excluded, 23h included)")
PY
ok "(s) 24h boundary: 25h-ago row excluded from signups/activated/briefs, 23h counted"

# =========================================================================
# (f) main() end-to-end via fixture
# =========================================================================
cat >"$scratch/fixture.json" <<'JSON'
{
  "repos": ["0509"],
  "prs": [
    {
      "number": 1,
      "repo": "0509",
      "title": "feat: a",
      "head_ref": "claim/1",
      "merged_ts": 1788264000,
      "issue_created_ts": 1788004800
    },
    {
      "number": 2,
      "repo": "0509",
      "title": "Revert \"feat: a\"",
      "head_ref": "revert/1",
      "merged_ts": 1788300000,
      "issue_created_ts": null
    },
    {
      "number": 3,
      "repo": "0509",
      "title": "feat: b",
      "head_ref": "claim/3",
      "merged_ts": 1788333600,
      "issue_created_ts": 1788240000
    }
  ]
}
JSON
# merged_ts: 1788264000 = NOW-1d, 1788300000 = NOW-14h, 1788333600 = NOW-4.67h
# issue leads: #1 = (1788264000-1788004800)/86400 = 3.0d; #3 = (1788333600-1788240000)/86400 = 1.0833d

OUT="$scratch/out.prom"
FLEET_PRODUCT_SLO_OUT="$OUT" \
FLEET_PRODUCT_SLO_NOW="$NOW_ISO" \
FLEET_PRODUCT_SLO_FIXTURE="$scratch/fixture.json" \
  python3 "$helper" --stdout >"$scratch/stdout.prom"
[[ -f "$OUT" ]] || fail "main() did not write $OUT"
grep -q 'fleet_product_throughput_weekly{repo="0509"} 2' "$OUT" \
  || fail "fixture throughput want 2 (non-reverts #1+#3): $(grep throughput "$OUT")"
# #1 merged_ts = NOW-1d = exactly DAY_S ago; day_cut = NOW - DAY_S, condition is
# day_cut < merged <= now so #1 is NOT in 24h. Only #3 counts -> merged_24h=1.
grep -q 'fleet_product_merged_24h{repo="0509"} 1' "$OUT" \
  || fail "fixture 24h want 1 (#3 only; #1 is exactly 1d ago): $(grep merged_24h "$OUT")"
grep -q 'fleet_product_revert_rate{repo="0509"} 0.333333' "$OUT" \
  || fail "fixture revert_rate want 1/3: $(grep revert_rate "$OUT")"
grep -q 'fleet_product_slo_last_run_seconds ' "$OUT" \
  || fail "missing heartbeat"
# HELP/TYPE once each
for metric in fleet_product_throughput_weekly fleet_product_lead_time_days \
              fleet_product_revert_rate fleet_product_merged_24h \
              fleet_product_slo_last_run_seconds; do
  help_count=$(grep -c "^# HELP $metric " "$OUT" || true)
  type_count=$(grep -c "^# TYPE $metric " "$OUT" || true)
  [[ "$help_count" -eq 1 ]] || fail "$metric HELP count=$help_count"
  [[ "$type_count" -eq 1 ]] || fail "$metric TYPE count=$type_count"
done
# lead median of [3.0, 1.083333...] = average of both sorted mid = (1.0833+3)/2 for even? 
# statistics.median of 2 values = average. Check roughly.
python3 - "$OUT" <<'PY' || fail "lead_time parse"
import sys, re
text = open(sys.argv[1]).read()
m = re.search(r'fleet_product_lead_time_days\{repo="0509"\} ([0-9.]+)', text)
assert m, text
val = float(m.group(1))
# samples: 3.0 and (1788333600-1788240000)/86400 = 93600/86400 = 1.083333...
# median of two = avg = 2.041666...
assert abs(val - 2.041666666) < 1e-5, val
print("OK: lead_time", val)
PY
ok "(f) main() fixture end-to-end textfile"

# =========================================================================
# (g) MANIFEST + drop-in + no new timer
# =========================================================================
grep -Fxq "lib/fleet-product-slo.py /home/nish/.local/lib/pi-packet/fleet-product-slo.py" "$manifest" \
  || fail "MANIFEST missing lib/fleet-product-slo.py dest"
grep -Fxq "systemd/fleet-metrics-export.service.d/product-slo.conf /home/nish/.config/systemd/user/fleet-metrics-export.service.d/product-slo.conf" "$manifest" \
  || fail "MANIFEST missing product-slo drop-in"
grep -q "ExecStart=-/bin/bash -c 'exec /usr/bin/python3 /home/nish/.local/lib/pi-packet/fleet-product-slo.py'" "$dropin" \
  || fail "drop-in must ExecStart=- the helper under ~/.local/lib/pi-packet/"
[[ ! -f "$repo_root/systemd/fleet-product-slo.timer" ]] \
  || fail "must not add a new timer; piggyback fleet-metrics-export (accept §5 rejected as new organ)"
[[ ! -f "$repo_root/systemd/fleet-product-slo.service" ]] \
  || fail "must not add a new service; piggyback fleet-metrics-export"
ok "(g) MANIFEST + drop-in wiring; no new timer"

# =========================================================================
# (h)(i) Rules + organ registry
# =========================================================================
grep -q 'alert: FleetProductSloAbsent' "$rules" \
  || fail "rules missing FleetProductSloAbsent"
grep -q 'absent(fleet_product_slo_last_run_seconds)' "$rules" \
  || fail "Absent rule must watch fleet_product_slo_last_run_seconds"
grep -q 'alert: ProductThroughputStalled' "$rules" \
  || fail "rules missing ProductThroughputStalled"
grep -q 'alert: ProductLeadTimeDegrading' "$rules" \
  || fail "rules missing ProductLeadTimeDegrading"
grep -q 'alert: ProductRevertRateHigh' "$rules" \
  || fail "rules missing ProductRevertRateHigh"
grep -q 'fleet_product_throughput_weekly{repo="0509"}' "$rules" \
  || fail "ProductThroughputStalled must gate on throughput weekly"
grep -q 'fleet_product_lead_time_days{repo="0509"} > 14' "$rules" \
  || fail "ProductLeadTimeDegrading must gate on lead_time > 14"
grep -q 'fleet_product_revert_rate{repo="0509"} > 0.15' "$rules" \
  || fail "ProductRevertRateHigh must gate on revert_rate > 0.15"

jq -e '.organs[] | select(.name=="product-slo")
  | select(.heartbeat_metric=="fleet_product_slo_last_run_seconds")
  | select(.absent_alert=="FleetProductSloAbsent")' "$organs" >/dev/null \
  || fail "fleet-organs.json missing product-slo organ"
ok "(h)(i) rules + organ registry"

# =========================================================================
# (j) console tile single source of truth
# =========================================================================
grep -q 'fleet_product_merged_24h' "$generate" \
  || fail "generate.py must read fleet_product_merged_24h"
grep -q 'prometheus:fleet_product_merged_24h' "$generate" \
  || fail "generate.py shipped tile source must be fleet_product_merged_24h"
! grep -q 'src = "prometheus:fleet_merged_prs_24h"' "$generate" \
  || fail "generate.py must not still source shipped_24h from fleet_merged_prs_24h"
grep -q 'sum(fleet_product_merged_24h)' "$verify" \
  || fail "verify.py shipped_prom must sum fleet_product_merged_24h"
ok "(j) console shipped_24h reads fleet_product_merged_24h"

# =========================================================================
# (k) fleet-ops#3519 per-repo quality metrics + committed ceilings
# =========================================================================
export FLEET_PRODUCT_SLO_OUT="$scratch/quality.prom"
FLEET_PRODUCT_SLO_SESSIONS="$scratch/sessions" \
python3 - "$helper" "$repo_root/config/quality-ratchet.json" <<'PY' || fail "quality metrics failed"
import importlib.util, json, os, sys
from datetime import datetime, timezone
from pathlib import Path
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["ps"] = m
spec.loader.exec_module(m)

# Point sessions at an empty dir so sessions_to_pr_pct == 0 (no host noise).
m.SESSIONS_DIR = Path(sys.argv[3]) if len(sys.argv) > 3 else Path("/nonexistent-sessions")
NOW = 1788350400  # 2026-09-02T12:00:00Z
DAY = 86400
prs = [
    # feat merged 2d ago, tied to an issue filed 3d ago (in-week link, NO
    # defect label) — normal throughput, must NOT count as a defect (#3587).
    m.MergedPR(number=1, repo="0509", title="feat: a", head_ref="claim/1",
               merged_ts=NOW - 2 * DAY, issue_created_ts=NOW - 3 * DAY),
    # revert merged 1d ago (in-week) with no linked issue
    m.MergedPR(number=2, repo="0509", title="Revert feat: a", head_ref="revert/1",
               merged_ts=NOW - 1 * DAY, issue_created_ts=None),
    # old merge, outside week
    m.MergedPR(number=3, repo="0509", title="feat: old", head_ref="claim/3",
               merged_ts=NOW - 10 * DAY, issue_created_ts=None),
    # defect-fix merged 1.5d ago, closes a bug-labeled issue filed 2d ago
    # (in-week) — a real post-merge defect report, MUST count (#3587).
    m.MergedPR(number=4, repo="0509", title="fix: billing crash", head_ref="claim/4",
               merged_ts=NOW - 1.5 * DAY, issue_created_ts=NOW - 2 * DAY,
               defect_issue_created_ts=NOW - 2 * DAY),
    # fix merged 1d ago closing an in-week issue with NO defect label — a
    # pre-existing fix, not a post-merge defect; must NOT count (#3587).
    m.MergedPR(number=5, repo="0509", title="fix: copy", head_ref="claim/5",
               merged_ts=NOW - 1 * DAY, issue_created_ts=NOW - 2 * DAY),
]
s = m.compute_repo_slo("0509", prs, now_ts=NOW)
# merges_7d = #1,#2,#4,#5 = 4; reverts_7d = 1 -> 25/100
assert s.merges_7d == 4, s.merges_7d
assert abs(s.quality_reverts_per_100 - 25.0) < 1e-9, s.quality_reverts_per_100
# defects: only #4 closes an in-week defect-labeled issue -> 1/4 = 25/100.
# #1 (feat, no label) and #5 (fix, no label) are normal throughput, NOT defects.
assert abs(s.quality_defects_per_100 - 25.0) < 1e-9, s.quality_defects_per_100
assert s.quality_sessions_to_pr_pct == 0.0, s.quality_sessions_to_pr_pct
print("OK: compute quality metrics (reverts 25/100, defects 25/100, sessions 0)")

# Direction lock (fleet-ops#3519): sessions_to_pr_pct = 100 * sessions / merges
# (sessions per 100 merged PRs; high = churning = bad). With 4 in-week session
# dirs and 4 in-week merges, the metric must be 100.0 — NOT 25.0 (the inverted
# 100 * merges / sessions shape that previously fired a false ceiling alert).
sess_root = Path(os.environ.get("FLEET_PRODUCT_SLO_SESSIONS", "/nonexistent-sessions"))
sess_root.mkdir(parents=True, exist_ok=True)
m.SESSIONS_DIR = sess_root
import time as _time
recent = _time.time()
for n in (10, 11, 12, 13):
    d = sess_root / f"pi-issue-0509-{n}"
    d.mkdir(parents=True, exist_ok=True)
    p = d / "session.jsonl"
    p.write_text("{}\n")
    os.utime(str(p), (recent, recent))
s2 = m.compute_repo_slo("0509", prs, now_ts=NOW)
assert s2.sessions_7d == 4, s2.sessions_7d
assert abs(s2.quality_sessions_to_pr_pct - 100.0) < 1e-9, s2.quality_sessions_to_pr_pct
print("OK: sessions_to_pr_pct direction = 100 * sessions / merges (100.0 for 4 sessions / 4 merges)")

# Ceilings load from config/quality-ratchet.json.
ratchet_path = sys.argv[2]
raw = json.loads(Path(ratchet_path).read_text())
# module reads candidates; force the config path so the test is hermetic
m._QUALITY_RATCHET_CANDIDATES = [ratchet_path]
ceil = m.load_ceilings(["0509", "futurerepo"])
assert ceil["0509"]["reverts_per_100_merges"] == 4.5, ceil
assert ceil["0509"]["sessions_to_pr_pct"] == 115.0, ceil  # 33 -> 115: 2026-09-09 mis-seed correction (fleet-ops#4580)
# _default fallback arms a future repo
assert ceil["futurerepo"]["post_merge_defects_per_100"] == 40.0, ceil
print("OK: ceilings loaded from config/quality-ratchet.json (+ _default fallback)")

# Export carries the quality families + ceiling series.
body = m.export_prom([s], now=m.parse_iso("2026-09-02T12:00:00Z"))
assert 'fleet_product_quality_reverts_per_100{repo="0509"} 25.000000' in body
assert 'fleet_product_quality_post_merge_defects_per_100{repo="0509"} 25.000000' in body
assert 'fleet_product_quality_sessions_to_pr_pct{repo="0509"} 0.000000' in body
assert 'fleet_product_quality_ceiling{repo="0509",metric="reverts_per_100_merges"} 4.500000' in body
assert 'fleet_product_quality_ceiling{repo="0509",metric="sessions_to_pr_pct"} 115.000000' in body
assert 'fleet_product_quality_ceiling{repo="0509",metric="post_merge_defects_per_100"} 40.000000' in body
print("OK: export carries quality gauges + ceilings")
PY
ok "(k) per-repo quality metrics + committed ceilings"

# =========================================================================
# (l) fleet-ops#3532 --repo-check: arm-gate verdict vs committed ceiling
# =========================================================================
cat >"$scratch/ratchet-3532.json" <<'JSON'
{
  "ceilings": {
    "_default": {"reverts_per_100_merges": 10.0, "red_on_main_minutes": 360.0},
    "calm": {"reverts_per_100_merges": 60.0, "red_on_main_minutes": 360.0}
  }
}
JSON
cat >"$scratch/repo-check-fixture.json" <<'JSON'
{
  "repos": ["0509", "calm"],
  "prs": [
    {"number": 1, "repo": "0509", "title": "feat: a", "head_ref": "claim/1",
     "merged_ts": 1788300000, "issue_created_ts": null},
    {"number": 2, "repo": "0509", "title": "Revert feat: a", "head_ref": "revert/1",
     "merged_ts": 1788326400, "issue_created_ts": null},
    {"number": 3, "repo": "calm", "title": "feat: x", "head_ref": "claim/3",
     "merged_ts": 1788330000, "issue_created_ts": null},
    {"number": 4, "repo": "calm", "title": "feat: y", "head_ref": "claim/4",
     "merged_ts": 1788340000, "issue_created_ts": null}
  ]
}
JSON
# 0509: merges_7d=2, reverts_7d=1 -> 50/100 vs _default ceiling 10 -> breach.
FLEET_PRODUCT_SLO_FIXTURE="$scratch/repo-check-fixture.json" \
FLEET_PRODUCT_SLO_NOW="$NOW_ISO" \
FLEET_QUALITY_RATCHET_JSON="$scratch/ratchet-3532.json" \
FLEET_PRODUCT_SLO_SESSIONS="$scratch/sessions" \
  python3 "$helper" --repo-check 0509 >"$scratch/v0509.json" \
  || fail "--repo-check 0509 exited nonzero"
jq -e '.ok == false
  and .breached == ["reverts_per_100_merges"]
  and .measured.reverts_per_100_merges == 50
  and .ceiling.reverts_per_100_merges == 10
  and .ceiling.red_on_main_minutes == 360
  and .merges_7d == 2
  and (.unmeasured | index("red_on_main_minutes") != null)' \
  "$scratch/v0509.json" >/dev/null \
  || fail "--repo-check 0509 verdict wrong: $(cat "$scratch/v0509.json")"

# calm: merges_7d=2, reverts=0 -> 0/100 vs ceiling 60 -> arms.
FLEET_PRODUCT_SLO_FIXTURE="$scratch/repo-check-fixture.json" \
FLEET_PRODUCT_SLO_NOW="$NOW_ISO" \
FLEET_QUALITY_RATCHET_JSON="$scratch/ratchet-3532.json" \
FLEET_PRODUCT_SLO_SESSIONS="$scratch/sessions" \
  python3 "$helper" --repo-check calm >"$scratch/vcalm.json" \
  || fail "--repo-check calm exited nonzero"
jq -e '.ok == true and .breached == []
  and .measured.reverts_per_100_merges == 0
  and .ceiling.reverts_per_100_merges == 60
  and .merges_7d == 2' "$scratch/vcalm.json" >/dev/null \
  || fail "--repo-check calm verdict wrong: $(cat "$scratch/vcalm.json")"

# Unenrolled repo: no merges and the _default ceiling row -> arms.
FLEET_PRODUCT_SLO_FIXTURE="$scratch/repo-check-fixture.json" \
FLEET_PRODUCT_SLO_NOW="$NOW_ISO" \
FLEET_QUALITY_RATCHET_JSON="$scratch/ratchet-3532.json" \
FLEET_PRODUCT_SLO_SESSIONS="$scratch/sessions" \
  python3 "$helper" --repo-check futurerepo >"$scratch/vfuture.json" \
  || fail "--repo-check futurerepo exited nonzero"
jq -e '.ok == true and .breached == [] and .merges_7d == 0
  and .ceiling.reverts_per_100_merges == 10' \
  "$scratch/vfuture.json" >/dev/null \
  || fail "--repo-check futurerepo verdict wrong: $(cat "$scratch/vfuture.json")"

# Measurement failure (no gh) -> exit 1, no verdict on stdout: the workflow
# step reads that as fail-open.
if FLEET_PRODUCT_SLO_GH="$scratch/no-such-gh" \
   FLEET_QUALITY_RATCHET_JSON="$scratch/ratchet-3532.json" \
   FLEET_PRODUCT_SLO_NOW="$NOW_ISO" \
   python3 "$helper" --repo-check 0509 >"$scratch/vfail.json" 2>/dev/null; then
  fail "--repo-check with no gh must exit nonzero"
fi
[[ ! -s "$scratch/vfail.json" ]] \
  || fail "--repo-check failure must not print a verdict"

# The workflow gate shape: fetch pinned lib + ceiling, run --repo-check,
# refuse to arm on breach.
arm_wf="$repo_root/.github/workflows/reusable-auto-merge-arm.yml"
grep -q 'id: quality' "$arm_wf" \
  || fail "reusable-auto-merge-arm.yml must define the quality step"
grep -q -- '--repo-check' "$arm_wf" \
  || fail "reusable-auto-merge-arm.yml must call --repo-check"
grep -q 'config/quality-ratchet.json' "$arm_wf" \
  || fail "reusable-auto-merge-arm.yml must read the committed ceiling"
grep -q 'stop-the-line: quality ceiling breached' "$arm_wf" \
  || fail "reusable-auto-merge-arm.yml must print the stop-the-line verdict"
grep -q "steps.quality.outputs.breached == 'false'" "$arm_wf" \
  || fail "Arm auto-merge must gate on steps.quality.outputs.breached"
ok "(l) --repo-check verdict + arm-gate wiring (fleet-ops#3532)"

# =========================================================================
# (m) fleet-ops#4039: LabelConnection retry — merged_24h survives a GitHub
# GraphQL gateway error on the nested labels subquery. A mock gh returns the
# LabelConnection schema error when the query carries `labels(first:`, and
# valid merged-PR data (no labels) when it does not. The exporter must retry
# without labels and still return PRs (so merged_24h keeps flowing); only the
# defect_issue_created_ts quality field degrades to None.
# =========================================================================
mock_gh="$scratch/gh-labelconnection"
cat >"$mock_gh" <<'PY'
#!/usr/bin/env python3
import json, sys
payload = json.load(sys.stdin)
query = payload.get("query", "")
# Page 1 with labels -> LabelConnection schema error (the GitHub gateway bug).
# Any query without the labels subquery -> valid merged-PR data.
if "labels(first: 20)" in query:
    print(json.dumps({"errors": [{"message": "Field 'name' doesn't exist on type 'LabelConnection'"}]}))
    sys.exit(0)
# Valid response: one non-revert merge in the last 24h, one revert, with
# closing-issue references but NO labels (the stripped-query shape).
now = 1788350400  # 2026-09-02T12:00:00Z (matches NOW_ISO)
day = 86400
nodes = [
    {
        "number": 21,
        "title": "feat: shipped today",
        "headRefName": "claim/issue-21",
        "mergedAt": "2026-09-02T08:00:00Z",  # ~4h ago, inside 24h
        "repository": {"nameWithOwner": "Nishfleet/0509"},
        "closingIssuesReferences": {"nodes": [
            {"number": 20, "createdAt": "2026-09-01T08:00:00Z"}
        ]},
    },
    {
        "number": 22,
        "title": "Revert \"feat: shipped today\"",
        "headRefName": "revert/21",
        "mergedAt": "2026-09-02T09:00:00Z",  # ~3h ago, inside 24h, revert
        "repository": {"nameWithOwner": "Nishfleet/0509"},
        "closingIssuesReferences": {"nodes": []},
    },
]
print(json.dumps({"data": {"search": {
    "pageInfo": {"hasNextPage": False, "endCursor": None},
    "nodes": nodes,
}}}))
PY
chmod +x "$mock_gh"

CACHE_4039="$scratch/product-slo-cache-4039.json"
FLEET_PRODUCT_SLO_GH="$mock_gh" \
FLEET_PRODUCT_SLO_CACHE="$CACHE_4039" \
FLEET_PRODUCT_SLO_NOW="$NOW_ISO" \
FLEET_PRODUCT_SLO_OUT="$scratch/out-4039.prom" \
  python3 - "$helper" <<'PY' || fail "LabelConnection retry failed"
import importlib.util, json, os, sys
from datetime import datetime, timezone
from pathlib import Path
spec = importlib.util.spec_from_file_location("fps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["fps"] = m
spec.loader.exec_module(m)

now = m.parse_iso("2026-09-02T12:00:00Z")
repos = ["0509"]
prs = m.load_merged_prs(now, repos)
assert prs is not None, "load_merged_prs returned None — LabelConnection retry did not fire"
assert len(prs) == 2, f"expected 2 PRs, got {len(prs)}"
# merged_24h: only the non-revert (#21) counts; the revert (#22) is excluded.
slo = m.compute_repo_slo("0509", prs, now_ts=now.timestamp())
assert slo.merged_24h == 1, f"merged_24h want 1, got {slo.merged_24h}"
# defect_issue_created_ts degrades to None (labels stripped) — the quality
# metric yields 0, but the delivery tile source is intact.
for p in prs:
    assert p.defect_issue_created_ts is None, "labels stripped path must not set defect_issue_created_ts"
assert slo.quality_defects_per_100 == 0.0, "defects must be 0 without labels"
# Cache was written from the stripped-query fetch.
cache = json.loads(Path(os.environ["FLEET_PRODUCT_SLO_CACHE"]).read_text())
assert "prs" in cache and len(cache["prs"]) == 2, "cache must hold the 2 PRs"
print("OK: LabelConnection retry — merged_24h=1 preserved, defect metric degraded to 0")
PY
ok "(m) LabelConnection retry keeps merged_24h flowing (fleet-ops#4039)"

# =========================================================================
# (n) fleet-ops#4073: the LabelConnection schema error also surfaces as a
# non-2xx HTTP status, so `gh api graphql` exits rc!=0 with the error on
# stderr (observed in production at 2026-09-06T23:15Z: `gh graphql rc=1:
# gh: Field 'name' doesn't exist on type 'LabelConnection'`). The #4102
# payload-error retry (test m) checks payload.get("errors") and never fires
# on the rc!=0 path — _gh_graphql returned None and stale cache was served,
# so merged_24h drifted and ConsoleLying re-fired. This test's mock gh exits
# rc=1 with the LabelConnection error on STDERR when the query carries
# `labels(first:`, and returns valid merged-PR data (no labels) when it does
# not. The exporter must retry without labels and still return PRs.
# =========================================================================
mock_gh_rc="$scratch/gh-labelconnection-rc"
cat >"$mock_gh_rc" <<'PY'
#!/usr/bin/env python3
import json, sys
payload = json.load(sys.stdin)
query = payload.get("query", "")
# Page 1 with labels -> rc=1 + LabelConnection on stderr (the production
# gateway-bug shape that bypassed #4102's payload-error retry).
if "labels(first: 20)" in query:
    sys.stderr.write(
        "gh: Field 'name' doesn't exist on type 'LabelConnection'\n"
    )
    sys.exit(1)
# Valid response once labels are stripped: one non-revert merge in 24h.
now = 1788350400  # 2026-09-02T12:00:00Z (matches NOW_ISO)
nodes = [
    {
        "number": 31,
        "title": "feat: shipped today (rc-variant)",
        "headRefName": "claim/issue-31",
        "mergedAt": "2026-09-02T08:00:00Z",
        "repository": {"nameWithOwner": "Nishfleet/0509"},
        "closingIssuesReferences": {"nodes": [
            {"number": 30, "createdAt": "2026-09-01T08:00:00Z"}
        ]},
    },
]
print(json.dumps({"data": {"search": {
    "pageInfo": {"hasNextPage": False, "endCursor": None},
    "nodes": nodes,
}}}))
PY
chmod +x "$mock_gh_rc"

CACHE_4073="$scratch/product-slo-cache-4073.json"
FLEET_PRODUCT_SLO_GH="$mock_gh_rc" \
FLEET_PRODUCT_SLO_CACHE="$CACHE_4073" \
FLEET_PRODUCT_SLO_NOW="$NOW_ISO" \
FLEET_PRODUCT_SLO_OUT="$scratch/out-4073.prom" \
  python3 - "$helper" <<'PY' || fail "LabelConnection rc!=0 retry failed"
import importlib.util, json, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("fps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["fps"] = m
spec.loader.exec_module(m)

now = m.parse_iso("2026-09-02T12:00:00Z")
repos = ["0509"]
prs = m.load_merged_prs(now, repos)
assert prs is not None, "load_merged_prs returned None — rc!=0 LabelConnection retry did not fire"
assert len(prs) == 1, f"expected 1 PR, got {len(prs)}"
# merged_24h: the one non-revert merge counts.
slo = m.compute_repo_slo("0509", prs, now_ts=now.timestamp())
assert slo.merged_24h == 1, f"merged_24h want 1, got {slo.merged_24h}"
# defect_issue_created_ts degrades to None (labels stripped).
for p in prs:
    assert p.defect_issue_created_ts is None, "labels stripped path must not set defect_issue_created_ts"
cache = json.loads(Path(os.environ["FLEET_PRODUCT_SLO_CACHE"]).read_text())
assert "prs" in cache and len(cache["prs"]) == 1, "cache must hold the 1 PR"
print("OK: LabelConnection rc!=0 retry — merged_24h=1 preserved, defect metric degraded to 0")
PY
ok "(n) LabelConnection rc!=0/stderr retry keeps merged_24h flowing (fleet-ops#4073)"

# =========================================================================
# (r) fleet-ops#5000: the ProductDataCensusDropped rule contract — severity
#     critical, for: 5m, the exact expr, and an annotation set that names the
#     table, carries the deletion-not-ageing phrase, links the issue, and
#     never sends a repair worker to the exporter.
# =========================================================================
census_block="$(awk '/# fleet-ops#5000: a 0509 production business table/,/- alert: ProductThroughputStalled/' "$rules")"
[[ -n "$census_block" ]] || fail "could not extract ProductDataCensusDropped block"
grep -qF 'alert: ProductDataCensusDropped' <<<"$census_block" \
  || fail "rules missing ProductDataCensusDropped (fleet-ops#5000)"
grep -qF 'expr: fleet_product_table_rows == 0 and max_over_time(fleet_product_table_rows[24h] offset 5m) >= 1' <<<"$census_block" \
  || fail "ProductDataCensusDropped expr must be the level check to zero with the offset 5m 24h history"
grep -qF 'for: 5m' <<<"$census_block" \
  || fail "ProductDataCensusDropped must use for: 5m"
grep -qF 'severity: critical' <<<"$census_block" \
  || fail "ProductDataCensusDropped must be severity=critical (data loss, not a trend)"
grep -qF '{{ $labels.table }}' <<<"$census_block" \
  || fail "ProductDataCensusDropped annotations must name the affected table via {{ \$labels.table }}"
grep -qF 'production product data is empty — rows were deleted, not aged out' <<<"$census_block" \
  || fail "ProductDataCensusDropped description must carry the deletion-not-ageing phrase"
grep -qF 'Nishfleet/fleet-ops#5000' <<<"$census_block" \
  || fail "ProductDataCensusDropped description must link Nishfleet/fleet-ops#5000"
grep -qF 'migrations/0085_retention_sweep_state.sql' <<<"$census_block" \
  || fail "ProductDataCensusDropped must say why gradual decay is expected (the retention-sweep migration)"
! grep -qi 'repair the exporter' <<<"$census_block" \
  || fail "ProductDataCensusDropped must not route the worker at the exporter — the data is empty, the read is fine"
ok "(r) ProductDataCensusDropped rule contract (fleet-ops#5000)"

# =========================================================================
# promtool (optional)
# =========================================================================
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null \
    || fail "promtool check rules failed"
  ok "promtool check rules"

  # fleet-ops#5000: the ProductDataCensusDropped drill. Two cases:
  #   (a) a table holding rows for the first 45m and reading 0 after FIRES
  #       at 60m — one 5m step past its for: 5m — because the 24h history
  #       proves rows were deleted rather than aged out;
  #   (b) a healthy non-zero census (3 rows throughout) stays silent, so a
  #       populated table can never trip the deletion rule.
  # exp_annotations are compared strictly by promtool, so the expected text is
  # the rule's own text with {{ $labels.table }} rendered to user_plan.
  census_yml="$scratch/fleet-product-census-dropped.test.yml"
  cat >"$census_yml" <<YOAML
rule_files:
  - $rules
evaluation_interval: 5m
tests:
  - interval: 5m
    name: census that emptied after holding rows fires
    input_series:
      - series: 'fleet_product_table_rows{table="user_plan"}'
        # 6 rows for 10 samples (t=0..45m), then the table reads empty.
        values: '6x10 0x20'
    alert_rule_test:
      - eval_time: 60m
        alertname: ProductDataCensusDropped
        exp_alerts:
          - exp_labels:
              alertname: ProductDataCensusDropped
              severity: critical
              service: fleet
              table: user_plan
            exp_annotations:
              summary: '0509 production table user_plan is empty — the row census dropped to 0'
              description: 'fleet_product_table_rows{table="user_plan"} == 0 while the same table held rows within the last 24h: production product data is empty — rows were deleted, not aged out (Nishfleet/fleet-ops#5000). migrations/0085_retention_sweep_state.sql decays rows gradually, so a cliff to zero is deletion, not ageing. Repair: inspect the user_plan table in the 0509 production D1 database and restore it from D1 Time Travel or the most recent export, then check recent migrations/sweeps for an accidental DELETE or TRUNCATE of user_plan.'
  - interval: 5m
    name: healthy non-zero census stays silent
    input_series:
      - series: 'fleet_product_table_rows{table="user_plan"}'
        values: '3x20'
    alert_rule_test:
      - eval_time: 60m
        alertname: ProductDataCensusDropped
        exp_alerts: []
YOAML
  # promtool test rules exits 1 on a failed case AND prints FAILED to
  # stdout, so gate on both: exit code (loud) and output text (catches
  # the exit-0-print-FAILED quirk on other builds).
  if ! out="$(promtool test rules "$census_yml" 2>&1)"; then
    fail "promtool test rules exited non-zero on the product-census test: $out"
  fi
  grep -q "SUCCESS" <<<"$out" \
    || fail "promtool test rules: ProductDataCensusDropped must fire on a table that emptied and stay silent on a healthy census ($out)"
  ok "promtool test rules: ProductDataCensusDropped fires on deletion, silent on a healthy census (fleet-ops#5000)"
else
  echo "SKIP: promtool not on PATH"
fi

echo "OK: fleet-product-slo: throughput, lead-time-excludes-reverts, revert-rate, intake list, MANIFEST, rules, organ, console source"
