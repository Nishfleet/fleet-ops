#!/usr/bin/env python3
"""Independent truth-check for every fleet-console tile (fleet-ops#1157).

Runs AFTER generate.py on the existing fleet-console-pi push cycle. No new
timer. Each tile carries a `verify` field naming the command that recomputes
its displayed value from source. A mismatch marks the tile DISPUTED and
exports fleet_console_tile_mismatch{tile=...} 1 for ConsoleLying.

Prometheus tiles query 9090 AND, where feasible, spot-check the raw system
(gh for one repo; systemd ExecStart for PI WORK). Cached families use a
percent tolerance on the gh spot; live counts are exact.
"""
from __future__ import annotations

import http.client
import json
import math
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Path(__file__).parent (not resolve): MANIFEST installs this as a symlink
# under ~/.local/libexec/.... data.json must sit next to the symlink.
DATA_JSON = Path(
    os.environ.get(
        "CONSOLE_DATA_JSON",
        str(Path(__file__).parent / "data.json"),
    )
)
PROM_OUT = Path(
    os.environ.get(
        "CONSOLE_TILE_PROM",
        "/var/lib/prometheus/node-exporter/fleet-console-tiles.prom",
    )
)
PROM = os.environ.get("PROM_URL", "http://127.0.0.1:9090")
XDG = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
PAUSED_MARKER = Path(
    os.environ.get(
        "FLEET_PAUSED_MARKER",
        "/home/nish/workspaces/agent-state/FLEET-PAUSED",
    )
)
GH = os.environ.get("GH", "gh")
SYSTEMCTL = os.environ.get("SYSTEMCTL", "systemctl")
SKIP_GH = os.environ.get("CONSOLE_SKIP_GH", "") == "1"
VERIFY_TIMEOUT = int(os.environ.get("CONSOLE_VERIFY_TIMEOUT", "20"))
ORG = os.environ.get("CONSOLE_ORG", "Nishfleet")
SPOT_REPO_DEFAULT = os.environ.get("CONSOLE_SPOT_REPO", "Nishfleet/fleet-ops")
# Same 15-minute freshness window generate.py uses for Prometheus tiles
# (exporter fires every 5 min; 2+ misses = stale).
PROM_STALE_S = 15 * 60
# An `answered` question is displayed for this long after its
# `decision-resolved:` comment, then dropped from the tile. Must equal
# generate.py's ANSWERED_KEEP_S (the tile's own constant) — a verifier
# that counts the raw open-question population false-DISPUTEs a faithful
# tile the moment one answered question ages out (fleet-ops#5070).
ANSWERED_KEEP_S = 24 * 60 * 60
# Must equal generate.py's QUESTION_SEARCH_LIMIT (fleet-ops#5133): both sides
# pass it as `gh search issues --limit`. Without it gh caps the search at its
# default 30 and says nothing, so the verifier's window and the tile's window
# are two independent 30-row slices of the same population — a boundary
# population then false-DISPUTEs a faithful tile, and rows past 30 reach
# neither side.
QUESTION_SEARCH_LIMIT = 1000
# Must equal generate.py's FINDINGS_LEDGER (fleet-ops#5469): the tile and
# its verifier count the SAME canonical vault file.
FINDINGS_LEDGER = Path(
    os.environ.get(
        "CONSOLE_FINDINGS_LEDGER",
        "/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/"
        "findings-ledger.jsonl",
    )
)

HELP_MISMATCH = (
    "# HELP fleet_console_tile_mismatch 1 if this console tile failed its "
    "independent truth-check on the last push, else 0. Unknown/stale tiles "
    "are 0 (a dash is not a lie)."
)
TYPE_MISMATCH = "# TYPE fleet_console_tile_mismatch gauge"
HELP_TS = (
    "# HELP fleet_console_tile_verify_timestamp_seconds Epoch seconds of the "
    "last console tile-verify pass (organ heartbeat for ConsoleTileVerifyAbsent)."
)
TYPE_TS = "# TYPE fleet_console_tile_verify_timestamp_seconds gauge"


class VerifyError(Exception):
    """A verify command could not produce a number."""


# ---------------------------------------------------------------------------
# Tile specs. `cmd` is the executable claim shown in "what is this?".
# `field` is the tile JSON field compared. `tolerance` is exact or percent.
# `spot` is an optional second check (gh); a spot transport failure is SKIP,
# not DISPUTED (a blip is not a lie).
# ---------------------------------------------------------------------------
SPECS = {
    "open_prs": {
        "cmd": (
            "PromQL sum(fleet_open_prs) @ 127.0.0.1:9090 "
            "(exact vs tile count) AND gh search prs "
            "'repo:<spot-repo> is:open type:pr' (vs that repo's item, "
            "bounded by the tile's own window: live minus the PRs opened "
            "since tile.observed_at <= displayed <= live plus the PRs "
            "closed since then; cached family — a lag the cache explains "
            "is not a lie, fleet-ops#5155)"
        ),
        "field": "count",
        "tolerance": {"mode": "exact"},
        "runner": "open_prs_prom",
        "spot": {
            "cmd": (
                "gh api search/issues -f q='repo:<spot-repo> is:open "
                "type:pr' --jq .total_count, plus the created/closed "
                "window counts for the same repo"
            ),
            "tolerance": {"mode": "window"},
            "runner": "open_prs_gh_spot",
        },
    },
    "shipped_24h": {
        "cmd": (
            "PromQL sum(fleet_product_merged_24h) @ 127.0.0.1:9090 "
            "(exact vs tile count) AND gh search prs "
            "'repo:<spot-repo> is:merged merged:>=<24h-iso> type:pr' "
            "(percent vs that repo's item; product-slo family, 2% or abs<=2; "
            "revert titles excluded client-side to match the non-revert "
            "definition, fleet-ops#4061)"
        ),
        "field": "count",
        "tolerance": {"mode": "exact"},
        "runner": "shipped_prom",
        "spot": {
            "cmd": (
                "gh api search/issues -f q='repo:<spot-repo> is:merged "
                "merged:>=<24h-iso> type:pr' --jq .total_count"
            ),
            "tolerance": {"mode": "percent", "pct": 2},
            "runner": "shipped_gh_spot",
        },
    },
    "main_ci": {
        "cmd": "PromQL count(fleet_main_ci_green == 0) @ 127.0.0.1:9090",
        "field": "red_count",
        "tolerance": {"mode": "exact"},
        "runner": "main_ci_prom",
    },
    "firing_alerts": {
        "cmd": (
            "Prometheus GET /api/v1/alerts, state=firing, Watchdog excluded "
            "(same source and filter as the tile writer)"
        ),
        "field": "count",
        "tolerance": {"mode": "exact"},
        "runner": "alerts_prom",
    },
    "repairs_inflight": {
        "cmd": (
            "systemctl --user list-units --type=service --state=running, "
            "names starting alert-repair-, Transient=yes"
        ),
        "field": "count",
        "tolerance": {"mode": "exact"},
        "runner": "repairs_units",
    },
    "running_pi": {
        "cmd": (
            "count of running user units whose ExecStart contains 'pi --print' "
            "(systemctl --user show -p ExecStart; never a unit-name pattern, "
            "fleet-ops#1155)"
        ),
        "field": "count",
        "tolerance": {"mode": "exact"},
        "runner": "running_pi_execstart",
    },
    "fleet_state": {
        "cmd": (
            "test -f /home/nish/workspaces/agent-state/FLEET-PAUSED "
            "(1 if paused, else 0)"
        ),
        "field": "paused",
        "tolerance": {"mode": "exact"},
        "runner": "fleet_paused",
    },
    "questions": {
        "cmd": (
            f"gh search issues --owner Nishfleet --state open --label question "
            f"--limit {QUESTION_SEARCH_LIMIT} (the tile's own search window), "
            f"each row's comments classified through the tile's own 24h "
            f"answered-exclusion (generate.py ANSWERED_KEEP_S) — the remaining "
            f"count == tile count (fleet-ops#5070, window pinned in #5133)"
        ),
        "field": "count",
        "tolerance": {"mode": "exact"},
        "runner": "questions_gh",
    },
    "outcome": {
        "cmd": (
            "PromQL sum(fleet_product_signups_24h), sum(fleet_signups_7d), "
            "sum(fleet_product_activated_24h), "
            "sum(fleet_product_paying_customers_total) @ 127.0.0.1:9090 "
            "(exact, all four vs the tile's four fields; same "
            "product-slo/fleet.prom freshness gate as the tile writer)"
        ),
        "field": "signups_24h",
        "tolerance": {"mode": "exact"},
        "runner": "outcome_prom",
    },
    "findings": {
        "cmd": (
            "count of non-empty rows in the canonical vault "
            "findings-ledger.jsonl (exact vs tile total; every "
            "disposition tally compared too). A ledger append between "
            "generate and verify is a race SKIP, not a lie."
        ),
        "field": "total",
        "tolerance": {"mode": "exact"},
        "runner": "findings_ledger",
    },
}


def attach_specs(doc):
    """Stamp each tile with its verify command (even when the tile is unknown)."""
    tiles = doc.setdefault("tiles", {})
    for name, spec in SPECS.items():
        tile = tiles.setdefault(name, {})
        verify = {
            "cmd": spec["cmd"],
            "field": spec["field"],
            "tolerance": spec["tolerance"],
        }
        if spec.get("spot"):
            verify["spot_cmd"] = spec["spot"]["cmd"]
            verify["spot_tolerance"] = spec["spot"]["tolerance"]
        tile["verify"] = verify
        tile.setdefault("disputed", False)
    return doc


def _atomic_write(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=str(path.parent)
    )
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    try:
        os.chmod(path, 0o644)
    except OSError:
        pass


def _http_json(url, timeout=VERIFY_TIMEOUT):
    """GET JSON from a loopback HTTP URL via http.client (no urllib)."""
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or ""
    if host not in ("127.0.0.1", "localhost", "::1"):
        raise VerifyError(f"refusing non-loopback host {host!r}")
    path = parsed.path or "/"
    if parsed.query:
        path = path + "?" + parsed.query
    conn = http.client.HTTPConnection(host, parsed.port or 80, timeout=timeout)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read()
        if resp.status >= 400:
            raise VerifyError(f"http {resp.status} {url}")
        return json.loads(body)
    except (OSError, TimeoutError, json.JSONDecodeError, ValueError,
            http.client.HTTPException) as exc:
        raise VerifyError(f"http {url}: {str(exc)[:160]}") from exc
    finally:
        conn.close()


def _promql_sum(expr):
    url = PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    payload = _http_json(url)
    if payload.get("status") != "success":
        raise VerifyError(f"prom status={payload.get('status')}")
    rows = (payload.get("data") or {}).get("result") or []
    total = 0.0
    for item in rows:
        try:
            total += float(item["value"][1])
        except (KeyError, IndexError, TypeError, ValueError) as exc:
            raise VerifyError(f"bad sample: {exc}") from exc
    return total


def _promql_sum_present(expr):
    """Sum a PromQL expression, but an empty result vector is an ERROR.

    fleet-ops#5003: `_promql_sum` collapses "absent family" and "real zero"
    to the same 0.0 — correct for the `count(...)` runners, where an empty
    vector genuinely means zero matching series. The outcome funnel must not
    invert the tile-side rule (generate.py renders an absent gauge as
    `_unknown`, never 0), or a fake "0 signups" tile would verify as
    truthful. So: same HTTP query and parse, but no samples raises a
    non-race VerifyError, which verify_tile renders as a DISPUTE naming the
    gauge instead of comparing against zero.
    """
    url = PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    payload = _http_json(url)
    if payload.get("status") != "success":
        raise VerifyError(f"prom status={payload.get('status')}")
    rows = (payload.get("data") or {}).get("result") or []
    if not rows:
        raise VerifyError(f"{expr}: no samples (gauge absent)")
    total = 0.0
    for item in rows:
        try:
            total += float(item["value"][1])
        except (KeyError, IndexError, TypeError, ValueError) as exc:
            raise VerifyError(f"bad sample: {exc}") from exc
    return total


def _int_sample(name, value):
    """Convert one gauge sample to int, or raise VerifyError (a DISPUTE).

    fleet-ops#5003: int(nan) raises ValueError and int(inf) raises
    OverflowError. verify_tile only catches VerifyError, so an unguarded
    conversion would abort run() for EVERY tile — data.json would keep no
    verify results and fleet_console_tile_verify_timestamp_seconds would go
    stale (a false ConsoleTileVerifyAbsent alarm). A non-finite sample is
    not a race, so it must surface as this tile's DISPUTE.
    """
    try:
        if not math.isfinite(value):
            raise VerifyError(f"{name}: non-finite sample {value}")
        return int(value)
    except (ValueError, OverflowError) as exc:
        raise VerifyError(f"{name}: non-finite sample {value}") from exc


def _prom_textfile_mtime():
    """Return the product-slo textfile mtime in epoch seconds, or None.

    fleet-ops#2755: shipped_24h now reads fleet_product_merged_24h from
    fleet-product-slo.prom, so the race gate watches that textfile (falling
    back to the heartbeat gauge when node_textfile_mtime has not scraped it
    yet). Returns None when both are absent — not an error; the downstream
    race check then lets the Prom re-query run.
    """
    url = PROM + "/api/v1/query?" + urllib.parse.urlencode({
        "query": (
            'node_textfile_mtime_seconds{file=~".*fleet-product-slo.prom"} '
            'or fleet_product_slo_last_run_seconds'
        ),
    })
    payload = _http_json(url)
    if payload.get("status") != "success":
        raise VerifyError(f"prom status={payload.get('status')}")
    rows = (payload.get("data") or {}).get("result") or []
    if not rows:
        return None
    try:
        return max(float(r["value"][1]) for r in rows)
    except (KeyError, IndexError, TypeError, ValueError) as exc:
        raise VerifyError(f"bad textfile mtime sample: {exc}") from exc


def _race_against_tile(tile):
    """True iff the textfile mtime advanced past the tile's observed_at.

    fleet-ops#2690: between generate.py and verify.py the metrics exporter
    may refresh fleet-product-slo.prom (every 5 min vs the 12-min push
    cycle). When that happens the tile and the verifier look at the SAME
    Prom family but at different snapshots —
    `tile.count != sum(fleet_product_merged_24h)` is a transient timing
    artifact, not a lying tile. The race gate tells Prom-based checkers
    to defer to the gh check.

    Tolerance of +1s absorbs clock-skew rounding between the tile's
    observed_at capture and the verifier's mtime query.
    """
    observed_at = tile.get("observed_at")
    if not isinstance(observed_at, (int, float)):
        return False  # no anchor → can't race-detect; let the check run
    try:
        mtime = _prom_textfile_mtime()
    except VerifyError:
        return False  # Prom unreachable → defer to spot check (gh)
    if mtime is None:
        return False  # series missing; exporter has never written → not race
    return mtime > float(observed_at) + 1.0


def _systemctl_env():
    env = dict(os.environ)
    env["XDG_RUNTIME_DIR"] = XDG
    return env


def _running_units():
    out = subprocess.run(
        [SYSTEMCTL, "--user", "list-units", "--type=service",
         "--state=running,activating", "--no-legend", "--plain"],
        capture_output=True, text=True, timeout=VERIFY_TIMEOUT,
        env=_systemctl_env(),
    )
    if out.returncode != 0:
        raise VerifyError(f"list-units rc={out.returncode}")
    names = []
    for ln in (out.stdout or "").splitlines():
        name = ln.split()[0] if ln.split() else ""
        if name:
            names.append(name)
    return names


def _show_value(unit, prop):
    out = subprocess.run(
        [SYSTEMCTL, "--user", "show", "-p", prop, "--value", unit],
        capture_output=True, text=True, timeout=VERIFY_TIMEOUT,
        env=_systemctl_env(),
    )
    return (out.stdout or "").strip()


def _spot_repo(tile):
    items = tile.get("items") or []
    for it in items:
        repo = it.get("repo") or ""
        if repo == SPOT_REPO_DEFAULT or repo.endswith("/fleet-ops"):
            return repo
    if items and items[0].get("repo"):
        return items[0]["repo"]
    return SPOT_REPO_DEFAULT


def _item_count_for_repo(tile, repo):
    for it in tile.get("items") or []:
        if it.get("repo") == repo:
            return it.get("count")
    return None


def _gh_search_count(query):
    if SKIP_GH:
        raise VerifyError("gh skipped")
    # GitHub search API total_count — one HTTP call, no 1000-item page.
    # Qualifiers must be space-separated (not one quoted blob).
    out = subprocess.run(
        [GH, "api", "search/issues",
         "-X", "GET", "-f", f"q={query} type:pr", "--jq", ".total_count"],
        capture_output=True, text=True, timeout=VERIFY_TIMEOUT,
    )
    if out.returncode != 0:
        raise VerifyError(
            f"gh search rc={out.returncode}: {(out.stderr or '')[:160]}"
        )
    try:
        return int((out.stdout or "0").strip() or "0")
    except ValueError as exc:
        raise VerifyError(f"gh search parse: {out.stdout[:80]!r}") from exc


def _gh_search_titles(query):
    """Return the titles of every PR matched by the search query.

    The shipped_24h spot check must count NON-revert merges to match the
    tile's definition (fleet_product_merged_24h = non-revert merges), but
    GitHub search's `.total_count` cannot be filtered client-side. Fetch the
    matched titles and count revert PRs out on this side (fleet-ops#4061).
    Paged so a busy 24h (60+ merges) is fully captured.
    """
    if SKIP_GH:
        raise VerifyError("gh skipped")
    out = subprocess.run(
        [GH, "api", "search/issues",
         "-X", "GET", "-f", f"q={query} type:pr", "--paginate",
         "--jq", ".items[]?.title"],
        capture_output=True, text=True, timeout=VERIFY_TIMEOUT,
    )
    if out.returncode != 0:
        raise VerifyError(
            f"gh search rc={out.returncode}: {(out.stderr or '')[:160]}"
        )
    return [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]


def _is_revert_title(title: str) -> bool:
    """Match fleet-product-slo's revert conventions by title.

    fleet-ops#2755 defines shipped throughput as NON-revert merges. The
    fleet's auto-restore bot merges `revert: auto-restore green main
    (reverts <sha>)` (head-ref `revert/<sha>`, lowercase `revert:` title),
    GitHub's auto-revert is `Revert \"...\"`, and the arm titles
    `auto-revert ...`. REST search drops `head` for merged PRs, so the
    title is the only field the spot check can see; strip and lowercase
    so ALL of the collector's title conventions match (fleet-ops#4061).
    """
    t = (title or "").lstrip().lower()
    return (t.startswith("revert ") or t.startswith("revert:")
            or t.startswith("auto-revert"))


def _gh_search_nonrevert_count(query):
    titles = _gh_search_titles(query)
    return sum(0 if _is_revert_title(t) else 1 for t in titles)



def run_open_prs_prom(tile):
    return int(_promql_sum("sum(fleet_open_prs)"))


def run_shipped_prom(tile):
    # fleet-ops#2690 / #2755: skip the Prom re-query when the textfile
    # advanced between generate and verify. The gh spot check still runs;
    # only the same-source race is suppressed. Source of truth is
    # fleet_product_merged_24h (product repos only).
    if _race_against_tile(tile):
        raise VerifyError(
            "textfile mtime advanced past tile.observed_at — race, "
            "defer to gh spot check"
        )
    return int(_promql_sum("sum(fleet_product_merged_24h)"))


def run_outcome_prom(tile):
    """Recompute the outcome tile's four numbers and compare all four.

    The tile is a funnel (signups 24h/7d, activations 24h, paying
    customers) drawn from two textfiles: `fleet_signups_7d` from
    fleet.prom, the other three from fleet-product-slo.prom. The SPEC's
    `field`/`tolerance` only covers the headline (signups_24h), so this
    runner checks ALL FOUR here and raises with every difference named —
    a partly-lying funnel must DISPUTE, not slip through on one field.

    Same gates as run_shipped_prom: a textfile race is a SKIP (the word
    "race" in the message is what verify_tile keys on), and the
    product-slo textfile must be fresh, because a stale snapshot means
    the tile and this re-query are not looking at the same moment.
    """
    if _race_against_tile(tile):
        raise VerifyError(
            "textfile mtime advanced past tile.observed_at — race, defer"
        )
    mtime = _prom_textfile_mtime()
    if mtime is None:
        raise VerifyError("product-slo textfile mtime absent")
    age = time.time() - mtime
    if age > PROM_STALE_S:
        raise VerifyError(f"product-slo.prom stale ({int(age)}s old)")

    sources = (
        ("signups_24h", "sum(fleet_product_signups_24h)"),
        ("signups_7d", "sum(fleet_signups_7d)"),
        ("activated_24h", "sum(fleet_product_activated_24h)"),
        ("paying_customers", "sum(fleet_product_paying_customers_total)"),
    )
    observed = {}
    diffs = []
    for name, expr in sources:
        value = _int_sample(name, _promql_sum_present(expr))
        observed[name] = value
        displayed = tile.get(name)
        try:
            same = int(displayed) == value
        except (TypeError, ValueError):
            same = False  # missing/None/garbage counts as a mismatch
        if not same:
            diffs.append(f"{name} displayed {displayed} vs verify {value}")
    if diffs:
        raise VerifyError("; ".join(diffs))
    return observed["signups_24h"]


def run_main_ci_prom(tile):
    return int(_promql_sum("count(fleet_main_ci_green == 0)"))


def run_alerts_prom(tile):
    """Live Prometheus /api/v1/alerts firing count, Watchdog excluded.

    fleet-ops#3637: the tile writer counts Prometheus /api/v1/alerts where
    state==firing, but the verifier used Alertmanager /api/v2/alerts. Those
    are two legitimately-different views (Alertmanager dedups/suppresses and
    groups), so a tile that faithfully mirrors Prometheus was falsely
    DISPUTED whenever the two sources diverged (ConsoleLying). Re-read the
    SAME Prometheus endpoint the writer claims to mirror, with the same
    filter, so a lying tile still DISPUTES but a true one stays green — the
    #2805 same-source pattern.
    """
    url = PROM.rstrip("/") + "/api/v1/alerts"
    payload = _http_json(url)
    if payload.get("status") != "success":
        raise VerifyError(f"prom alerts status={payload.get('status')}")
    alerts = (payload.get("data") or {}).get("alerts") or []
    n = 0
    for a in alerts:
        if a.get("state") != "firing":
            continue
        name = (a.get("labels") or {}).get("alertname") or ""
        if name == "Watchdog":
            continue
        n += 1
    return n


def run_repairs_units(tile):
    n = 0
    for name in _running_units():
        if not name.startswith("alert-repair-"):
            continue
        if _show_value(name, "Transient") == "yes":
            n += 1
    return n


def _running_pi_units():
    """Live running/activating units whose ExecStart invokes `pi --print`.

    Exact mirror of the tile writer's `_invokes_pi_print` in generate.py
    (fleet-ops#1155: never a unit-name pattern), so a faithful tile and its
    verifier count the SAME set.
    """
    found = []
    for name in _running_units():
        es = _show_value(name, "ExecStart")
        if ("pi --print" in es) or ("/pi-issue-run " in es) or ("/pi-issue-start" in es):
            found.append(name)
    return found


def run_running_pi_execstart(tile):
    """Live running-pi unit count, churn-race tolerant.

    fleet-ops#3674: the tile snapshots the running-pi unit set at generate
    time; this verifier re-scans the SAME live systemd source ~2s later.
    The fleet spawns/finishes workers constantly, so a worker starting or
    stopping in that window makes the two counts legitimately differ — a
    timing artifact, not a lying tile. Mirror #2690: when the live set has
    moved since the tile (the tile's recorded units != what's running now)
    AND the counts now disagree, raise a race VerifyError so verify_tile
    SKIPS (match=None) instead of falsely DISPUTING (ConsoleLying). A
    tile that still disagrees without that churn signal (count off against
    a stable / non-race set) is a genuine lie and DISPUTES.

    The tiles's `units` list is truncated to 20 entries; when more workers
    run than that we can't trust set equality, so a set mismatch only
    counts as a race when the counts already differ. Matching counts never
    race and never dispute (nothing to reconcile).
    """
    live = _running_pi_units()
    live_n = len(live)
    tile_n = tile.get("count")
    if isinstance(tile_n, (int, float)) and int(tile_n) != live_n:
        recorded = tile.get("units")
        if isinstance(recorded, list) and recorded and set(recorded) != set(live):
            raise VerifyError(
                "running_pi unit set changed between generate and verify "
                "(worker start/stop) — race, skip, not a lie"
            )
    return live_n


def run_fleet_paused(tile):
    return 1 if PAUSED_MARKER.exists() else 0


def run_findings_ledger(tile):
    """Recount the canonical findings ledger, all tallies compared.

    Same-source check (fleet-ops#5469): the tile counts rows of the vault
    findings-ledger.jsonl at generate time; this re-reads the SAME file
    ~2s later. An append in that window makes the counts legitimately
    differ — the mtime-past-observed_at gate is the #2690 race pattern:
    SKIP, not DISPUTED. When the file is unchanged the total AND every
    disposition tally must match, or the tile is lying (a partly-lying
    ledger view must not slip through on the headline count).
    """
    try:
        mtime = FINDINGS_LEDGER.stat().st_mtime
    except OSError as e:
        raise VerifyError(f"findings ledger stat: {e}") from e
    if mtime > (tile.get("observed_at") or 0):
        raise VerifyError(
            "findings ledger mtime advanced past tile.observed_at — race, "
            "an append landed between generate and verify"
        )
    try:
        counts = {}
        n = 0
        for ln in FINDINGS_LEDGER.read_text().splitlines():
            if not ln.strip():
                continue
            n += 1
            try:
                d = json.loads(ln).get("disposition")
            except (json.JSONDecodeError, AttributeError):
                d = None
            counts[d] = counts.get(d, 0) + 1
    except OSError as e:
        raise VerifyError(f"findings ledger read: {e}") from e
    displayed = tile.get("dispositions") or {}
    diffs = []
    for k in set(counts) | set(displayed):
        if counts.get(k, 0) != displayed.get(k, 0):
            diffs.append(
                f"dispositions[{k}] displayed {displayed.get(k, 0)} "
                f"vs verify {counts.get(k, 0)}"
            )
    if diffs:
        raise VerifyError("; ".join(diffs))
    return n


def _question_answer_epoch(comments):
    """Epoch of the newest `decision-resolved:` comment, or None.

    Mirror of generate.py `_answer_epoch` (fleet-ops#5070): same field,
    same newest-wins rule, same tz parse. Keep the two in step or an
    aged answer is classified differently on each side.
    """
    latest = None
    for c in (comments or []):
        body = (c or {}).get("body") or ""
        if "decision-resolved:" not in body:
            continue
        created = (c or {}).get("createdAt")
        if not created:
            continue
        try:
            epoch = datetime.fromisoformat(
                created.replace("Z", "+00:00")).timestamp()
        except ValueError:
            continue
        if latest is None or epoch > latest:
            latest = epoch
    return latest


def _questions_open_issues():
    """The open `question` population org-wide, one gh search.

    Same store, same qualifiers AND same explicit --limit as generate.py's
    `_gh_questions` search (fleet-ops#1157 same-source pattern, #5133 same
    window). Labels ride along so a debugger can see the row's shape; the
    24h exclusion below is what matters.
    """
    out = subprocess.run(
        [GH, "search", "issues", "--owner", ORG, "--state", "open",
         "--label", "question", "--limit", str(QUESTION_SEARCH_LIMIT),
         "--json", "number,repository,labels"],
        capture_output=True, text=True, timeout=VERIFY_TIMEOUT,
    )
    if out.returncode != 0:
        raise VerifyError(
            f"gh search rc={out.returncode}: {(out.stderr or '')[:160]}"
        )
    try:
        rows = json.loads(out.stdout or "[]")
    except (json.JSONDecodeError, TypeError) as e:
        raise VerifyError(f"gh search parse: {e}") from e
    if not isinstance(rows, list):
        raise VerifyError(f"gh search returned {type(rows).__name__}")
    return rows


def _questions_comments(issue):
    """Comments of one issue. `gh issue view` takes ONE positional (the
    number); the repo is named only via -R (fleet-ops#4996)."""
    repo = (issue.get("repository") or {}).get("nameWithOwner") or ORG
    out = subprocess.run(
        [GH, "issue", "view", str(issue.get("number")), "-R", repo,
         "--json", "comments", "--jq", ".comments // []"],
        capture_output=True, text=True, timeout=VERIFY_TIMEOUT,
    )
    if out.returncode != 0:
        raise VerifyError(
            f"gh issue view rc={out.returncode}: {(out.stderr or '')[:160]}"
        )
    try:
        comments = json.loads(out.stdout or "[]")
    except (json.JSONDecodeError, TypeError) as e:
        raise VerifyError(f"gh issue view parse: {e}") from e
    if not isinstance(comments, list):
        raise VerifyError(f"gh issue view returned {type(comments).__name__}")
    return comments


def run_questions_gh(tile):
    """Count the questions the tile is contracted to display.

    NOT "every open `question` issue": generate.py drops an `answered`
    question once its `decision-resolved:` comment is older than
    ANSWERED_KEEP_S (24h). Counting the raw search total false-DISPUTEs a
    faithful tile as soon as one answered question ages out — latent while
    the tile was dark, reachable once fleet-ops#4996 lit it. Classify every
    row through the SAME 24h exclusion (the #4061 same-definition pattern)
    so a faithful tile and its verifier count the SAME set (fleet-ops#1157
    same-source pattern). A gh transport blip is a SKIP, not a DISPUTE.
    """
    if SKIP_GH:
        raise VerifyError("gh skipped")
    now = time.time()
    shown = 0
    for issue in _questions_open_issues():
        answer_epoch = _question_answer_epoch(_questions_comments(issue))
        if answer_epoch is not None and now - answer_epoch > ANSWERED_KEEP_S:
            continue
        shown += 1
    return shown


def run_open_prs_gh_spot(tile):
    """Live open-PR cross-check that is sound against the cache, not just fresh.

    The tile's number was measured at the tile's own `observed_at` (the
    exporter publishes the cache's measurement time — fleet-ops#5155), so the
    only honest way to judge it against GitHub NOW is a window: every PR
    opened since that instant may be legitimately missing from the tile, and
    every PR closed since may still be in it. A gap inside that window is a
    cache lag; a gap outside it is a real error. A fixed ±2/15% band cannot
    express that — a repo opening 4 PRs in 9 minutes drifts 4 past the floor,
    which is how ConsoleLying tile=open_prs false-fired every cache window
    (11 vs 15 on 2026-09-10T21:54Z, tile faithful to a 9-minute-old snapshot).
    """
    repo = _spot_repo(tile)
    displayed = _item_count_for_repo(tile, repo)
    if displayed is None:
        raise VerifyError(f"no items entry for {repo}")
    at = tile.get("observed_at")
    if not isinstance(at, (int, float)):
        raise VerifyError("tile has no observed_at; cannot bound the window")
    since = datetime.fromtimestamp(float(at), timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%S+00:00"
    )
    live = _gh_search_count(f"repo:{repo} is:open")
    opened = _gh_search_count(f"repo:{repo} is:open created:>={since}")
    closed = _gh_search_count(
        f"repo:{repo} is:closed created:<{since} closed:>={since}"
    )
    return live, displayed, repo, {
        "mode": "window",
        "down": opened + SEARCH_INDEX_FLOOR,
        "up": closed + SEARCH_INDEX_FLOOR,
    }


def run_shipped_gh_spot(tile):
    repo = _spot_repo(tile)
    displayed = _item_count_for_repo(tile, repo)
    if displayed is None:
        raise VerifyError(f"no items entry for {repo}")
    since = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime(
        "%Y-%m-%dT%H:%M:%S+00:00"
    )
    # fleet-ops#4061: count NON-revert merges so the spot cross-check agrees
    # with the tile's definition (fleet_product_merged_24h). A raw total_-
    # count includes revert PRs and chronically false-DISPUTEs the tile.
    # _is_revert_title must stay symmetric with lib/fleet-product-slo.py
    # is_revert()'s title conventions (incl. the lowercase `revert:` the
    # auto-restore bot uses) or a faithful tile false-DISPUTEs.
    n = _gh_search_nonrevert_count(f"repo:{repo} is:merged merged:>={since}")
    return n, displayed, repo


RUNNERS = {
    "open_prs_prom": run_open_prs_prom,
    "shipped_prom": run_shipped_prom,
    "outcome_prom": run_outcome_prom,
    "main_ci_prom": run_main_ci_prom,
    "alerts_prom": run_alerts_prom,
    "repairs_units": run_repairs_units,
    "running_pi_execstart": run_running_pi_execstart,
    "fleet_paused": run_fleet_paused,
    "findings_ledger": run_findings_ledger,
    "questions_gh": run_questions_gh,
    "open_prs_gh_spot": run_open_prs_gh_spot,
    "shipped_gh_spot": run_shipped_gh_spot,
}


def _as_number(value, field):
    if field == "paused":
        if isinstance(value, bool):
            return 1 if value else 0
        return int(value)
    if value is None:
        raise VerifyError(f"tile field {field} is missing")
    return float(value)


def _within(displayed, observed, tolerance):
    mode = (tolerance or {}).get("mode", "exact")
    if mode == "exact":
        return int(round(displayed)) == int(round(observed))
    if mode == "percent":
        pct = float(tolerance.get("pct", 0))
        if displayed == 0 and observed == 0:
            return True
        # Absolute floor of 2 so a 2-vs-3 cache lag on a small repo is not
        # a lie. Percent still catches a 10-vs-20 class error.
        delta = abs(displayed - observed)
        if delta <= 2:
            return True
        denom = max(abs(displayed), abs(observed), 1.0)
        return delta / denom * 100.0 <= pct
    if mode == "window":
        # fleet-ops#5155: a cached level has no single truth to compare
        # against at verify time. `displayed` was measured earlier, so it may
        # trail the live count by everything opened since then (`down`) and
        # may exceed it by everything closed since then (`up`). Inside that
        # window the tile is consistent with its own source; outside it, it
        # is wrong by more than the cache can explain.
        return (observed - float(tolerance.get("down", 0))
                <= displayed
                <= observed + float(tolerance.get("up", 0)))
    raise VerifyError(f"unknown tolerance mode {mode}")


# The gh search index trails the live API by seconds-to-minutes, and the tile
# and the verifier read the clock on either side of a push cycle. Both are
# noise around a window bound, never evidence of a lie (fleet-ops#5155).
SEARCH_INDEX_FLOOR = 2


def _inject(doc, specs):
    """Apply tile.field=value overlays (drill)."""
    tiles = doc.setdefault("tiles", {})
    for spec in specs:
        if not spec or "=" not in spec:
            continue
        left, raw = spec.split("=", 1)
        if "." not in left:
            continue
        tile_name, field = left.split(".", 1)
        tile = tiles.setdefault(tile_name, {})
        if raw.lower() in ("true", "false"):
            value = raw.lower() == "true"
        else:
            try:
                value = int(raw)
            except ValueError:
                try:
                    value = float(raw)
                except ValueError:
                    value = raw
        tile[field] = value
        tile["ok"] = True
        tile.setdefault("observed_at", time.time())
        tile.setdefault("stale_after_s", 900)
        tile.setdefault("source", "inject")


def verify_tile(name, tile):
    """Return (mismatch:int, tile_mutated). Unknown/stale tiles are not lies."""
    spec = SPECS.get(name)
    if spec is None:
        tile["verify"] = {"cmd": None, "skipped": "no spec"}
        tile["disputed"] = False
        return 0

    attach_specs({"tiles": {name: tile}})
    verify = tile["verify"]

    if not tile.get("ok") or tile.get("observed_at") is None:
        verify["skipped"] = "tile unknown or stale (a dash is not a lie)"
        tile["disputed"] = False
        return 0

    field = spec["field"]
    try:
        displayed = _as_number(tile.get(field), field)
    except VerifyError as e:
        verify["error"] = str(e)
        verify["match"] = False
        tile["disputed"] = True
        return 1

    mismatch = 0
    reasons = []

    try:
        observed = RUNNERS[spec["runner"]](tile)
        observed_n = float(observed)
        verify["displayed"] = displayed
        verify["observed"] = observed_n
        if not _within(displayed, observed_n, spec["tolerance"]):
            mismatch = 1
            reasons.append(
                f"{field} displayed {displayed} vs verify {observed_n}"
            )
            verify["match"] = False
        else:
            verify["match"] = True
    except VerifyError as e:
        # fleet-ops#2690: a race between generate.py and verify.py (textfile
        # mtime advanced past tile.observed_at) raises VerifyError from
        # run_shipped_prom so the same-source Prom check does not falsely
        # DISPUTE on a timing artifact. The gh spot check still runs and
        # is the real cross-check. Treat it as a skip: mismatch stays 0,
        # but record the reason so the canary sees it.
        if "race" in str(e).lower():
            verify["skipped"] = str(e)
            verify["match"] = None
        else:
            verify["error"] = str(e)
            verify["match"] = False
            mismatch = 1
            reasons.append(f"verify failed: {e}")

    spot = spec.get("spot")
    if spot and not SKIP_GH:
        try:
            result = RUNNERS[spot["runner"]](tile)
            observed, spot_displayed, repo = result[:3]
            tolerance = result[3] if len(result) > 3 else spot["tolerance"]
            verify["spot_repo"] = repo
            verify["spot_displayed"] = spot_displayed
            verify["spot_observed"] = float(observed)
            if not _within(float(spot_displayed), float(observed),
                           tolerance):
                mismatch = 1
                reasons.append(
                    f"spot {repo} displayed {spot_displayed} vs gh {observed}"
                )
                verify["spot_match"] = False
            else:
                verify["spot_match"] = True
        except VerifyError as e:
            # Transport blip: SKIP the extra, do not DISPUTE on it.
            verify["spot_skipped"] = str(e)
            verify["spot_match"] = None

    tile["disputed"] = bool(mismatch)
    if reasons:
        verify["reason"] = "; ".join(reasons)
    return mismatch


def write_prom(results, ts):
    lines = [HELP_MISMATCH, TYPE_MISMATCH]
    for name in sorted(SPECS):
        val = int(results.get(name, 0))
        lines.append(f'fleet_console_tile_mismatch{{tile="{name}"}} {val}')
    lines.append(HELP_TS)
    lines.append(TYPE_TS)
    lines.append(f"fleet_console_tile_verify_timestamp_seconds {ts:.0f}")
    lines.append("")
    _atomic_write(PROM_OUT, "\n".join(lines))


def run(data_path=None, inject=None):
    path = Path(data_path) if data_path else DATA_JSON
    doc = json.loads(path.read_text(encoding="utf-8"))
    if inject:
        _inject(doc, inject)
    attach_specs(doc)
    results = {}
    for name in SPECS:
        tile = doc.setdefault("tiles", {}).setdefault(name, {})
        results[name] = verify_tile(name, tile)
    ts = time.time()
    doc["verified_at"] = datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%S+00:00"
    )
    doc["tile_mismatches"] = results
    _atomic_write(path, json.dumps(doc, indent=2) + "\n")
    write_prom(results, ts)
    disputed = [k for k, v in results.items() if v]
    print(
        f"verify {doc['verified_at']} disputed={disputed or 'none'} "
        f"prom={PROM_OUT}"
    )
    return results


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    data = None
    inject = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--data":
            i += 1
            data = argv[i]
        elif a == "--prom-out":
            i += 1
            global PROM_OUT
            PROM_OUT = Path(argv[i])
        elif a == "--inject":
            i += 1
            inject.append(argv[i])
        elif a == "--skip-gh":
            global SKIP_GH
            SKIP_GH = True
        elif a in ("-h", "--help"):
            print(
                "usage: verify.py [--data PATH] [--prom-out PATH] "
                "[--inject tile.field=value] [--skip-gh]"
            )
            return 0
        else:
            print(f"verify.py: unknown arg {a}", file=sys.stderr)
            return 2
        i += 1
    run(data_path=data, inject=inject or None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
