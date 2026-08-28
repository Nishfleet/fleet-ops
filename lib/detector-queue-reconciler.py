#!/usr/bin/env python3
"""Detector->queue reconciler + observe-to-close (fleet-ops#362).

Every LOUD alarm line in the heartbeat triage file is matched to an open
issue by a stable `signal:` key, or auto-filed, within one tick. Issues are
closed only when their alarm no longer appears (the detector reports green).

Usage:
  python3 lib/detector-queue-reconciler.py [OPTIONS]

Environment (all have --flag equivalents):
  FLEET_HEARTBEAT_TRIAGE         triage file path
  FLEET_SIGNAL_RECONCILE_TICK_START
                                 ISO timestamp; only lines at/after this are read
  FLEET_SIGNAL_RECONCILE_ISSUE_REPO  default Nishfleet/fleet-ops
  FLEET_SIGNAL_RECONCILE_CAP       default 5
  FLEET_SIGNAL_RECONCILE_FILE_ISSUES  1/0 (default 1)
  FLEET_SIGNAL_RECONCILE_OK_TO_CLOSE  1/0 (default 1)
  FLEET_SIGNAL_RECONCILE_STALL_HOURS  default 6
  FLEET_SIGNAL_RECONCILE_HEARTBEAT_COMMENT_MIN_HOURS  default 24
  FLEET_SIGNAL_RECONCILE_NOW       ISO timestamp override (tests)
  FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON  test override for gh list output
  FLEET_SIGNAL_RECONCILE_DRY_RUN   1/0 (default 0)
  FLEET_ISSUE_FILE                 path to fleet-issue-file wrapper
  GH                               default gh
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

GREEN_SUFFIXES = (
    "-OK",
    "-GREEN",
    "-RECOVERED",
    "-PARKED",
    "-COMPLETE",
    "-SKIP",
    "-FILED",
    "-AVAILABLE",
    "-DISPATCHED",
    "-RECONCILED",
    "-REROUTE",
)
GREEN_TAGS = {"THROUGHPUT", "ESCALATION-CANARY-EXCLUDED", "ESCALATION-CANARY-OK"}
SKIP_MSG_PREFIXES = ("rule-enforcement:",)
STOPWORDS = frozenset(
    """
    a an the to of and or in on for with this that is are be as at by from
    it its not no yes if then than so such into over after before between
    through during without vs via per our your we they you i but also just
    more most other some any all each every both same own too very about
    up out off down new old issue issues pr prs repo repos must should
    will can could may might do does did has have had been being was were
    """.split()
)

TRIAGE_RE = re.compile(
    r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\] "
    r"\[([A-Z][A-Z0-9_-]*)\] (.*)$"
)
SIGNAL_RE = re.compile(r"signal:\s*([^\s`]+)")
UNIT_EQ_RE = re.compile(r"(?:^|[\s,])unit=([A-Za-z0-9_@.:-]+\.(?:service|timer|path|socket|target|slice))")
UNIT_BARE_RE = re.compile(
    r"\b([A-Za-z0-9_@.:-]+\.(?:service|timer|path|socket|target|slice))\b"
)
REPO_RE = re.compile(r"\b(Nishfleet/[A-Za-z0-9_.-]+)\b")
BIN_RE = re.compile(r"\bbin/([A-Za-z0-9_.-]+)\b")
FILE_RE = re.compile(
    r"\b([A-Za-z0-9_.-]+\.(?:yml|yaml|json|py|sh|md|service|timer|path|socket|target|slice))\b"
)
DYNAMIC_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z|\d+h ago|\d+ days? ago|\d+ years? ago|age=\d+[^\s]*|n=\d+|state=[^\s]+|rc=\d+|\b\d+\b")


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{ts}] [detector-queue-reconciler] {msg}", file=sys.stderr)


def loud(triage: Path | None, tag: str, msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"[{ts}] [{tag}] {msg}"
    print(f"LOUD [{tag}] {msg}", file=sys.stderr)
    if triage is not None:
        try:
            with open(triage, "a", encoding="utf-8") as f:
                f.write(f"\n{line}\n")
        except OSError as e:
            log(f"WARN: could not append to triage {triage}: {e}")


def now_iso(now: str | None) -> str:
    if now:
        return now
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _safe_slug(text: str, length: int = 60) -> str:
    text = re.sub(r"[^a-z0-9_.-]", "-", text.lower())
    text = re.sub(r"-+", "-", text).strip("-.")
    return text[:length].rstrip("-.")


def _extract_signal_key(tag: str, msg: str) -> list[str]:
    m = SIGNAL_RE.search(msg)
    if m:
        sig = m.group(1).strip()
        if sig:
            return [sig]

    if tag == "UNIT-FAILED":
        units: list[str] = []
        if " :: " in msg:
            list_part = msg.split(" :: ", 1)[1]
            for u in re.split(r"[,\s]+", list_part):
                u = u.strip(" .")
                if u and u.endswith((".service", ".timer", ".path", ".socket", ".target", ".slice")):
                    units.append(u)
        if not units:
            for m in UNIT_EQ_RE.finditer(msg):
                units.append(m.group(1))
        if not units:
            for m in UNIT_BARE_RE.finditer(msg):
                units.append(m.group(1))
        return [_safe_slug(u, 80) for u in dict.fromkeys(units)]

    tokens: list[str] = []
    for m in UNIT_EQ_RE.finditer(msg):
        tokens.append(m.group(1))
    for m in REPO_RE.finditer(msg):
        tokens.append(m.group(1))
    for m in BIN_RE.finditer(msg):
        tokens.append(f"bin/{m.group(1)}")
    for m in FILE_RE.finditer(msg):
        tokens.append(m.group(1))
    for m in UNIT_BARE_RE.finditer(msg):
        if m.group(1) not in tokens:
            tokens.append(m.group(1))

    if len(tokens) == 1:
        return [_safe_slug(tokens[0], 80)]
    if tokens:
        return [_safe_slug(tokens[0], 80)]

    phrase = msg
    for sep in (" — ", "::", ";", "("):
        if sep in phrase:
            phrase = phrase.split(sep, 1)[0]
    phrase = re.sub(r"[()#]", " ", phrase)
    phrase = DYNAMIC_RE.sub(" ", phrase)
    words = [
        w
        for w in re.split(r"[^a-z0-9_.-/]+", phrase.lower())
        if w and w not in STOPWORDS and len(w) > 1
    ]
    if not words:
        return ["unspecified"]
    key = "-".join(words[:6])
    return [_safe_slug(key, 80) or "unspecified"]


def derive_signals(tag: str, msg: str) -> list[str]:
    if tag in GREEN_TAGS or tag.endswith(GREEN_SUFFIXES):
        return []
    for prefix in SKIP_MSG_PREFIXES:
        if msg.startswith(prefix):
            return []
    m = SIGNAL_RE.search(msg)
    if m:
        sig = m.group(1).strip()
        if sig:
            return [sig]
    subkeys = _extract_signal_key(tag, msg)
    tag_slug = tag.lower()
    if subkeys == ["unspecified"]:
        return [f"loud/{tag_slug}"]
    return [f"loud/{tag_slug}/{k}" for k in subkeys]


def parse_triage(path: Path, tick_start: str | None) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    if not path.is_file():
        return out
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            m = TRIAGE_RE.match(line)
            if not m:
                continue
            ts, tag, msg = m.group(1), m.group(2), m.group(3)
            if tick_start and ts < tick_start:
                continue
            out.append({"ts": ts, "tag": tag, "msg": msg})
    return out


def routing_labels(tag: str) -> list[str]:
    senior = (
        tag.endswith(("-VIOLATION", "-FAIL", "-BROKEN", "-ESCALATE"))
        or tag.startswith((
            "HELPER-MISSING",
            "SEAT-HEALTH",
            "BLIND-AUDIT-",
            "GAP-LOOP-",
            "RESURRECTION-",
            "BARE-METAL-",
            "TAILSCALE-",
            "KEYSTONE-",
            "SEAT-LIVE-VALIDATE-",
            "DEPLOY-BLOCKED",
            "TIMER-START-FAIL",
        ))
        or tag in {"UNIT-ESCALATE"}
    )
    if senior:
        return ["escalate-senior", "critical-path"]
    return ["agent-ready"]


def issue_title(tag: str, msg: str) -> str:
    short = re.sub(r"^signal:\s*\S+\s*", "", msg)
    short = short.split(" — ", 1)[0].split("::", 1)[0].strip()
    if len(short) > 80:
        short = short[:77] + "..."
    return f"alarm: {tag} — {short}"


def issue_body(signal: str, tag: str, msg: str, ts: str) -> str:
    return (
        "The heartbeat detector reported this alarm on a real tick and no open "
        "issue carried its signal key, so the detector→queue reconciler filed one.\n\n"
        f"- alarm tag: `{tag}`\n"
        f"- evidence: {msg}\n"
        f"- observed tick: `{ts}`\n"
        f"- detector→queue reconciler: fleet-ops#362\n\n"
        "Do NOT close this issue on PR merge alone. "
        "The reconciler closes it only when the detector reports green on a real "
        "heartbeat tick (observe-to-close).\n\n"
        f"`{signal}`\n"
    )


def find_existing_signal(issues: list[dict[str, Any]], signal: str) -> dict[str, Any] | None:
    for issue in issues:
        body = (issue.get("body") or "") + "\n" + "\n".join(
            str(c.get("body") or "") for c in (issue.get("comments") or [])
        )
        if f"{signal}\n" in body or body.endswith(signal):
            return issue
    return None


def has_recent_heartbeat_comment(issue: dict[str, Any], now: datetime, min_hours: int) -> bool:
    marker = "detector heartbeat: still alarmed"
    for comment in issue.get("comments") or []:
        body = comment.get("body") or ""
        if marker not in body:
            continue
        created = comment.get("createdAt") or ""
        if not created:
            continue
        try:
            cdt = datetime.fromisoformat(created.replace("Z", "+00:00"))
        except ValueError:
            continue
        if (now - cdt).total_seconds() < min_hours * 3600:
            return True
    return False


def load_open_issues(
    repo: str,
    gh: str,
    from_json: str | None,
) -> list[dict[str, Any]]:
    if from_json:
        return json.loads(Path(from_json).read_text(encoding="utf-8"))
    proc = subprocess.run(
        [
            gh,
            "issue",
            "list",
            "-R",
            repo,
            "--state",
            "open",
            "--limit",
            "300",
            "--json",
            "number,title,body,labels,createdAt,comments",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or not (proc.stdout or "").strip():
        log(f"WARN: could not list open issues (rc={proc.returncode})")
        return []
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        log("WARN: could not parse open issues JSON")
        return []


def gh_comment(repo: str, number: int, body: str, gh: str, dry_run: bool) -> bool:
    if dry_run:
        log(f"dry-run: would comment #{number} on {repo}")
        return True
    proc = subprocess.run(
        [gh, "issue", "comment", str(number), "-R", repo, "--body", body],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode == 0


def gh_close(repo: str, number: int, body: str, gh: str, dry_run: bool) -> bool:
    if dry_run:
        log(f"dry-run: would close #{number} on {repo}")
        return True
    proc = subprocess.run(
        [gh, "issue", "close", str(number), "-R", repo, "--reason", "completed", "--comment", body],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode == 0


def gh_edit_labels(repo: str, number: int, add: list[str], remove: list[str], gh: str, dry_run: bool) -> bool:
    if dry_run:
        log(f"dry-run: would edit labels on #{number}: +{add} -{remove}")
        return True
    cmd = [gh, "issue", "edit", str(number), "-R", repo]
    for label in add:
        cmd += ["--add-label", label]
    for label in remove:
        cmd += ["--remove-label", label]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return proc.returncode == 0


def file_issue(
    repo: str,
    title: str,
    body: str,
    labels: list[str],
    issue_file: str,
    dry_run: bool,
) -> tuple[int, str]:
    if dry_run:
        log(f"dry-run: would file in {repo}: {title}")
        return 0, "dry-run"
    cmd = [issue_file, "file", "-R", repo, "--title", title, "--body", body]
    for label in labels:
        cmd += ["--label", label]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return proc.returncode, (proc.stdout or proc.stderr or "").strip()


def _parse_iso(ts: str) -> datetime:
    raw = ts.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    return datetime.fromisoformat(raw)


def reconcile(
    alarms: list[dict[str, str]],
    open_issues: list[dict[str, Any]],
    repo: str,
    cap: int,
    file_issues: bool,
    ok_to_close: bool,
    stall_hours: int,
    comment_min_hours: int,
    now_str: str,
    gh: str,
    issue_file: str,
    triage: Path | None,
    dry_run: bool,
) -> dict[str, Any]:
    now = _parse_iso(now_str)
    summary: dict[str, Any] = {
        "alarm_count": 0,
        "filed": 0,
        "deduped": 0,
        "heartbeat_comments": 0,
        "closed": 0,
        "rerouted": 0,
        "capped": 0,
    }

    # Build current signal set and signal -> alarm map.
    current_signals: set[str] = set()
    signal_to_alarm: dict[str, dict[str, str]] = {}
    for alarm in alarms:
        for sig in derive_signals(alarm["tag"], alarm["msg"]):
            if sig in current_signals:
                continue
            current_signals.add(sig)
            signal_to_alarm[sig] = alarm

    summary["alarm_count"] = len(current_signals)
    open_by_signal: dict[str, dict[str, Any]] = {}
    for issue in open_issues:
        body = issue.get("body") or ""
        for m in SIGNAL_RE.finditer(body):
            sig = m.group(1).strip()
            if sig:
                open_by_signal[sig] = issue

    # File or heartbeat-comment.
    filed_count = 0
    capped_sigs: list[str] = []
    for sig in sorted(current_signals):
        alarm = signal_to_alarm[sig]
        existing = open_by_signal.get(sig)
        if existing:
            summary["deduped"] += 1
            if not has_recent_heartbeat_comment(existing, now, comment_min_hours):
                comment_body = (
                    f"detector heartbeat: still alarmed for `{sig}` "
                    f"at {alarm['ts']} — alarm is still live.\n\n"
                    "Do not close this until the detector reports green."
                )
                if gh_comment(repo, existing["number"], comment_body, gh, dry_run):
                    summary["heartbeat_comments"] += 1
                    log(f"heartbeat: #{existing['number']} touched for {sig}")
                else:
                    log(f"WARN: failed to comment #{existing['number']} for {sig}")
            continue

        if filed_count >= cap:
            capped_sigs.append(sig)
            summary["capped"] += 1
            continue

        if not file_issues:
            log(f"skip filing {sig} (FILE_ISSUES=0)")
            continue

        title = issue_title(alarm["tag"], alarm["msg"])
        body = issue_body(sig, alarm["tag"], alarm["msg"], alarm["ts"])
        labels = routing_labels(alarm["tag"])
        rc, out = file_issue(repo, title, body, labels, issue_file, dry_run)
        if rc == 0:
            log(f"filed {sig} -> {out}")
            filed_count += 1
            summary["filed"] += 1
        else:
            log(f"WARN: failed to file {sig} (rc={rc}): {out}")

    if capped_sigs:
        loud(triage, "SIGNAL-RECONCILE-CAP", f"auto-file cap reached ({cap}); unfiled signals: {', '.join(capped_sigs)}")

    # Observe-to-close: close open signal-keyed issues not in current tick.
    current_open_signals = set(open_by_signal.keys())
    for sig in sorted(current_open_signals - current_signals):
        issue = open_by_signal[sig]
        if ok_to_close:
            body = (
                f"observe-to-close: detector no longer reports `{sig}` "
                f"at {now_str} — detector reports green on this heartbeat tick."
            )
            if gh_close(repo, issue["number"], body, gh, dry_run):
                log(f"closed #{issue['number']} (signal={sig} no longer in tick)")
                summary["closed"] += 1
            else:
                log(f"WARN: failed to close #{issue['number']} (signal={sig})")
        else:
            log(f"observe-to-close: skipped #{issue['number']} (signal={sig} OK_TO_CLOSE=0)")

    # Unclaimed-stall reroute.
    if file_issues and ok_to_close:
        stall_cutoff = now - timedelta(hours=stall_hours)
        for sig, issue in open_by_signal.items():
            if sig not in current_signals:
                continue
            labels = [str(l.get("name")) for l in issue.get("labels") or [] if l.get("name")]
            if "agent-ready" not in labels:
                continue
            created = issue.get("createdAt") or ""
            if not created:
                continue
            try:
                cdt = _parse_iso(created)
            except ValueError:
                continue
            if cdt > stall_cutoff:
                continue
            if gh_edit_labels(repo, issue["number"], ["escalate-senior"], ["agent-ready"], gh, dry_run):
                loud(triage, "SIGNAL-RECONCILE-REROUTE", f"issue #{issue['number']} (signal={sig}) unclaimed past {stall_hours}h — re-routed agent-ready -> escalate-senior")
                summary["rerouted"] += 1
            else:
                log(f"WARN: failed to reroute #{issue['number']} (signal={sig})")

    return summary


def find_repo_root() -> Path:
    here = Path(__file__).resolve().parent
    return here.parent


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--triage", default="")
    p.add_argument("--tick-start", default="")
    p.add_argument("--repo", default="")
    p.add_argument("--cap", type=int, default=None)
    p.add_argument("--file-issues", type=int, default=None)
    p.add_argument("--ok-to-close", type=int, default=None)
    p.add_argument("--stall-hours", type=int, default=None)
    p.add_argument("--comment-min-hours", type=int, default=None)
    p.add_argument("--now", default="")
    p.add_argument("--open-issues-json", default="")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--json", action="store_true", help="emit JSON summary")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    triage_path = Path(
        args.triage
        or os.environ.get("FLEET_HEARTBEAT_TRIAGE")
        or "/home/nish/workspaces/agent-state/FLEET-HEARTBEAT-TRIAGE.md"
    )
    tick_start = args.tick_start or os.environ.get("FLEET_SIGNAL_RECONCILE_TICK_START")
    repo = args.repo or os.environ.get("FLEET_SIGNAL_RECONCILE_ISSUE_REPO") or "Nishfleet/fleet-ops"
    cap = args.cap if args.cap is not None else int(os.environ.get("FLEET_SIGNAL_RECONCILE_CAP") or 5)
    file_issues = (
        bool(args.file_issues)
        if args.file_issues is not None
        else os.environ.get("FLEET_SIGNAL_RECONCILE_FILE_ISSUES", "1") == "1"
    )
    ok_to_close = (
        bool(args.ok_to_close)
        if args.ok_to_close is not None
        else os.environ.get("FLEET_SIGNAL_RECONCILE_OK_TO_CLOSE", "0") == "1"
    )
    stall_hours = args.stall_hours if args.stall_hours is not None else int(os.environ.get("FLEET_SIGNAL_RECONCILE_STALL_HOURS") or 6)
    comment_min_hours = (
        args.comment_min_hours
        if args.comment_min_hours is not None
        else int(os.environ.get("FLEET_SIGNAL_RECONCILE_HEARTBEAT_COMMENT_MIN_HOURS") or 24)
    )
    now = now_iso(args.now or os.environ.get("FLEET_SIGNAL_RECONCILE_NOW"))
    open_issues_json = args.open_issues_json or os.environ.get("FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON")
    dry_run = args.dry_run or os.environ.get("FLEET_SIGNAL_RECONCILE_DRY_RUN") == "1"
    gh = os.environ.get("GH", "gh")

    repo_root = find_repo_root()
    issue_file = os.environ.get("FLEET_ISSUE_FILE")
    if not issue_file:
        for candidate in [
            repo_root / "bin" / "fleet-issue-file",
            Path.home() / ".local" / "bin" / "fleet-issue-file",
            repo_root.parent / "bin" / "fleet-issue-file",
        ]:
            if candidate.is_file():
                issue_file = str(candidate)
                break
    if not issue_file:
        log("WARN: fleet-issue-file not found; auto-file disabled")
        file_issues = False

    log(
        f"starting (repo={repo} cap={cap} file={file_issues} close={ok_to_close} "
        f"tick_start={tick_start or 'ALL'} dry_run={dry_run})"
    )

    alarms = parse_triage(triage_path, tick_start)
    open_issues: list[dict[str, Any]] = []
    if (file_issues or ok_to_close) and not dry_run:
        open_issues = load_open_issues(repo, gh, open_issues_json)
    elif open_issues_json:
        open_issues = load_open_issues(repo, gh, open_issues_json)

    summary = reconcile(
        alarms,
        open_issues,
        repo,
        cap,
        file_issues,
        ok_to_close,
        stall_hours,
        comment_min_hours,
        now,
        gh,
        issue_file or "fleet-issue-file",
        triage_path if not dry_run else None,
        dry_run,
    )

    log(
        f"complete: alarms={summary['alarm_count']} filed={summary['filed']} "
        f"deduped={summary['deduped']} heartbeat={summary['heartbeat_comments']} "
        f"closed={summary['closed']} rerouted={summary['rerouted']} capped={summary['capped']}"
    )
    if args.json:
        print(json.dumps(summary, sort_keys=True))

    if summary["capped"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
