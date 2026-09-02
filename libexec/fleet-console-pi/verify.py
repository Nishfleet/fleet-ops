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
AM = os.environ.get("AM_URL", "http://127.0.0.1:9093")
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
            "'repo:<spot-repo> is:open type:pr' (percent vs that repo's "
            "item; cached family, 15% or abs<=2)"
        ),
        "field": "count",
        "tolerance": {"mode": "exact"},
        "runner": "open_prs_prom",
        "spot": {
            "cmd": "gh api search/issues -f q='repo:<spot-repo> is:open type:pr' --jq .total_count",
            "tolerance": {"mode": "percent", "pct": 15},
            "runner": "open_prs_gh_spot",
        },
    },
    "shipped_24h": {
        "cmd": (
            "PromQL sum(fleet_merged_prs_24h) @ 127.0.0.1:9090 "
            "(exact vs tile count) AND gh search prs "
            "'repo:<spot-repo> is:merged merged:>=<24h-iso> type:pr' "
            "(percent vs that repo's item; cached family, 20% or abs<=2)"
        ),
        "field": "count",
        "tolerance": {"mode": "exact"},
        "runner": "shipped_prom",
        "spot": {
            "cmd": (
                "gh api search/issues -f q='repo:<spot-repo> is:merged "
                "merged:>=<24h-iso> type:pr' --jq .total_count"
            ),
            "tolerance": {"mode": "percent", "pct": 20},
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
            "Alertmanager GET /api/v2/alerts, state=active, Watchdog excluded "
            "(independent of Prometheus /api/v1/alerts)"
        ),
        "field": "count",
        "tolerance": {"mode": "exact"},
        "runner": "alerts_am",
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


def _prom_textfile_mtime():
    """Return the Prometheus fleet.ptextfile mtime in epoch seconds, or None.

    Same family node_textfile_mtime_seconds{file=~".*fleet.prom"} that
    generate.py uses for its staleness gate. Returns None when the series
    is absent (the file has never been written) — not an error; the
    downstream race check treats absent == "definitely changed" and falls
    back to the gh spot check.
    """
    url = PROM + "/api/v1/query?" + urllib.parse.urlencode({
        "query": 'node_textfile_mtime_seconds{file=~".*fleet.prom"}',
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
    may refresh fleet.prom (every 5 min vs the 12-min push cycle). When
    that happens the tile and the verifier look at the SAME Prom family
    but at different snapshots — `tile.count != sum(fleet_merged_prs_24h)`
    is a transient timing artifact, not a lying tile. The race gate tells
    Prom-based checkers to defer to the gh check.

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


def run_open_prs_prom(tile):
    return int(_promql_sum("sum(fleet_open_prs)"))


def run_shipped_prom(tile):
    # fleet-ops#2690: skip the Prom re-query when the textfile advanced
    # between generate and verify. The gh spot check still runs; only the
    # same-source race is suppressed.
    if _race_against_tile(tile):
        raise VerifyError(
            "textfile mtime advanced past tile.observed_at — race, "
            "defer to gh spot check"
        )
    return int(_promql_sum("sum(fleet_merged_prs_24h)"))


def run_main_ci_prom(tile):
    return int(_promql_sum("count(fleet_main_ci_green == 0)"))


def run_alerts_am(tile):
    url = AM.rstrip("/") + "/api/v2/alerts"
    try:
        payload = _http_json(url)
    except VerifyError:
        # AM down: fall back to Prometheus alerts API (weaker independence).
        payload = _http_json(PROM.rstrip("/") + "/api/v1/alerts")
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
    if not isinstance(payload, list):
        raise VerifyError("am /api/v2/alerts was not a list")
    n = 0
    for a in payload:
        labels = a.get("labels") or {}
        if labels.get("alertname") == "Watchdog":
            continue
        status = a.get("status") or {}
        state = status.get("state") or a.get("status") or ""
        if state in ("active", "firing"):
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


def run_running_pi_execstart(tile):
    units = 0
    for name in _running_units():
        es = _show_value(name, "ExecStart")
        if ("pi --print" in es) or ("/pi-issue-run " in es) or ("/pi-issue-start" in es):
            units += 1
    return units


def run_fleet_paused(tile):
    return 1 if PAUSED_MARKER.exists() else 0


def run_open_prs_gh_spot(tile):
    repo = _spot_repo(tile)
    displayed = _item_count_for_repo(tile, repo)
    if displayed is None:
        raise VerifyError(f"no items entry for {repo}")
    n = _gh_search_count(f"repo:{repo} is:open")
    return n, displayed, repo


def run_shipped_gh_spot(tile):
    repo = _spot_repo(tile)
    displayed = _item_count_for_repo(tile, repo)
    if displayed is None:
        raise VerifyError(f"no items entry for {repo}")
    since = (datetime.now(timezone.utc) - timedelta(hours=24)).strftime(
        "%Y-%m-%dT%H:%M:%S+00:00"
    )
    n = _gh_search_count(f"repo:{repo} is:merged merged:>={since}")
    return n, displayed, repo


RUNNERS = {
    "open_prs_prom": run_open_prs_prom,
    "shipped_prom": run_shipped_prom,
    "main_ci_prom": run_main_ci_prom,
    "alerts_am": run_alerts_am,
    "repairs_units": run_repairs_units,
    "running_pi_execstart": run_running_pi_execstart,
    "fleet_paused": run_fleet_paused,
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
    raise VerifyError(f"unknown tolerance mode {mode}")


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
            observed, spot_displayed, repo = RUNNERS[spot["runner"]](tile)
            verify["spot_repo"] = repo
            verify["spot_displayed"] = spot_displayed
            verify["spot_observed"] = float(observed)
            if not _within(float(spot_displayed), float(observed),
                           spot["tolerance"]):
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
