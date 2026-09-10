#!/usr/bin/env python3
"""Analyse the fleet-ops#4804 CPU sampler output.

Reads the JSONL produced by libexec/fleet-cpu-sampler.py and produces the
four numbers the issue's termination requires:

  1. CPU share by command class (tsc, vitest+workerd, wrangler/esbuild,
     node build, git, gh, pi/cursor-agent, other) — % of worker-worktree CPU.
  2. CPU-seconds per merged PR — total worker-worktree CPU-seconds over the
     window divided by the number of PRs merged in the same window.
  3. Saturated-with-backlog hours — hours where load1 > 2x cores AND ready > 20.
  4. Control — the same numbers for a 24h window 7 days earlier, or "no control".

Merged-PR timestamps come from gh (one call per repo, cached). The sampler
records cumulative per-process CPU-seconds; this script joins consecutive
samples to get per-interval CPU (the delta between two samples).

Usage:
  python3 libexec/fleet-cpu-analysis.py <sampler.jsonl> [--control <jsonl>]

Stdlib only.
"""
import argparse
import calendar
import json
import os
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

CORES = os.cpu_count() or 8
READY_THRESHOLD = 20
SATURATED_LOAD = 2 * CORES  # load1 > 2x cores
GH_OWNER = "Nishfleet"
GH_TIMEOUT = 45
# Repos with worker merges in the study snapshot (fleet-ops#4804). The issue's
# "one call per repo" rule: one gh call per entry here.
GH_REPOS = ("fleet-ops", "0509")


def _load_samples(path):
    samples = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                samples.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return samples


def _merged_prs(start_ts, end_ts):
    """Return {repo: [mergedAt_epoch, ...]} for PRs merged in [start_ts, end_ts].

    One gh call per repo (the issue's "one call per repo" rule). Uses
    `gh pr list --state merged --search "merged:>=.. merged:<=.."` per repo and
    parses mergedAt as UTC (calendar.timegm, not time.mktime which is local).
    Cached to a temp file so a re-run does not burn the API budget.
    """
    cache = Path("/tmp/fleet-cpu-analysis-merged.json")
    if cache.exists() and time.time() - cache.stat().st_mtime < 1800:
        try:
            cached = json.loads(cache.read_text())
            if str(start_ts) in cached:
                return cached[str(start_ts)]
        except (OSError, json.JSONDecodeError):
            pass
    start_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start_ts))
    end_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(end_ts))
    result = {}
    for repo in GH_REPOS:
        try:
            out = subprocess.run(
                ["gh", "pr", "list", "-R", f"{GH_OWNER}/{repo}",
                 "--state", "merged",
                 "--search", f"merged:>={start_iso} merged:<={end_iso}",
                 "--json", "mergedAt,number", "--limit", "500"],
                capture_output=True, text=True, timeout=GH_TIMEOUT,
            )
            if out.returncode != 0:
                continue
            for pr in json.loads(out.stdout or "[]"):
                merged = pr.get("mergedAt")
                if not merged:
                    continue
                try:
                    ts = calendar.timegm(time.strptime(merged[:19], "%Y-%m-%dT%H:%M:%S"))
                except ValueError:
                    continue
                if start_ts <= ts <= end_ts:
                    result.setdefault(f"{GH_OWNER}/{repo}", []).append(ts)
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
            continue
    try:
        prev = {}
        if cache.exists():
            try:
                prev = json.loads(cache.read_text())
            except (OSError, json.JSONDecodeError):
                prev = {}
        prev[str(start_ts)] = result
        cache.write_text(json.dumps(prev))
    except OSError:
        pass
    return result


def _per_interval_cpu(samples):
    """Return list of {ts, cpu_by_class, cpu_total, load1, ready} per interval.

    CPU per interval = delta of cumulative per-process CPU-seconds between
    consecutive samples, summed across worktrees and grouped by class.
    """
    intervals = []
    prev = None
    for s in samples:
        if prev is None:
            prev = s
            continue
        dt = s["ts"] - prev["ts"]
        if dt <= 0:
            prev = s
            continue
        # Delta per class across all worktrees.
        delta = defaultdict(float)
        for wt, classes in s.get("procs", {}).items():
            for cls, cpu in classes.items():
                prev_cpu = prev.get("procs", {}).get(wt, {}).get(cls, 0.0)
                d = cpu - prev_cpu
                if d > 0:
                    delta[cls] += d
        intervals.append({
            "ts": s["ts"],
            "cpu_by_class": dict(delta),
            "cpu_total": sum(delta.values()),
            "load1": s.get("load1"),
            "ready": s.get("ready", 0),
        })
        prev = s
    return intervals


def _analyse(samples, label):
    intervals = _per_interval_cpu(samples)
    if not intervals:
        return None
    # CPU share by class.
    class_total = defaultdict(float)
    for iv in intervals:
        for cls, cpu in iv["cpu_by_class"].items():
            class_total[cls] += cpu
    total_cpu = sum(class_total.values())
    share = {cls: round(100.0 * c / total_cpu, 2) for cls, c in class_total.items()} if total_cpu else {}
    # Saturated-with-backlog hours: load1 > 2x cores AND ready > 20.
    sat_secs = 0
    for i in range(len(intervals)):
        iv = intervals[i]
        if iv["load1"] is not None and iv["load1"] > SATURATED_LOAD and iv["ready"] > READY_THRESHOLD:
            dt = 60
            if i > 0:
                dt = iv["ts"] - intervals[i - 1]["ts"]
            sat_secs += max(1, dt)
    sat_hours = round(sat_secs / 3600.0, 2)
    # Merged PRs in window.
    start_ts = intervals[0]["ts"]
    end_ts = intervals[-1]["ts"]
    merged = _merged_prs(start_ts, end_ts)
    total_merged = sum(len(v) for v in merged.values())
    cpu_per_merge = round(total_cpu / total_merged, 2) if total_merged else None
    return {
        "label": label,
        "window_s": end_ts - start_ts,
        "cpu_share_by_class": share,
        "cpu_total_s": round(total_cpu, 2),
        "merged_prs": total_merged,
        "cpu_s_per_merge": cpu_per_merge,
        "saturated_with_backlog_hours": sat_hours,
        "samples": len(intervals),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sampler_jsonl")
    ap.add_argument("--control", help="sampler JSONL from 7 days earlier")
    args = ap.parse_args()
    samples = _load_samples(args.sampler_jsonl)
    if not samples:
        print("no samples in %s" % args.sampler_jsonl, file=sys.stderr)
        return 1
    result = _analyse(samples, "study")
    if result is None:
        print("not enough samples (need >=2)", file=sys.stderr)
        return 1
    if args.control:
        ctrl = _load_samples(args.control)
        result["control"] = _analyse(ctrl, "control") if ctrl else None
    else:
        result["control"] = "no control"
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
