#!/usr/bin/env python3
"""Sample host CPU + worker-worktree process CPU for 24h at 60s (fleet-ops#4804).

Population-first measurement: this sampler MEASURES before anything changes.
It runs as ONE pi-systemd-run unit (--deadline 1500 = 25h) and exits on its
own after 24h. No timer, no dispatcher.

Per sample (every 60s) it records:
  - ts            epoch seconds
  - load1         /proc/loadavg 1-min load
  - idle_pct      %idle since the previous sample (from /proc/stat deltas)
  - iowait_pct    %iowait since the previous sample
  - procs         per-process CPU-seconds (utime+stime) attributed to a worker
                  worktree (cmdline contains agent-worktrees/), grouped by
                  command class. Each entry: {worktree, class, cpu_s}.
  - ready         open agent-ready issues across enrolled repos (best-effort,
                  from the fleet-metrics ready-work cache if fresh, else 0)

Command classes (fleet-ops#4804): tsc, vitest+workerd, wrangler/esbuild,
node build, git, gh, pi/cursor-agent, other.

Output: one JSONL line per sample appended to
  $AGENT_STATE/fleet-metrics/cpu-sampler-<start-epoch>.jsonl
(default AGENT_STATE=/home/nish/workspaces/agent-state).

Stdlib only. Exits 0 on its own after DURATION_S (default 24h).
"""
import json
import os
import sys
import time
from pathlib import Path

DURATION_S = int(os.environ.get("FLEET_CPU_SAMPLER_DURATION_S", str(24 * 3600)))
INTERVAL_S = int(os.environ.get("FLEET_CPU_SAMPLER_INTERVAL_S", "60"))
AGENT_STATE = Path(
    os.environ.get("AGENT_STATE", "/home/nish/workspaces/agent-state")
)
OUT_DIR = AGENT_STATE / "fleet-metrics"
# Optional fixed output path (used by the detached pi-systemd-run unit so the
# --deliverable matches the actual file). Default: cpu-sampler-<start-epoch>.jsonl.
OUT_OVERRIDE = os.environ.get("FLEET_CPU_SAMPLER_OUT", "")
READY_CACHE = OUT_DIR / "ready-work-cache.json"
WORKTREE_MARK = "/agent-worktrees/"

# Command-class classifier. Order matters: more specific first.
_CLASS_RULES = (
    ("tsc", lambda c: "tsc" in c),
    ("vitest+workerd", lambda c: "vitest" in c or "workerd" in c),
    ("wrangler/esbuild", lambda c: "wrangler" in c or "esbuild" in c),
    ("node build", lambda c: any(
        k in c for k in ("vite build", "react-router typegen", "npm run build",
                         "typecheck", "tsc -b", "tsc --build", "rollup")
    )),
    ("git", lambda c: c.startswith("git ")),
    ("gh", lambda c: c.startswith("gh ")),
    ("pi/cursor-agent", lambda c: any(
        k in c for k in ("cursor-agent", "ccd-cli", "/pi ", " pi ", "pi --print")
    )),
)


def _classify(cmdline: str) -> str:
    for name, rule in _CLASS_RULES:
        if rule(cmdline):
            return name
    return "other"


def _read_cpu_totals():
    """Return (user, nice, system, idle, iowait) jiffies from /proc/stat."""
    try:
        with open("/proc/stat") as f:
            for line in f:
                if line.startswith("cpu "):
                    parts = line.split()
                    # cpu user nice system idle iowait irq softirq steal
                    return (
                        int(parts[1]), int(parts[2]), int(parts[3]),
                        int(parts[4]), int(parts[5]),
                    )
    except (OSError, ValueError, IndexError):
        return None
    return None


def _read_ready():
    """Best-effort ready-work count from the fleet-metrics cache (fresh <= 2h)."""
    try:
        data = json.loads(READY_CACHE.read_text())
        ts = data.get("ts", 0)
        if time.time() - ts <= 7200:
            return int(data.get("ready", 0))
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        pass
    return 0


def _sample_procs():
    """Return {worktree: {class: cpu_s}} for worker-worktree processes.

    Reads /proc/<pid>/stat for utime+stime (jiffies), /proc/<pid>/cwd for the
    worktree directory (the reliable attribution — the process's cwd IS the
    worktree), and /proc/<pid>/cmdline for command-class classification. A
    process is attributed to a worktree when its cwd resolves under
    agent-worktrees/. CPU seconds are the process's cumulative utime+stime
    (not a delta) — the analysis joins consecutive samples to get per-interval
    CPU.
    """
    clk = os.sysconf("SC_CLK_TCK") or 100
    out = {}
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return out
    for pid in pids:
        try:
            with open(f"/proc/{pid}/stat") as f:
                stat = f.read()
        except OSError:
            continue
        # stat fields: pid (comm) state ppid ... utime stime ...
        # comm may contain spaces/parens; split on the LAST ')'.
        try:
            rparen = stat.rindex(")")
            rest = stat[rparen + 2:].split()
            # rest[0]=state, rest[11]=utime, rest[12]=stime
            utime = int(rest[11])
            stime = int(rest[12])
        except (ValueError, IndexError):
            continue
        # Worktree attribution from cwd (reliable).
        try:
            cwd = os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            continue
        if WORKTREE_MARK not in cwd:
            continue
        idx = cwd.find(WORKTREE_MARK)
        start = idx + len(WORKTREE_MARK)
        end = cwd.find("/", start)
        wt = cwd[start:end] if end != -1 else cwd[start:]
        if not wt:
            continue
        # Command class from cmdline.
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                raw = f.read()
        except OSError:
            continue
        cmdline = raw.replace(b"\x00", b" ").decode("utf-8", "replace").strip()
        cls = _classify(cmdline) if cmdline else "other"
        cpu_s = (utime + stime) / clk
        d = out.setdefault(wt, {})
        d[cls] = d.get(cls, 0.0) + cpu_s
    return out


def main():
    out_dir = OUT_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    start = int(time.time())
    out_path = Path(OUT_OVERRIDE) if OUT_OVERRIDE else out_dir / f"cpu-sampler-{start}.jsonl"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    prev = _read_cpu_totals()
    deadline = time.time() + DURATION_S
    with open(out_path, "a") as f:
        while time.time() < deadline:
            now = int(time.time())
            cur = _read_cpu_totals()
            idle_pct = iowait_pct = None
            if prev and cur:
                total = sum(cur) - sum(prev)
                if total > 0:
                    idle_pct = round(100.0 * (cur[3] - prev[3]) / total, 2)
                    iowait_pct = round(100.0 * (cur[4] - prev[4]) / total, 2)
            prev = cur
            rec = {
                "ts": now,
                "load1": _read_load1(),
                "idle_pct": idle_pct,
                "iowait_pct": iowait_pct,
                "ready": _read_ready(),
                "procs": _sample_procs(),
            }
            f.write(json.dumps(rec) + "\n")
            f.flush()
            os.fsync(f.fileno())
            # Sleep in small steps so a SIGTERM (deadline) is honoured promptly.
            slept = 0
            while slept < INTERVAL_S and time.time() < deadline:
                time.sleep(min(5, INTERVAL_S - slept))
                slept += 5
    print(f"sampler done: {out_path} samples over {DURATION_S}s", file=sys.stderr)
    return 0


def _read_load1():
    try:
        with open("/proc/loadavg") as f:
            return float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


if __name__ == "__main__":
    sys.exit(main())
