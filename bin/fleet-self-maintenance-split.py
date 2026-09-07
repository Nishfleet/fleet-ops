#!/usr/bin/env python3
"""fleet-self-maintenance-split — measure the product-vs-self merge split
per repo over the trailing N days (fleet-ops#4061).

The FleetQueueSelfMaintenanceRatioHigh alert fires constantly at ~72-74%;
every repeat the alert-repair loop re-derives the same answer by hand: which
repo did the merges land in, is that repo self-maintenance, and what is the
ratio?  This is that derivation, mechanized, on demand — observe-to-close
(fleet-ops#366).

It answers the three measurement bullets the issue asks for:
  1. the actual product-vs-self merge split PER REPO over the trailing 7d
  2. the top self-maintenance workload classes within the self repos
  3. whether the console `shipped_24h` tile still agrees with independently
     measured merges (the lying-tile reconciliation)

It is ON DEMAND only — no timer, no new prom metric, no new exporter.  It
reuses the fleet's existing classifications (config/self-maintenance-repos.json
= self; every other non-archived Nishfleet repo = product), the existing
console data.json, and the existing fleet_product_merged_24h exporter gauge.
Collapsing the per-repeat manual re-derivation IS the self-maintenance
reduction: a worker no longer has to burn a session reproducing this split.

Usage:
  fleet-self-maintenance-split [--days N] [--repo-only NAME[,ANOTHER]]
  fleet-self-maintenance-split --reconcile-tile
  fleet-self-maintenance-split --help

Environment seams (tests):
  FLEET_SELF_SPLIT_GH           gh binary (or a fake)            [gh]
  FLEET_SELF_SPLIT_ORG          org name                        [Nishfleet]
  FLEET_SELF_SPLIT_DAYS         trailing window days             [7]
  FLEET_SELF_SPLIT_SELF_JSON    config/self-maintenance-repos.json
  FLEET_SELF_SPLIT_NOW          anchor now ISO (deterministic tests)
  FLEET_SELF_SPLIT_CONSOLE      console data.json path (tile reconcile)
  FLEET_SELF_SPLIT_PRODUCT_SLO  fleet-product-slo.prom path (tile reconcile)
  FLEET_SELF_SPLIT_TOLERANCE    shipped_24h spot-tolerance percent [20]
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

HOME = os.environ.get("HOME", "/home/nish")
GH = os.environ.get("FLEET_SELF_SPLIT_GH", "gh")
ORG = os.environ.get("FLEET_SELF_SPLIT_ORG", "Nishfleet")
DAYS = int(os.environ.get("FLEET_SELF_SPLIT_DAYS", "7"))
SELF_JSON = os.environ.get(
    "FLEET_SELF_SPLIT_SELF_JSON",
    f"{HOME}/workspaces/tooling/fleet-ops/config/self-maintenance-repos.json",
)
NOW_ISO = os.environ.get(
    "FLEET_SELF_SPLIT_NOW", datetime.now(timezone.utc).isoformat()
)
CONSOLE_JSON = os.environ.get(
    "FLEET_SELF_SPLIT_CONSOLE",
    "/home/nish/.local/libexec/fleet-console-pi/data.json",
)
PRODUCT_SLO = os.environ.get(
    "FLEET_SELF_SPLIT_PRODUCT_SLO",
    "/var/lib/prometheus/node-exporter/fleet-product-slo.prom",
)
TOL = float(os.environ.get("FLEET_SELF_SPLIT_TOLERANCE", "20"))
GH_TIMEOUT = 45
MAX_PER_REPO = 1000

DEFAULT_SELF = ("fleet-ops",)

# Single-assignment topic classifier for the self-maintenance workload.
# First rule whose keyword hits wins; the catch-all is the honest residual.
_TOPIC_RULES = [
    ("seat management", ["seat", "corpse", "credential", "comeback", "spawn_fail"]),
    ("audit / drift", ["audit", "gap-audit", "blind", "drift"]),
    ("canary", ["canary"]),
    ("intake / scout", ["intake", "scout"]),
    ("deploy / rebuild", ["deploy", "rebuild", "install", "manifest"]),
    ("quality gate", ["quality"]),
    ("gate / ci", ["gate", "ci", "workflow", "release-gate"]),
    ("escalation / alert-repair", ["escalation", "alert-repair", "repair"]),
    ("oomd / memory", ["oomd", "memory"]),
    ("console tile", ["console", "tile"]),
    ("metrics / export", ["metrics", "export", "prometheus"]),
    ("drift / freshness", ["freshness", "stale"]),
    ("docs / verification-record", ["verification record", "docs:"]),
    ("revert", ["revert", "auto-restore"]),
    ("test-only", ["test("]),
    ("chore", ["chore"]),
]


def _now() -> datetime:
    return datetime.fromisoformat(NOW_ISO)


def _run_gh(args, check=True):
    env = dict(os.environ)
    env.update({"GH_TOKEN": os.environ.get("GH_TOKEN", "")})
    try:
        r = subprocess.run(
            [GH] + args, capture_output=True, text=True, timeout=GH_TIMEOUT,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SystemExit(f"fleet-self-maintenance-split: gh failed: {exc}")
    if check and r.returncode != 0:
        raise SystemExit(
            f"fleet-self-maintenance-split: gh call failed rc={r.returncode}: "
            f"{(r.stderr or r.stdout or '')[:200]}"
        )
    return r


def _list_repos():
    r = _run_gh(["repo", "list", ORG, "--json", "name,isArchived", "-L", "200"])
    try:
        rows = json.loads(r.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"fleet-self-maintenance-split: repo list json: {exc}")
    return [x["name"] for x in rows if not x.get("isArchived")]


def _load_self_set():
    if os.path.exists(SELF_JSON):
        try:
            d = json.load(open(SELF_JSON))
            return d.get("repos", list(DEFAULT_SELF))
        except (OSError, json.JSONDecodeError):
            return list(DEFAULT_SELF)
    return list(DEFAULT_SELF)


def _cutoff_iso(days: int) -> str:
    return (_now() - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S+00:00")


def _merged_per_repo(repo: str, days: int):
    """Return (count, list_of_titles) of merged PRs in the window."""
    cutoff = _cutoff_iso(days)
    r = _run_gh(
        [
            "pr", "list", "-R", f"{ORG}/{repo}", "--state", "merged",
            "--search", f"merged:>={cutoff}",
            "--json", "number,title,mergedAt,headRefName", "-L", str(MAX_PER_REPO),
        ]
    )
    try:
        rows = json.loads(r.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"fleet-self-maintenance-split: pr list json {repo}: {exc}")
    return len(rows), [x.get("title", "") for x in rows]


def _topic(title: str) -> str:
    tl = title.lower()
    for label, kws in _TOPIC_RULES:
        for kw in kws:
            if kw in tl:
                return label
    return "other / fix-misc"


def _top_classes(titles, n=3):
    c = Counter(_topic(t) for t in titles)
    return c.most_common(n), len(titles)


# --- console shipped_24h tile reconciliation -------------------------------

def _read_shipped_tile():
    """Return (tile_count, disputed, observed_at_iso) from console data.json."""
    try:
        d = json.load(open(CONSOLE_JSON))
    except (OSError, json.JSONDecodeError) as exc:
        return None, None, f"unreadable: {exc}"
    t = d.get("tiles", {}).get("shipped_24h", {}) or {}
    obs = t.get("observed_at")
    obs_iso = ""
    if isinstance(obs, (int, float)):
        obs_iso = datetime.fromtimestamp(obs, timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
    return t.get("count"), t.get("disputed"), obs_iso or str(obs)


def _read_product_slo_24h():
    """Return the sum of fleet_product_merged_24h gauges in the textfile."""
    try:
        lines = open(PRODUCT_SLO).read().splitlines()
    except OSError as exc:
        return None, f"unreadable: {exc}"
    total = 0.0
    for ln in lines:
        if ln.startswith("fleet_product_merged_24h"):
            # fleet_product_merged_24h{repo="0509"} 45
            try:
                total += float(ln.rsplit(None, 1)[1])
            except (IndexError, ValueError):
                pass
    return int(total), ""


def reconcile_tile():
    """Cross-check the shipped_24h tile value against measured merges."""
    tile, disputed, obs = _read_shipped_tile()
    exporter, xerr = _read_product_slo_24h()
    print("console shipped_24h tile — reconcile against measured merges")
    print(f"  tile.count          = {tile if tile is not None else 'n/a'}")
    print(f"  tile.disputed       = {disputed}")
    print(f"  tile.observed_at    = {obs}")
    print(f"  exporter 24h (slo)  = {exporter if exporter is not None else 'n/a'} ({xerr})")
    if tile is None or exporter is None:
        print("  result: UNKNOWN (tile or exporter unreadable)")
        return 2
    match = (tile == exporter)
    print(f"  tile==exporter      = {match}")
    if match:
        print("  result: RECONCILED — the tile agrees with its declared source")
        return 0
    print(
        f"  result: MISMATCH — tile {tile} vs exporter {exporter}; "
        "a lying or stale tile. Inspect fleet-product-slo cache/6h TTL."
    )
    return 1


# --- main -------------------------------------------------------------------

def _split(days: int, only: list[str] | None):
    self_set = set(_load_self_set())
    repos = only if only else _list_repos()
    if only:
        # --repo-only still needs the self classification; resolve self first.
        self_set = set(_load_self_set())
    by_repo = {}
    self_titles: list[str] = []
    self_total = 0
    product_total = 0
    print(f"fleet product-vs-self merge split — trailing {days}d (org {ORG})")
    print(f"anchor now: {_now().strftime('%Y-%m-%dT%H:%M:%SZ')}")
    print(f"self repos (config/self-maintenance-repos.json): {sorted(self_set)}")
    print()
    hdr = f"{'repo':<18}{'merges/'+str(days)+'d':>14}  class"
    print(hdr)
    print("-" * len(hdr))
    for repo in sorted(repos, key=str.lower):
        try:
            n, titles = _merged_per_repo(repo, days)
        except SystemExit as exc:
            print(f"{repo:<18}{'ERR':>14}  skipped ({str(exc)[:60]})")
            n, titles = 0, []
        by_repo[repo] = n
        cls = "self" if repo in self_set else "product"
        if cls == "self":
            self_total += n
            self_titles.extend(titles)
        else:
            product_total += n
        print(f"{repo:<18}{n:>14}  {cls}")
    total = self_total + product_total
    ratio = self_total / total if total else 0.0
    print()
    print(f"self merges   /{days}d: {self_total}")
    print(f"product merges/{days}d: {product_total}")
    print(f"total               : {total}")
    print(f"self/total ratio    : {ratio:.4f}")
    print(
        f"  ({'ABOVE 0.5' if ratio >= 0.5 else 'below 0.5'} — "
        "the product-first tripwire is 0.50)"
    )
    print()
    if self_titles:
        top, n = _top_classes(self_titles, 3)
        print(
            f"top-3 self-maintenance workload classes within {n} self merges:"
        )
        for label, count in top:
            print(f"  {count:5d}  {label} ({count/n*100:.1f}%)")
    return 0


def main(argv):
    days = DAYS
    only = None
    if "--help" in argv or "-h" in argv:
        print(__doc__)
        return 0
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--days":
            days = int(argv[i + 1]); i += 2
        elif a == "--repo-only":
            only = [s.strip() for s in argv[i + 1].split(",") if s.strip()]
            i += 2
        elif a == "--reconcile-tile":
            return reconcile_tile()
        else:
            raise SystemExit(f"unknown arg: {a}")
    return _split(days, only)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
