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
import http.client
import json
import os
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


def collect_running_pi():
    src = ("systemd: running user units whose ExecStart contains "
           "'pi --print'")
    explain = ("PI WORK: count of running systemd user units whose "
               "ExecStart contains `pi --print` (systemctl --user show "
               "-p ExecStart over running units — never a unit-name "
               "pattern; fleet-ops#1155). Subtitle is /proc argv count of "
               "the pi binary plus --print (independent, not added). Seat "
               "health_class from agent-state/lanes/pi-seat-health.json.")
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
    note = f"seat {health} ({data.get('provider')}/{data.get('model')})"
    if note_extra:
        note = note + "; " + note_extra
    return _tile(
        src, SEAT_STALE_S, True, obs_epoch,
        count=len(units), proc_count=proc_count, unit_count=len(units),
        units=units[:20],
        health_class=health,
        provider=data.get("provider"),
        model=data.get("model"),
        note=note,
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
    print(f"generated {doc['generated_at']} "
          f"open_prs={op.get('count','—')} shipped={sh.get('count','—')} "
          f"main_red={ci.get('red_count','—')} "
          f"alerts={al.get('count','—')} repairs={rp.get('count','—')} "
          f"in {doc['gen_seconds']}s -> {OUT_JSON}")


if __name__ == "__main__":
    main()
