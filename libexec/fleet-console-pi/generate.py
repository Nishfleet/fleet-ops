#!/usr/bin/env python3
"""Fleet Console (Pi) — live-truth generator.

Tiles pull from the shared monitoring plane: Prometheus on 127.0.0.1:9090
for merged PRs, open PRs, main-branch CI, repair dispatches, and firing
alerts; pi-seat-health.json plus live transient systemd units for PI WORK
and repairs-in-flight. The generator makes zero GitHub API calls.

Every tile carries a freshness contract (observed_at + stale_after_s +
source + explain). A missing or stale metric renders unknown (the shell
shows "—"), never a frozen last value and never a coerced zero.
"""
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ORG = "Nishfleet"
OUT_JSON = Path(__file__).resolve().parent / "data.json"
CADENCE_MIN = 12
PROM = "http://127.0.0.1:9090"
PROM_STALE_S = 15 * 60          # exporter fires every 5 min; 2+ misses = stale
SEAT_STALE_S = 30 * 60
PROC_STALE_S = 5 * 60
REPAIR_STALE_S = 20 * 60       # >1.5 push cycles (CADENCE_MIN=12); younger renders, older renders —
FLEET_STALE_S = 60 * 60
FLEET_PAUSED_MARKER = Path("/home/nish/workspaces/agent-state/FLEET-PAUSED")
SEAT_HEALTH = Path("/home/nish/workspaces/agent-state/lanes/pi-seat-health.json")
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


def _prom_query(expr, timeout=5):
    """Instant query. Returns [{metric, value}] or raises PromError.

    An empty list means the query succeeded and matched no series (family
    omitted, or a true zero with no per-repo samples).
    """
    url = PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            payload = json.load(r)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError,
            OSError, json.JSONDecodeError, ValueError) as exc:
        raise PromError(str(exc)[:160]) from exc
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
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            payload = json.load(r)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError,
            OSError, json.JSONDecodeError, ValueError) as exc:
        raise PromError(str(exc)[:160]) from exc
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


def _cache_fresh(kind):
    """True when exporter emitted fleet_gh_cache_fresh{kind=...} = 1."""
    rows = _prom_query(f'fleet_gh_cache_fresh{{kind="{kind}"}}')
    return bool(rows) and any(r["value"] == 1 for r in rows)


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


def collect_shipped():
    src = "prometheus:fleet_merged_prs_24h"
    explain = ("Prometheus fleet_merged_prs_24h, trailing 24h, skipped/"
               "cancelled runs excluded. Cached org-wide gh search ≤30 min; "
               "cache older than 2h omits the family (never a frozen value).")
    mtime, err = _prom_or_stale(src, explain)
    if err:
        return err
    try:
        fresh = _cache_fresh("merged_prs")
        rows = _prom_query("fleet_merged_prs_24h")
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
    return _tile(src, PROM_STALE_S, True, mtime, count=total, items=items,
                 explain=explain)


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
    return _tile(src, PROM_STALE_S, True, mtime, count=total, items=items,
                 explain=explain)


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
    return _tile(src, PROM_STALE_S, True, mtime, red_count=red, items=items,
                 explain=explain)


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
         "--state=running", "--no-legend", "--plain"],
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

    Replaces the old pi-*/alert-repair-* prefix filter, which missed units
    whose names don't start with those prefixes (issue-*-fix, canary-*,
    vps-hygiene-*, ram-governor-*, ad-hoc pi-systemd-run names). ExecStart is
    the honest signal: a fleet worker runs `pi --print`. Verified 2026-08-27:
    9 live units invoke `pi --print`, 0 matched the old prefix filter.
    """
    env = dict(os.environ, XDG_RUNTIME_DIR=XDG)
    out = subprocess.run(
        ["systemctl", "--user", "show", "-p", "ExecStart", "--value", unit],
        capture_output=True, text=True, timeout=5, env=env,
    )
    return "pi --print" in (out.stdout or "")


def _pgrep_pi_print():
    """Count running `pi --print` processes (pgrep -c -f 'pi --print').

    pgrep exits 1 with empty stdout when nothing matches (treated as 0).
    """
    out = subprocess.run(
        ["pgrep", "-c", "-f", "pi --print"],
        capture_output=True, text=True, timeout=5,
    )
    if out.returncode == 0:
        try:
            return int((out.stdout or "").strip())
        except ValueError:
            return 0
    # rc=1: no matches; anything else: treat as 0 rather than crash
    return 0


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


def collect_running_pi():
    src = "pgrep -c -f 'pi --print' + systemd transients invoking 'pi --print'"
    explain = ("PI WORK: count of running `pi --print` processes "
               "(pgrep -c -f 'pi --print') PLUS running transient systemd "
               "user units whose ExecStart invokes `pi --print` "
               "(systemctl --user show -p ExecStart over running units, "
               "transient only — catches pi-issue@*, pi-intake@*, "
               "alert-repair-*, issue-*-fix, canary-*, vps-hygiene-*, "
               "and ad-hoc pi-systemd-run names alike). Seat health_class "
               "from agent-state/lanes/pi-seat-health.json is the subtitle.")
    try:
        data = json.loads(SEAT_HEALTH.read_text())
    except (OSError, json.JSONDecodeError) as e:
        return _unknown(src, SEAT_STALE_S, f"seat file unreadable: {e}",
                        explain=explain)
    health = data.get("health_class")
    try:
        proc_count = _pgrep_pi_print()
    except Exception as e:
        return _unknown(src, PROC_STALE_S, f"pgrep failed: {str(e)[:120]}",
                        explain=explain)
    try:
        transients = [n for n in _running_units()
                      if _is_transient(n) and _invokes_pi_print(n)]
    except Exception as e:
        return _unknown(src, PROC_STALE_S, f"systemctl failed: {str(e)[:120]}",
                        explain=explain)
    total = proc_count + len(transients)
    return _tile(
        src, SEAT_STALE_S, True, time.time(),
        count=total, proc_count=proc_count, unit_count=len(transients),
        units=transients[:20],
        health_class=health,
        provider=data.get("provider"),
        model=data.get("model"),
        note=f"seat {health} ({data.get('provider')}/{data.get('model')})",
        explain=explain,
    )


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
    finding queued and never dropped silently, rendered live on nish.sh/fleet.
    Reads the vault ledger; the jsonl IS the truth, no second copy."""
    src = "vault _system/shared-memory/findings-ledger.jsonl"
    doc = _unknown("navish@netcup-rs2000/vault", 0, "ledger missing")
    ledger = os.path.expanduser(
        "~/workspaces/tooling/nish-vault/_system/shared-memory/findings-ledger.jsonl")
    try:
        rows = [json.loads(x) for x in open(ledger) if x.strip()]
    except FileNotFoundError:
        return dict(doc, source=src, reason="no findings ledger file")
    except (json.JSONDecodeError, OSError) as e:
        return dict(doc, source=src, reason="unreadable: %s" % e)
    now = time.time()
    def _age(ts):
        try:
            dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
            return max(0.0, now - dt.timestamp())
        except Exception:
            return 0.0
    counts = {"filed": 0, "carried_over": 0, "panel_fail": 0, "by_design": 0, "duplicate_of": 0}
    for r in rows:
        counts[r.get("disposition")] += 1  # KeyError-safe: strictly-validated rows
    oldest_carry = max((_age(r["ts"]) for r in rows if r.get("disposition") == "carried_over"), default=0.0)
    last_append = max((_age(r["ts"]) for r in rows), default=0.0)
    alert = []
    if oldest_carry > 24 * 3600:
        alert.append("carried-over finding untouched for over 24h")
    if last_append > 48 * 3600:
        alert.append("ledger went 48h with no append — a silent ledger is itself a finding")
    last = sorted(rows, key=lambda r: r.get("ts", ""))[-50:][::-1]
    out = {
        "source": src,
        "stale_after_s": 2 * 48 * 3600,  # a ledger silent longer than 48h is itself a finding
        "ok": True,
        "observed_at": now_iso(),
        "age_s": last_append,
        "total": len(rows),
        "dispositions": counts,
        "oldest_carry_h": round(oldest_carry / 3600, 1),
        "last_append_h": round(last_append / 3600, 1),
        "alert": "; ".join(alert),
        "items": [
            {"finding_id": r.get("finding_id"), "severity": r.get("severity"),
             "title": r.get("title"), "disposition": r.get("disposition"),
             "ref": r.get("ref"), "reason": r.get("reason"), "ts": r.get("ts")}
            for r in last
        ],
    }
    lead = None
    if alert:
        out["level"] = "danger"
    return out


def generate():
    t0 = time.time()
    doc = {"generated_at": now_iso(), "generated_epoch": time.time(),
           "cadence_min": CADENCE_MIN, "org": ORG, "tiles": {}}
    doc["tiles"]["open_prs"] = collect_open_prs()
    doc["tiles"]["shipped_24h"] = collect_shipped()
    doc["tiles"]["main_ci"] = collect_main_ci()
    doc["tiles"]["firing_alerts"] = collect_firing_alerts()
    doc["tiles"]["repairs_inflight"] = collect_repairs_inflight()
    doc["tiles"]["running_pi"] = collect_running_pi()
    doc["tiles"]["fleet_state"] = collect_fleet_state()
    doc["tiles"]["findings"] = collect_findings()
    repos = set()
    for key in ("open_prs", "shipped_24h", "main_ci"):
        for item in doc["tiles"][key].get("items") or []:
            if item.get("repo"):
                repos.add(item["repo"])
    doc["repos"] = sorted(repos)
    doc["gen_seconds"] = round(time.time() - t0, 2)
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
    print(f"generated {doc['generated_at']} "
          f"open_prs={op.get('count','—')} shipped={sh.get('count','—')} "
          f"main_red={ci.get('red_count','—')} "
          f"alerts={al.get('count','—')} repairs={rp.get('count','—')} "
          f"in {doc['gen_seconds']}s -> {OUT_JSON}")


if __name__ == "__main__":
    main()
