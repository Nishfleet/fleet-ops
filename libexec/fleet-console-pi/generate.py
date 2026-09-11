#!/usr/bin/env python3
"""Fleet Console (Pi) — live-truth generator.

Tiles pull from the shared monitoring plane: Prometheus on 127.0.0.1:9090
for merged PRs, open PRs, main-branch CI, repair dispatches, and firing
alerts; pi-seat-health.json plus live transient systemd units for PI WORK
and repairs-in-flight. Every metric tile makes zero GitHub API calls.

The one exception is the `questions` tile (fleet-ops#4475): the questions
store IS an open GitHub issue with the `question` label, so it reads GitHub
directly (via `gh`) and fails closed to source-unavailable on any error.

Every tile carries a freshness contract (observed_at + stale_after_s +
source + explain). A missing or stale metric renders unknown (the shell
shows "—"), never a frozen last value and never a coerced zero.
"""
import http.client
import json
import math
import os
import re
import subprocess
import calendar
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

ORG = "Nishfleet"
# Path(__file__).parent (not resolve): when this file is a MANIFEST symlink
# under ~/.local/libexec/..., data.json must land next to the symlink, not
# inside the git checkout that resolve() would follow.
OUT_JSON = Path(
    os.environ.get(
        "CONSOLE_DATA_JSON",
        str(Path(__file__).parent / "data.json"),
    )
)
CADENCE_MIN = 12
PROM = "http://127.0.0.1:9090"
PROM_STALE_S = 15 * 60          # exporter fires every 5 min; 2+ misses = stale
# The exporter serves fleet_open_prs / fleet_main_ci_green from a cached org
# GraphQL snapshot (fleet-metrics-export.py PR_CACHE_TTL = 30 min). A tile
# rendered from those families is as old as that CACHE, not as old as the
# export, so it keeps the cache window as its freshness gate — and stamps
# fleet_gh_cache_timestamp_seconds as its observed_at (fleet-ops#5155).
GH_CACHE_WINDOW_S = 30 * 60
SEAT_STALE_S = 30 * 60
PROC_STALE_S = 5 * 60
# Questions tile (part 2 of the 2026-09-08 decision). Cadence is 12 min;
# a question must appear within one cadence of its label, so 2.5 cycles is
# a generous freshness window that still fails closed on a frozen query.
QUESTION_STALE_S = 30 * 60
# An `answered` question is kept on the tab for 24h after its answer, then
# dropped (its decision-resolved: comment is the answer; it re-queues via
# blocked-reconcile). Older than this it must not render.
ANSWERED_KEEP_S = 24 * 60 * 60
# `gh search issues` defaults to --limit 30 and reports nothing when it
# truncates (fleet-ops#5133), so a 31-question backlog silently lost row 31
# and the tile's count/items were a capped window. Ask for GitHub's own search
# ceiling explicitly — gh pages internally up to whatever --limit says — and
# flag the tile when the result fills that window. Mirrored in verify.py
# (same constant, same --limit) so the tile and its verifier see the SAME
# window; a boundary population fetched by two different windows is the
# false-DISPUTE class #5070 fixed for the 24h exclusion.
QUESTION_SEARCH_LIMIT = 1000
# Labels a question must carry for its ask to have passed the senior
# conference gate (fleet-ops#4474): conference-approved or the older
# nish-reserved both mean "worth bothering Nish".
FOR_NISH_LABELS = ("conference-approved", "nish-reserved")
REPAIR_STALE_S = 20 * 60       # >1.5 push cycles (CADENCE_MIN=12); younger renders, older renders —
FLEET_STALE_S = 60 * 60
FLEET_PAUSED_MARKER = Path("/home/nish/workspaces/agent-state/FLEET-PAUSED")
SEAT_HEALTH = Path("/home/nish/workspaces/agent-state/lanes/pi-seat-health.json")
# Per-seat health ledger dir; the wrapper's clobber-proof bench marker for a
# seat is <sanitised-provider>__<sanitised-model>.spawn-bench.json inside it
# (lib/seat-lib.sh seat_spawn_bench_path).
SEAT_LEDGER = Path("/home/nish/workspaces/agent-state/lanes/seats")
# Canonical findings ledger (fleet-ops#5443, ported in fleet-ops#5476):
# every finding queued and never dropped silently. The vault jsonl IS the
# truth — the tile reads it directly, no second copy. Mirrored in
# verify.py (same env override) so tile and verifier read the SAME file.
FINDINGS_LEDGER = Path(os.environ.get(
    "FINDINGS_LEDGER",
    "/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/findings-ledger.jsonl"))
# The ledger is a local file re-read every cycle; 2.5 cycles is the same
# generous fail-closed window the questions tile uses.
FINDINGS_STALE_S = 30 * 60
XDG = f"/run/user/{os.getuid()}"


class PromError(Exception):
    """Prometheus HTTP API failed (down, timeout, non-success)."""


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")


def _tile(source, stale_s, ok, observed_at, **data):
    t = {"source": source, "stale_after_s": stale_s, "ok": bool(ok),
         "observed_at": observed_at}
    t.update(data)
    return t


def _unknown(source, stale_s, reason, explain=None):
    kw = {"reason": reason}
    if explain:
        kw["explain"] = explain
    return _tile(source, stale_s, False, None, **kw)


def _loopback_json(url, timeout=5):
    """GET JSON from a loopback HTTP URL via http.client (no urllib)."""
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or ""
    if host not in ("127.0.0.1", "localhost", "::1"):
        raise PromError(f"refusing non-loopback host {host!r}")
    path = parsed.path or "/"
    if parsed.query:
        path = path + "?" + parsed.query
    conn = http.client.HTTPConnection(host, parsed.port or 80, timeout=timeout)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read()
        if resp.status >= 400:
            raise PromError(f"http {resp.status}")
        return json.loads(body)
    except (OSError, TimeoutError, json.JSONDecodeError, ValueError,
            http.client.HTTPException) as exc:
        raise PromError(str(exc)[:160]) from exc
    finally:
        conn.close()


def _prom_query(expr, timeout=5):
    """Instant query. Returns [{metric, value}] or raises PromError.

    An empty list means the query succeeded and matched no series (family
    omitted, or a true zero with no per-repo samples).
    """
    url = PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    payload = _loopback_json(url, timeout=timeout)
    if payload.get("status") != "success":
        raise PromError(f"prom status={payload.get('status')}")
    rows = []
    for item in (payload.get("data") or {}).get("result") or []:
        try:
            val = float(item["value"][1])
        except (KeyError, IndexError, TypeError, ValueError) as exc:
            raise PromError(f"bad sample: {exc}") from exc
        rows.append({"metric": item.get("metric") or {}, "value": val})
    return rows


def _prom_alerts(timeout=5):
    url = PROM + "/api/v1/alerts"
    payload = _loopback_json(url, timeout=timeout)
    if payload.get("status") != "success":
        raise PromError(f"prom alerts status={payload.get('status')}")
    return (payload.get("data") or {}).get("alerts") or []


def _textfile_mtime():
    """Epoch seconds of fleet.prom last write, or None if the series is absent.

    Raises PromError when Prometheus itself is unreachable.
    """
    rows = _prom_query('node_textfile_mtime_seconds{file=~".*fleet.prom"}')
    if not rows:
        return None
    return max(r["value"] for r in rows)


def _seat_quota_info(provider, timeout=5):
    """Query Prometheus for fleet_seat_quota_* rows for one provider.

    Returns a dict with 'rows' (list of {window, remaining_pct, reset_s})
    and 'source' (api/dashboard/stale).  Returns None on any error
    (Prometheus down, no series for this provider) — the caller treats
    None as 'no quota data available' and the tile still renders.
    """
    if not provider:
        return None
    try:
        pct_rows = _prom_query(
            f'fleet_seat_quota_remaining_pct{{provider="{provider}"}}',
            timeout=timeout,
        )
        reset_rows = _prom_query(
            f'fleet_seat_quota_reset_seconds{{provider="{provider}"}}',
            timeout=timeout,
        )
    except PromError:
        return None
    if not pct_rows:
        return None
    # Index reset rows by window for joining
    reset_by_window = {}
    for r in reset_rows:
        w = r["metric"].get("window", "")
        reset_by_window[w] = r["value"]
    rows = []
    source = ""
    for r in pct_rows:
        w = r["metric"].get("window", "")
        source = r["metric"].get("source", "")
        rows.append({
            "window": w,
            "remaining_pct": round(r["value"], 1),
            "reset_s": round(reset_by_window.get(w, 0)),
        })
    return {"rows": rows, "source": source}


def _cache_fresh(kind):
    """True when exporter emitted fleet_gh_cache_fresh{kind=...} = 1."""
    rows = _prom_query(f'fleet_gh_cache_fresh{{kind="{kind}"}}')
    return bool(rows) and any(r["value"] == 1 for r in rows)


def _cache_data_time(kind, fallback):
    """Epoch when the cached gh family's data was MEASURED, or `fallback`.

    A tile fed by a cached family must stamp the measurement time, not the
    export time: the exporter refreshes these caches at most every 30 min, so
    stamping the export time shows a half-hour-old count as seconds-fresh
    (fleet-ops#5155: ConsoleLying tile=open_prs, where the tile said 11
    open PRs while 15 were open and the verify's live gh spot check read the
    difference as a lie). Fail open to `fallback` when the gauge is absent.
    """
    try:
        rows = _prom_query(
            f'fleet_gh_cache_timestamp_seconds{{kind="{kind}"}}'
        )
    except PromError:
        return fallback
    if not rows:
        return fallback
    return float(rows[0]["value"])


def _prom_or_stale(source, explain):
    """Shared gate: Prom reachable, fleet.prom fresh enough to trust."""
    try:
        mtime = _textfile_mtime()
    except PromError as e:
        return None, _unknown(source, PROM_STALE_S, f"Prometheus unreachable: {e}",
                              explain=explain)
    if mtime is None:
        return None, _unknown(source, PROM_STALE_S,
                              "fleet.prom mtime absent from Prometheus",
                              explain=explain)
    age = time.time() - mtime
    if age > PROM_STALE_S:
        return None, _unknown(
            source, PROM_STALE_S,
            f"fleet.prom stale ({int(age)}s old; exporter likely frozen)",
            explain=explain,
        )
    return mtime, None


def _product_slo_mtime():
    """Epoch of the product-slo textfile (or its heartbeat), or None.

    fleet-ops#2755 / #2690: shipped_24h reads fleet_product_merged_24h from
    fleet-product-slo.prom (not the org-wide fleet_merged_prs_24h in
    fleet.prom). Freshness therefore keys on that textfile / heartbeat.
    """
    rows = _prom_query(
        'node_textfile_mtime_seconds{file=~".*fleet-product-slo.prom"}'
    )
    if rows:
        return max(r["value"] for r in rows)
    hb = _prom_query("fleet_product_slo_last_run_seconds")
    if hb:
        return max(r["value"] for r in hb)
    return None


def collect_shipped():
    src = "prometheus:fleet_product_merged_24h"
    explain = ("Prometheus fleet_product_merged_24h, trailing 24h non-revert "
               "merges for product repos (intake-repos minus self-maintenance). "
               "Single source of truth for product delivery "
               "(fleet-ops#2755 / #2690). Written by lib/fleet-product-slo.py "
               "on the metrics-export tick.")
    try:
        mtime = _product_slo_mtime()
    except PromError as e:
        return _unknown(src, PROM_STALE_S,
                        f"Prometheus unreachable: {e}", explain=explain)
    if mtime is None:
        return _unknown(src, PROM_STALE_S,
                        "product-slo metrics absent from Prometheus",
                        explain=explain)
    age = time.time() - mtime
    if age > PROM_STALE_S:
        return _unknown(
            src, PROM_STALE_S,
            f"product-slo.prom stale ({int(age)}s old; exporter likely frozen)",
            explain=explain,
        )
    try:
        rows = _prom_query("fleet_product_merged_24h")
    except PromError as e:
        return _unknown(src, PROM_STALE_S, f"query failed: {e}", explain=explain)
    items = []
    total = 0
    for r in rows:
        repo = r["metric"].get("repo") or ""
        n = int(r["value"])
        total += n
        if repo:
            # Short name from the product-slo exporter; expand for spot checks.
            full = repo if "/" in repo else f"{ORG}/{repo}"
            items.append({"repo": full, "count": n})
    items.sort(key=lambda x: (-x["count"], x["repo"]))
    # fleet-ops#3984: surface the org-wide trailing-24h merge total (all
    # repos incl. fleet-ops) as a secondary line so the product-only number
    # is not read as org-wide. fleet_merged_prs_24h is the org-wide family
    # in fleet.prom; when it is absent, hide the secondary line (None).
    org_total = 0
    try:
        for r in _prom_query("fleet_merged_prs_24h"):
            org_total += int(r["value"])
    except PromError:
        org_total = None
    return _tile(src, PROM_STALE_S, True, mtime, count=total, items=items,
                 org_total=org_total, explain=explain)


def collect_outcome():
    src = "prometheus:fleet_product_signups_24h+fleet_signups_7d+fleet_product_activated_24h+fleet_product_paying_customers_total"
    explain = (
        "Product outcome from the 0509 D1 gauges (users created, first "
        "brief delivered, non-free plan): signups 24h/7d, activated 24h, "
        "paying customers. fleet.prom carries signups_7d; "
        "fleet-product-slo.prom carries the other three. Any absent gauge "
        "renders unknown (a dash), never 0. Top of funnel is UNMEASURED. "
    )
    # fleet.prom gate: fleet_signups_7d lives there, so its freshness is a
    # precondition for the whole funnel reading.
    mtime, err = _prom_or_stale(src, explain)
    if err:
        return err
    try:
        pmtime = _product_slo_mtime()
    except PromError as e:
        return _unknown(src, PROM_STALE_S, f"Prometheus unreachable: {e}",
                        explain=explain)
    if pmtime is None:
        return _unknown(src, PROM_STALE_S,
                        "product-slo metrics absent from Prometheus",
                        explain=explain)
    age = time.time() - pmtime
    if age > PROM_STALE_S:
        return _unknown(
            src, PROM_STALE_S,
            f"product-slo.prom stale ({int(age)}s old; exporter likely frozen)",
            explain=explain,
        )
    # Each gauge is queried on its own: an unreadable source OMITS its family
    # (a healthy empty table exports an explicit 0), so no rows means the
    # number is unmeasured, never 0. "0 signups" and "signups not measured"
    # must never look the same (fleet-ops#5003 accept bullet 2).
    values = {}
    for field, gauge in (
        ("signups_24h", "fleet_product_signups_24h"),
        ("signups_7d", "fleet_signups_7d"),
        ("activated_24h", "fleet_product_activated_24h"),
        ("paying_customers", "fleet_product_paying_customers_total"),
    ):
        try:
            rows = _prom_query(f"sum({gauge})")
        except PromError as e:
            return _unknown(src, PROM_STALE_S, f"query failed: {e}",
                            explain=explain)
        if not rows:
            return _unknown(
                src, PROM_STALE_S,
                f"{gauge} gauge absent (source unreadable) — not a zero",
                explain=explain,
            )
        # Rows present, but the sample itself may be nan/inf (a broken
        # exporter write). int(nan) raises ValueError, int(inf) raises
        # OverflowError; either escaping here would kill the whole
        # generate run. Fail this tile closed to unknown instead —
        # "unreadable" must never render as 0 (fleet-ops#5003).
        try:
            total = sum(r["value"] for r in rows)
            if not math.isfinite(total):
                raise ValueError(f"non-finite sample {total}")
            values[field] = int(total)
        except (ValueError, OverflowError) as exc:
            return _unknown(
                src, PROM_STALE_S,
                f"{gauge} gauge unreadable: {exc}",
                explain=explain,
            )
    # Anchor on the product-slo mtime, NOT min(mtime, pmtime). The tile stays
    # gated on BOTH sources — the `_prom_or_stale` call above already returns
    # an unknown tile when fleet.prom is stale, so `mtime` is still
    # load-bearing — but the freshness ANCHOR must be the product-slo mtime,
    # because that is the value verify.py:_race_against_tile compares against.
    # With min(...), an older fleet.prom makes the verifier SKIP on that tick
    # and a lying tile escapes instead of DISPUTING.
    return _tile(
        src, PROM_STALE_S, True, pmtime,
        count=values["signups_24h"],
        funnel=("top of funnel UNMEASURED (no visit/page-view gauge "
                "exists; Nishfleet/0509#2120)"),
        explain=explain,
        **values,
    )


def collect_open_prs():
    src = "prometheus:fleet_open_prs"
    explain = ("Prometheus fleet_open_prs, current open-PR count per repo "
               "from a cached org GraphQL snapshot ≤30 min; cache older "
               "than 2h omits the family (never a frozen value).")
    mtime, err = _prom_or_stale(src, explain)
    if err:
        return err
    try:
        fresh = _cache_fresh("repo_snapshot")
        rows = _prom_query("fleet_open_prs")
    except PromError as e:
        return _unknown(src, PROM_STALE_S, f"query failed: {e}", explain=explain)
    if not fresh:
        return _unknown(src, PROM_STALE_S,
                        "metric family absent (exporter omitted stale cache)",
                        explain=explain)
    items = []
    total = 0
    for r in rows:
        repo = r["metric"].get("repo") or ""
        n = int(r["value"])
        total += n
        if repo:
            items.append({"repo": repo, "count": n})
    items.sort(key=lambda x: (-x["count"], x["repo"]))
    return _tile(src, GH_CACHE_WINDOW_S, True,
                 _cache_data_time("repo_snapshot", mtime),
                 count=total, items=items, explain=explain)


def collect_main_ci():
    src = "prometheus:fleet_main_ci_green"
    explain = ("Prometheus fleet_main_ci_green, default-branch check rollup: "
               "1=SUCCESS (green), 0=FAILURE/ERROR (MAIN RED). Pending/"
               "unknown rollups omitted. Cached org GraphQL snapshot ≤30 min; "
               "cache older than 2h omits the family (never a frozen value).")
    mtime, err = _prom_or_stale(src, explain)
    if err:
        return err
    try:
        fresh = _cache_fresh("repo_snapshot")
        rows = _prom_query("fleet_main_ci_green")
    except PromError as e:
        return _unknown(src, PROM_STALE_S, f"query failed: {e}", explain=explain)
    if not fresh:
        return _unknown(src, PROM_STALE_S,
                        "metric family absent (exporter omitted stale cache)",
                        explain=explain)
    items = []
    red = 0
    for r in rows:
        repo = r["metric"].get("repo") or ""
        green = int(r["value"])
        if not repo:
            continue
        items.append({"repo": repo, "green": green})
        if green == 0:
            red += 1
    items.sort(key=lambda x: (x["green"], x["repo"]))
    return _tile(src, GH_CACHE_WINDOW_S, True,
                 _cache_data_time("repo_snapshot", mtime),
                 red_count=red, items=items, explain=explain)


def collect_firing_alerts():
    src = "prometheus:/api/v1/alerts"
    explain = ("Prometheus HTTP API /api/v1/alerts, currently firing, "
               "Watchdog (dead-man heartbeat) excluded. This is live "
               "Alertmanager state, not a scraped gauge.")
    try:
        alerts = _prom_alerts()
    except PromError as e:
        return _unknown(src, PROM_STALE_S, f"alerts API failed: {e}",
                        explain=explain)
    items = []
    for a in alerts:
        if a.get("state") != "firing":
            continue
        name = (a.get("labels") or {}).get("alertname") or ""
        if name == "Watchdog":
            continue
        sev = (a.get("labels") or {}).get("severity") or ""
        items.append({"alertname": name, "severity": sev,
                      "labels": a.get("labels") or {}})
    items.sort(key=lambda x: x["alertname"])
    return _tile(src, PROM_STALE_S, True, time.time(), count=len(items),
                 items=items, explain=explain)


def _running_units():
    env = dict(os.environ, XDG_RUNTIME_DIR=XDG)
    out = subprocess.run(
        ["systemctl", "--user", "list-units", "--type=service",
         "--state=running,activating", "--no-legend", "--plain"],
        capture_output=True, text=True, timeout=8, env=env,
    )
    if out.returncode != 0:
        raise RuntimeError(f"list-units rc={out.returncode}")
    names = []
    for ln in (out.stdout or "").splitlines():
        name = ln.split()[0] if ln.split() else ""
        if name:
            names.append(name)
    return names


def _is_transient(unit):
    env = dict(os.environ, XDG_RUNTIME_DIR=XDG)
    out = subprocess.run(
        ["systemctl", "--user", "show", "-p", "Transient", "--value", unit],
        capture_output=True, text=True, timeout=5, env=env,
    )
    return (out.stdout or "").strip() == "yes"


def _invokes_pi_print(unit):
    """True iff the unit's ExecStart invokes `pi --print`.

    Never a unit-name prefix (fleet-ops#1155). ExecStart is the honest
    signal: a fleet worker runs `pi --print`.
    """
    env = dict(os.environ, XDG_RUNTIME_DIR=XDG)
    out = subprocess.run(
        ["systemctl", "--user", "show", "-p", "ExecStart", "--value", unit],
        capture_output=True, text=True, timeout=5, env=env,
    )
    execstart = out.stdout or ""
    # fleet-ops#1451: issue workers exec via the pi-issue-run wrapper; its
    # ExecStart path is as honest a pi-invocation signal as a literal
    # `pi --print` (still ExecStart-based, never a unit-name prefix — #1155).
    return ("pi --print" in execstart) or ("/pi-issue-run " in execstart) or ("/pi-issue-start" in execstart)


def _pi_argv_count():
    """Count /proc PIDs whose argv is the pi binary plus --print.

    Never substring-match a command line. Independent of the unit
    count; the tile's headline number is the ExecStart unit count.
    """
    n = 0
    try:
        entries = os.listdir("/proc")
    except OSError:
        return 0
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            raw = Path(f"/proc/{entry}/cmdline").read_bytes()
        except OSError:
            continue
        if not raw:
            continue
        argv = raw.split(b"\x00")
        if argv and argv[-1] == b"":
            argv = argv[:-1]
        decoded = []
        for a in argv:
            try:
                decoded.append(a.decode("utf-8", "replace"))
            except Exception:
                decoded.append("")
        has_pi = any(x == "pi" or x.endswith("/pi") for x in decoded)
        if has_pi and "--print" in decoded:
            n += 1
    return n


def collect_repairs_inflight():
    src = "systemd:alert-repair-* transients + prometheus:fleet_repair_dispatch_24h"
    explain = ("Repairs in flight: running transient systemd units named "
               "alert-repair-*. Subtitle is Prometheus fleet_repair_dispatch_24h "
               "(DISPATCH lines in alert-repair/actions.log, trailing 24h).")
    try:
        names = [n for n in _running_units()
                 if n.startswith("alert-repair-") and _is_transient(n)]
    except Exception as e:
        return _unknown(src, REPAIR_STALE_S, f"systemctl failed: {str(e)[:120]}",
                        explain=explain)
    dispatch_24h = None
    try:
        mtime, err = _prom_or_stale("prometheus:fleet_repair_dispatch_24h",
                                    explain)
        if not err:
            rows = _prom_query("fleet_repair_dispatch_24h")
            if rows:
                dispatch_24h = int(sum(r["value"] for r in rows))
    except PromError:
        dispatch_24h = None
    return _tile(src, REPAIR_STALE_S, True, time.time(), count=len(names),
                 units=names[:20], dispatch_24h=dispatch_24h, explain=explain)


# fleet-ops#3737: freshness window for an expired spawn-bench marker that
# still gates the seat. Matches EMPTY_RUN_COUNT_WINDOW_S / SEAT_PARK_WALL_S
# in lib/seat-lib.sh and SPAWN_BENCH_FRESH_S in
# libexec/fleet-metrics-export.py (24 h). Older than this the marker is
# archaeology and fail-open.
_SEAT_BENCH_FRESH_S = 86400
# Failure ceilings mirror lib/seat-lib.sh seat_usable(): a spawn_fail (or
# any non-empty_run) seat parks past 20 consecutive failures; an empty run
# parks past 5. Used by the fleet-ops#3828 ceiling fence below.
_SEAT_FAILURE_CEILING = 20
_EMPTY_RUN_FAILURE_CEILING = 5


def _seat_bench_held(provider, model):
    """True if the seat's wrapper spawn-bench marker is held right now.

    fleet-ops#3563: mark_seat_empty_run / mark_seat_spawn_fail write a
    clobber-proof marker (<p>__<m>.spawn-bench.json) beside the per-seat
    ledger whenever they bench a seat. The sidecar can be rewritten healthy
    by a later extension observation while the marker still holds; the tile
    must agree with the router (seat_usable honours the marker), so a held
    marker means "not healthy" here. Never raises; a missing, unreadable,
    or expired marker is False.

    fleet-ops#3795: seat_usable holds the bench in TWO cases —
      (a) usable_at strictly in the future (the active bench), or
      (b) usable_at expired/absent BUT the marker is FRESH (written within
          _SEAT_BENCH_FRESH_S) and still the seat's latest evidence: no
          sibling-ledger observed_at newer than written_at. A later ledger
          observation is post-bench evidence — a run that produced output
          writes healthy with no following marker — so case (b) releases on
          it; otherwise the comeback organ probes the seat before
          re-admission and the tile must agree the seat is not healthy
          while it is probe-gated. Without case (b) a clobbered-healthy
          sidecar renders an unprobed dead-weight seat as healthy (the
          ollama/<retired-V4-flash> empty-run churn this issue names:
          25 no-ops in 2h while the census said healthy). Mirrors
          _spawn_bench_marker_held in libexec/fleet-metrics-export.py.

    fleet-ops#3828 (mirror of the #3889/#3826 fences in
    _spawn_bench_marker_held and seat_usable): the bench is held in TWO
    more cases the clock rules miss, so the console tile never renders a
    seat the router excludes as "healthy". (1) corpse fence: a marker-
    declared corpse (seat_dead=true, a chronic spawn_fail past the corpse
    threshold) is held terminally, regardless of usable_at or a later
    false-healthy ledger clobber — only a recovery probe
    (source=comeback_release) releases it. (2) ceiling fence: a FRESH
    marker whose count is at/past the failure ceiling (20 for spawn_fail,
    5 for empty_run) stays held even when the sibling ledger carries a
    NEWER healthy observation (the after_provider_response 200 that
    carries status+headers only, never the exit rc), unless
    source=comeback_release.
    """
    if not isinstance(provider, str) or not provider:
        return False
    if not isinstance(model, str) or not model:
        return False
    safe_p = re.sub(r"[^A-Za-z0-9._-]", "_", provider)
    safe_m = re.sub(r"[^A-Za-z0-9._-]", "_", model)
    marker_path = SEAT_LEDGER / f"{safe_p}__{safe_m}.spawn-bench.json"
    try:
        marker = json.loads(marker_path.read_text())
    except (OSError, json.JSONDecodeError):
        return False
    if not isinstance(marker, dict):
        return False
    now = int(time.time())
    # Sibling per-seat ledger: both the false-healthy clobber target and
    # the recovery authority (a comeback-release probe writes source on it).
    ledger_path = SEAT_LEDGER / f"{safe_p}__{safe_m}.json"
    ledger_src = ""
    try:
        led = json.loads(ledger_path.read_text())
        if isinstance(led, dict):
            ledger_src = led.get("source") or ""
    except (OSError, json.JSONDecodeError):
        led = {}
    # fleet-ops#3889 corpse fence: terminal until a real recovery probe
    # (source=comeback_release) re-writes the ledger. Mirrors seat_usable —
    # no usable_at or marker-age bound, the corpse hold is durable.
    if marker.get("seat_dead") is True:
        if ledger_src != "comeback_release":
            return True
        # Recovered corpse: fall through — the fresh ledger observation now
        # decides (seat_usable drops the corpse hold the same way).
    usable_at = marker.get("usable_at")
    if isinstance(usable_at, str) and usable_at:
        try:
            # UTC parse via calendar.timegm (process TZ is +05:30 on the
            # live host; mktime would misread a future-Z as past and drop
            # the overlay).
            usable_epoch = calendar.timegm(time.strptime(
                usable_at.replace("Z", "")[:19], "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            usable_epoch = None
        if usable_epoch is not None and usable_epoch > now:
            return True
    # Case (b): expired or clockless bench — held only while the marker is
    # fresh and remains the seat's latest evidence.
    written_at = marker.get("written_at")
    if not isinstance(written_at, str) or not written_at:
        return False
    try:
        written_epoch = calendar.timegm(time.strptime(
            written_at.replace("Z", "")[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return False
    if now - written_epoch > _SEAT_BENCH_FRESH_S:
        return False
    obs_epoch = None
    if isinstance(led, dict):
        obs = led.get("observed_at")
        if isinstance(obs, str) and obs:
            try:
                obs_epoch = calendar.timegm(time.strptime(
                    obs.replace("Z", "")[:19], "%Y-%m-%dT%H:%M:%S"))
            except ValueError:
                obs_epoch = None
    if obs_epoch is None or obs_epoch <= written_epoch:
        return True
    # fleet-ops#3826 ceiling fence: a NEWER healthy observation is the
    # false-healthy clobber, not recovery, for a ceiling-parked seat.
    mcount = marker.get("consecutive_failure_count") or 0
    if not isinstance(mcount, int) or isinstance(mcount, bool):
        try:
            mcount = int(mcount)
        except (TypeError, ValueError):
            mcount = 0
    mmode = marker.get("failure_mode") or ""
    _ceil = (
        _EMPTY_RUN_FAILURE_CEILING if mmode == "empty_run"
        else _SEAT_FAILURE_CEILING
    )
    if mcount >= _ceil and ledger_src != "comeback_release":
        return True
    return False


def collect_running_pi():
    src = ("systemd: running user units whose ExecStart contains "
           "'pi --print'")
    explain = ("PI WORK: count of running systemd user units whose "
               "ExecStart contains `pi --print` (systemctl --user show "
               "-p ExecStart over running units — never a unit-name "
               "pattern; fleet-ops#1155). Subtitle is /proc argv count of "
               "the pi binary plus --print (independent, not added). Seat "
               "health_class from agent-state/lanes/pi-seat-health.json. "
               "Quota remaining % from fleet_seat_quota_remaining_pct "
               "(fleet-ops#4217) for the current seat's provider.")
    try:
        data = json.loads(SEAT_HEALTH.read_text())
    except (OSError, json.JSONDecodeError) as e:
        return _unknown(src, SEAT_STALE_S, f"seat file unreadable: {e}",
                        explain=explain)
    health = data.get("health_class")
    # fleet-ops#3111: a stale observation is UNKNOWN, never "healthy". The
    # 2026-09-03 incident left this tile green on a 2-day-old observation
    # while the transport was down 33h. Use the file's observed_at (not
    # time.time()) and render unknown when it is older than SEAT_STALE_S or
    # absent — the underlying health_class is not trustworthy past 30 min.
    obs_raw = data.get("observed_at")
    obs_epoch = None
    if isinstance(obs_raw, str):
        try:
            obs_epoch = int(calendar.timegm(time.strptime(
                obs_raw.replace("Z", "+00:00")[:19], "%Y-%m-%dT%H:%M:%S")))
        except ValueError:
            obs_epoch = None
    stale = obs_epoch is None or (time.time() - obs_epoch) > SEAT_STALE_S
    # fleet-ops#3563: overlay the wrapper's spawn-bench marker. The bench
    # writers co-write pi-seat-health.json at bench time, but a later
    # healthy observation from the seat-health extension (an in-flight run
    # completing after the bench, or a comeback probe) rewrites the sidecar
    # as healthy while the marker still holds the seat — the tile would
    # show "seat healthy" for a seat the router refuses to use. A held
    # marker renders as spawn_bench, matching the heartbeat census overlay.
    if health == "healthy" and _seat_bench_held(
            data.get("provider"), data.get("model")):
        health = "spawn_bench"
    try:
        units = [n for n in _running_units() if _invokes_pi_print(n)]
    except Exception as e:
        return _unknown(src, PROC_STALE_S, f"systemctl failed: {str(e)[:120]}",
                        explain=explain)
    try:
        proc_count = _pi_argv_count()
    except Exception as e:
        proc_count = None
        note_extra = f"proc count failed: {str(e)[:80]}"
    else:
        note_extra = None
    if stale:
        age_s = -1 if obs_epoch is None else int(time.time() - obs_epoch)
        note = (f"seat UNKNOWN — health observation stale ({age_s}s old; "
                f"last class {health}, {data.get('provider')}/{data.get('model')})")
        if note_extra:
            note = note + "; " + note_extra
        return _unknown(src, SEAT_STALE_S, note, explain=explain)
    provider = data.get("provider")
    quota_info = _seat_quota_info(provider)
    quota_note = ""
    quota_fields = {}
    if quota_info and quota_info["rows"]:
        parts = []
        for qr in quota_info["rows"]:
            w = qr["window"] or "?"
            parts.append(f"{w}={qr['remaining_pct']}%")
        quota_note = f"quota {', '.join(parts)}"
        quota_fields["quota_source"] = quota_info["source"]
        quota_fields["quota_rows"] = quota_info["rows"]
    note = f"seat {health} ({provider}/{data.get('model')})"
    if quota_note:
        note = note + "; " + quota_note
    if note_extra:
        note = note + "; " + note_extra
    return _tile(
        src, SEAT_STALE_S, True, obs_epoch,
        count=len(units), proc_count=proc_count, unit_count=len(units),
        units=units[:20],
        health_class=health,
        provider=provider,
        model=data.get("model"),
        note=note,
        explain=explain,
        **quota_fields,
    )


def _gh_json(args, timeout=25):
    """Run a `gh` subprocess and return parsed JSON. Raises on failure.

    The questions tile is the one console source the issue (fleet-ops#4475)
    requires to read GitHub directly — every open issue org-wide with the
    `question` label. A non-zero gh exit or non-JSON output raises so the
    caller fails closed to "source unavailable", never an empty list.
    """
    out = subprocess.run(
        ["gh"] + args, capture_output=True, text=True, timeout=timeout,
    )
    if out.returncode != 0:
        # Name the repo too when the call carries one. The per-issue fetch is
        # ["issue", "view", <number>, "-R", <repo>, ...] (fleet-ops#4996), so
        # the positional prefix alone dropped the repo and a dark questions
        # tile could not say WHICH repo's fetch failed (fleet-ops#5069).
        named = list(args[:3])
        if "-R" in args:
            i = args.index("-R")
            if i + 1 < len(args):
                named += ["-R", args[i + 1]]
        raise RuntimeError(
            f"gh {' '.join(named)} rc={out.returncode}: "
            f"{(out.stderr or '').strip()[:160]}"
        )
    try:
        return json.loads(out.stdout or "null")
    except json.JSONDecodeError as e:
        raise RuntimeError(f"gh output not JSON: {e}") from e


def _body_field(body, key):
    """Value of the first `key: ...` line in an issue body (or '')."""
    for line in (body or "").splitlines():
        ls = line.strip()
        if ls.startswith(key + ":"):
            return ls[len(key) + 1:].strip()
    return ""


def _conference_reason(issue, comments):
    """One-line conference reason for the question, or '' when absent."""
    texts = [issue.get("body") or ""] + [
        c.get("body") or "" for c in (comments or [])
    ]
    for text in texts:
        for line in text.splitlines():
            ls = line.strip()
            if ls.lower().startswith("reason:"):
                return ls[len("reason:"):].strip() or ""
    return ""


def _answer_epoch(comments):
    """Epoch of the most recent decision-resolved: comment body, or None."""
    latest = None
    for c in (comments or []):
        body = c.get("body") or ""
        if "decision-resolved:" not in body:
            continue
        created = c.get("createdAt")
        if not created:
            continue
        try:
            epoch = datetime.fromisoformat(created.replace("Z", "+00:00")).timestamp()
        except ValueError:
            continue
        if latest is None or epoch > latest:
            latest = epoch
    return latest


def _classify_question(issue, comments):
    """Classify one open question issue.

    Returns (state, conference_reason):
      - 'answered'   has a decision-resolved: comment, kept ANSWERED_KEEP_S
      - 'for-nish'   no answer; carries a FOR_NISH_LABELS (passed the gate)
      - 'in-conference' no answer and no gate verdict yet
    The conference one-line reason is lifted from a `reason:` line in the
    body or any comment (part-1 verdicts carry it); '' when absent.
    """
    reason = _conference_reason(issue, comments)
    answer_epoch = _answer_epoch(comments)
    if answer_epoch is not None:
        return ("answered", reason)
    labels = {l.get("name") for l in (issue.get("labels") or [])}
    if labels & set(FOR_NISH_LABELS):
        return ("for-nish", reason)
    return ("in-conference", reason)


def _gh_questions():
    """Return (items, capped) for the open `question` issues across the org.

    One search for the current population, then one comment fetch per issue
    (to detect decision-resolved: answers and the conference reason). Raises
    on any gh failure so collect_questions fails closed — never an empty
    list when the source is unreachable.

    The search carries an explicit --limit (QUESTION_SEARCH_LIMIT); `capped`
    is True when the result filled that window, i.e. the population may
    continue past it and the tile must say so instead of under-reporting
    (fleet-ops#5133).
    """
    q = _gh_json([
        "search", "issues", "--owner", ORG, "--state", "open",
        "--label", "question",
        "--limit", str(QUESTION_SEARCH_LIMIT),
        "--json", "number,title,url,createdAt,updatedAt,repository,labels,body",
    ])
    rows = q or []
    capped = len(rows) >= QUESTION_SEARCH_LIMIT
    items = []
    now = time.time()
    for issue in rows:
        repo = (issue.get("repository") or {}).get("nameWithOwner") or ORG
        number = issue.get("number")
        # `gh issue view` takes exactly one positional (the issue number);
        # the repo is named only via -R. Passing both exits rc=1.
        comments = _gh_json([
            "issue", "view", str(number),
            "-R", f"{ORG}/{repo.split('/')[-1]}" if repo.startswith(ORG) else repo,
            "--json", "comments",
            "--jq", ".comments // []",
        ]) if number is not None else []
        if not isinstance(comments, list):
            comments = []
        state, reason = _classify_question(issue, comments)
        if state == "answered":
            answer_epoch = _answer_epoch(comments)
            if answer_epoch is None or now - answer_epoch > ANSWERED_KEEP_S:
                # Answered >24h ago — no longer on the tab.
                continue
        body = issue.get("body") or ""
        createdAt = issue.get("createdAt") or now_iso()
        try:
            asked_epoch = datetime.fromisoformat(
                createdAt.replace("Z", "+00:00")).timestamp()
        except ValueError:
            asked_epoch = now
        items.append({
            "repo": repo,
            "number": number,
            "ref": f"{repo.split('/')[-1]}#{number}",
            "handle": f"Q:{repo.split('/')[-1]}#{number}",
            "url": issue.get("url") or "",
            "question": _body_field(body, "question") or (issue.get("title") or "").strip(),
            "options": _body_field(body, "options"),
            "asked_at": createdAt,
            "age_h": round(max(now - asked_epoch, 0) / 3600.0, 1),
            "state": state,
            "conference_reason": reason,
        })
    items.sort(key=lambda x: x["age_h"], reverse=True)  # oldest ask first
    return items, capped


def collect_questions():
    """Live-truth tile for the 'Questions for Nish' section.

    Source is GitHub directly (the `question` label is the single store,
    fleet-ops#4474). Fails closed to source-unavailable on any gh error —
    never an empty list when the query failed.
    """
    src = "github:open question-label issues (Nishfleet org)"
    explain = ("Open issues org-wide carrying the `question` label. Each is "
               "classified: for-nish (has conference-approved or nish-reserved), "
               "in-conference (no gate verdict yet), or answered (has a "
               "decision-resolved: comment, kept 24h then dropped). Answers are "
               "GitHub comments; blocked-reconcile re-queues the work. The tab has "
               "no write path.")
    try:
        items, capped = _gh_questions()
    except Exception as e:
        return _unknown(src, QUESTION_STALE_S,
                        f"github query failed: {str(e)[:160]}", explain=explain)
    return _tile(src, QUESTION_STALE_S, True, time.time(),
                 count=len(items), items=items, capped=capped,
                 search_limit=QUESTION_SEARCH_LIMIT, explain=explain)


def collect_fleet_state():
    src = "local:FLEET-PAUSED + systemd user timers"
    explain = ("Fleet pause marker at agent-state/FLEET-PAUSED plus the live "
               "count of systemd --user timers. Authoritative vs any memory file.")
    marker = FLEET_PAUSED_MARKER.exists()
    timer_count = None
    try:
        env = dict(os.environ, XDG_RUNTIME_DIR=XDG)
        out = subprocess.run(
            ["systemctl", "--user", "list-timers", "--all",
             "--no-legend", "--plain"],
            capture_output=True, text=True, timeout=8, env=env,
        )
        timer_count = len([ln for ln in (out.stdout or "").splitlines()
                           if ln.strip()])
    except Exception:
        pass
    note = "paused (FLEET-PAUSED marker present)" if marker else \
           "running (no FLEET-PAUSED marker)"
    return _tile(src, FLEET_STALE_S, True, time.time(),
                 paused=marker, marker_exists=marker, active_timers=timer_count,
                 note=note, explain=explain)


def collect_findings():
    """Canonical findings ledger (fleet-ops#5443, Nish 2026-09-11): every
    finding queued and never dropped silently, rendered live on
    nish.sh/fleet. Reads the vault ledger; the jsonl IS the truth, no
    second copy."""
    src = "vault _system/shared-memory/findings-ledger.jsonl"
    explain = ("Canonical findings ledger at nish-vault "
               "_system/shared-memory/findings-ledger.jsonl: totals per "
               "disposition plus the newest 50 rows. The red banner fires "
               "when a carried-over finding is older than 24h or the "
               "ledger has been silent 48h — a silent ledger is itself a "
               "finding.")
    try:
        rows = [json.loads(x) for x in
                FINDINGS_LEDGER.read_text().splitlines() if x.strip()]
    except FileNotFoundError:
        return _unknown(src, FINDINGS_STALE_S, "no findings ledger file",
                        explain=explain)
    except (json.JSONDecodeError, OSError) as e:
        return _unknown(src, FINDINGS_STALE_S, f"unreadable: {e}",
                        explain=explain)
    now = time.time()

    def _age(ts):
        try:
            dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
            return max(0.0, now - dt.timestamp())
        except Exception:
            return 0.0

    # A disposition the summary line does not name is still counted (never
    # a KeyError that would freeze the whole doc).
    counts = {"filed": 0, "carried_over": 0, "panel_fail": 0,
              "by_design": 0, "duplicate_of": 0}
    for r in rows:
        d = r.get("disposition")
        counts[d] = counts.get(d, 0) + 1
    oldest_carry = max((_age(r.get("ts")) for r in rows
                        if r.get("disposition") == "carried_over"),
                       default=0.0)
    last_append = max((_age(r.get("ts")) for r in rows), default=0.0)
    alert = []
    if oldest_carry > 24 * 3600:
        alert.append("carried-over finding untouched for over 24h")
    if last_append > 48 * 3600:
        alert.append("ledger went 48h with no append — a silent ledger is "
                     "itself a finding")
    last = sorted(rows, key=lambda r: r.get("ts") or "")[-50:][::-1]
    return _tile(src, FINDINGS_STALE_S, True, now,
                 total=len(rows),
                 dispositions=counts,
                 oldest_carry_h=round(oldest_carry / 3600, 1),
                 last_append_h=round(last_append / 3600, 1),
                 alert="; ".join(alert),
                 items=[
                     {"finding_id": r.get("finding_id"),
                      "severity": r.get("severity"),
                      "title": r.get("title"),
                      "disposition": r.get("disposition"),
                      "ref": r.get("ref"),
                      "reason": r.get("reason"),
                      "ts": r.get("ts")}
                     for r in last
                 ],
                 explain=explain)


def generate():
    t0 = time.time()
    doc = {"generated_at": now_iso(), "generated_epoch": time.time(),
           "cadence_min": CADENCE_MIN, "org": ORG, "tiles": {}}
    doc["tiles"]["open_prs"] = collect_open_prs()
    doc["tiles"]["shipped_24h"] = collect_shipped()
    doc["tiles"]["outcome"] = collect_outcome()
    doc["tiles"]["main_ci"] = collect_main_ci()
    doc["tiles"]["firing_alerts"] = collect_firing_alerts()
    doc["tiles"]["repairs_inflight"] = collect_repairs_inflight()
    doc["tiles"]["running_pi"] = collect_running_pi()
    doc["tiles"]["fleet_state"] = collect_fleet_state()
    doc["tiles"]["findings"] = collect_findings()
    # fleet-ops#4475: the questions tile is a full section, not a band cell.
    # It lives under tiles (freshness contract + independent verify) and is
    # ALSO surfaced top-level as `questions` for the shell to render first.
    q = collect_questions()
    doc["tiles"]["questions"] = q
    doc["questions"] = q.get("items") or []
    repos = set()
    for key in ("open_prs", "shipped_24h", "main_ci"):
        for item in doc["tiles"][key].get("items") or []:
            if item.get("repo"):
                repos.add(item["repo"])
    doc["repos"] = sorted(repos)
    doc["gen_seconds"] = round(time.time() - t0, 2)
    # Stamp each tile with its executable verify command (fleet-ops#1157).
    # The push job then RUNS those commands; this only records the claim.
    try:
        import importlib.util
        vpath = Path(__file__).resolve().parent / "verify.py"
        spec = importlib.util.spec_from_file_location("console_verify", vpath)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.attach_specs(doc)
    except Exception as e:
        doc["verify_attach_error"] = str(e)[:160]
    return doc


def main():
    doc = generate()
    OUT_JSON.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    tiles = doc.get("tiles", {})
    op = tiles.get("open_prs", {})
    sh = tiles.get("shipped_24h", {})
    ci = tiles.get("main_ci", {})
    al = tiles.get("firing_alerts", {})
    rp = tiles.get("repairs_inflight", {})
    q = tiles.get("questions", {})
    oc = tiles.get("outcome", {})
    print(f"generated {doc['generated_at']} "
          f"open_prs={op.get('count','—')} shipped={sh.get('count','—')} "
          f"outcome={oc.get('count','—')} "
          f"main_red={ci.get('red_count','—')} "
          f"alerts={al.get('count','—')} repairs={rp.get('count','—')} "
          f"questions={q.get('count','—')} "
          f"in {doc['gen_seconds']}s -> {OUT_JSON}")


if __name__ == "__main__":
    main()
