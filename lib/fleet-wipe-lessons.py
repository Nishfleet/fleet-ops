#!/usr/bin/env python3
"""Fleet-wipe lesson gates (fleet-ops#533).

Standing rule (Nish, 2026-08-23): Lessons from the 2026-08-23 fleet wipe.

Two lessons were still prose when this landed:

  1. Verify identity with argv[0]/argv[1], never a substring of the full
     command line. ``pgrep -f`` matches its own argv and any later
     argument that merely carries a path.
  2. Push before deleting a worktree. ``git cherry`` and "ahead of main"
     both lie about squash-merged work; the question that protects you
     is whether HEAD is on origin.

FLEET-PAUSED as code is the heartbeat timer-arm skip (see
bin/fleet-heartbeat-tier1 block 5), not this binary.

Usage:
  fleet-wipe-lessons-check scan [--root DIR]
  fleet-wipe-lessons-check argv-running NAME
  fleet-wipe-lessons-check count-argv NAME [--has FLAG VALUE]
  fleet-wipe-lessons-check worktree-remove PATH

Exit codes:
  0 — clean / process found / worktree removed / count printed
  1 — violation / process not found / worktree refused
  2 — usage error / bad input
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

PROG = "fleet-wipe-lessons-check"

# Short-option clusters that include -f/--full (full command line), but
# not -F/--pidfile.  Combined clusters like -af / -lf still count.
PGREP_CMDS = re.compile(r"\b(pgrep|pkill|pidwait)\b")
PS_PIPE_GREP = re.compile(r"\bps\b[^#\n]*\|\s*grep\b")

SKIP_NAME_RE = re.compile(r"fleet-wipe-lessons")


def _die(msg: str, code: int = 2) -> None:
    print(f"{PROG}: {msg}", file=sys.stderr)
    raise SystemExit(code)


def code_only(line: str) -> str:
    """Drop quoted strings and a trailing bash comment so docs don't trip."""
    no_str = re.sub(r'"([^"\\]|\\.)*"', '""', line)
    no_str = re.sub(r"'[^']*'", "''", no_str)
    return no_str.split("#", 1)[0]


def _short_opts_have_full(token: str) -> bool:
    if not token.startswith("-") or token.startswith("--"):
        return False
    letters = token[1:]
    # -F is --pidfile; strip F so it does not look like -f.
    return "f" in letters.replace("F", "")


def line_has_full_cmdline_match(line: str) -> bool:
    """True if the code (not comment) uses pgrep/pkill -f or ps|grep."""
    code = code_only(line)
    if PS_PIPE_GREP.search(code):
        return True
    for match in PGREP_CMDS.finditer(code):
        rest = code[match.end() :]
        tokens = rest.split()
        for token in tokens:
            if not token.startswith("-"):
                break
            if token in ("-f", "--full") or _short_opts_have_full(token):
                return True
    return False


def scan_tree(root: Path) -> list[str]:
    """Scan bin/ and lib/ for substring process matching."""
    findings: list[str] = []
    for sub in ("bin", "lib"):
        base = root / sub
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file():
                continue
            if SKIP_NAME_RE.search(path.name):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            rel = path.relative_to(root)
            for idx, line in enumerate(text.splitlines(), start=1):
                if line_has_full_cmdline_match(line):
                    findings.append(f"{rel}:{idx}: substring cmdline match: {line.strip()}")
    return findings


def argv_of(pid: int) -> list[str] | None:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return None
    parts = raw.split(b"\0")
    return [p.decode("utf-8", "surrogateescape") for p in parts if p]


def _identity_match(argv: list[str], name: str) -> bool:
    want = Path(name).name
    return any(Path(arg).name == want for arg in argv[:2])


def _has_flag_value(argv: list[str], flag: str, value: str) -> bool:
    for i in range(len(argv) - 1):
        if argv[i] == flag and argv[i + 1] == value:
            return True
    return False


def iter_matching(name: str, has: tuple[str, str] | None = None) -> list[int]:
    """PIDs whose argv[0]/argv[1] basename is NAME, optionally with FLAG VALUE."""
    skip = {os.getpid()}
    found: list[int] = []
    try:
        proc_iter = Path("/proc").iterdir()
    except OSError as exc:
        _die(f"cannot read /proc: {exc}")
    for proc in proc_iter:
        if not proc.name.isdigit():
            continue
        pid = int(proc.name)
        if pid in skip:
            continue
        argv = argv_of(pid)
        if not argv:
            continue
        if not _identity_match(argv, name):
            continue
        if has is not None and not _has_flag_value(argv, has[0], has[1]):
            continue
        found.append(pid)
    return found


def argv_running(name: str, skip_pids: set[int] | None = None) -> bool:
    """True if some process has NAME as the basename of argv[0] or argv[1]."""
    extra = set(skip_pids or ())
    return any(pid not in extra for pid in iter_matching(name))


def _run_git(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(cwd), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def head_sha_on_origin(worktree: Path) -> tuple[bool, str]:
    """Return (HEAD is a tip of some origin ref, HEAD sha). Fail closed."""
    head = _run_git(worktree, "rev-parse", "HEAD")
    if head.returncode != 0:
        _die(f"not a git worktree: {worktree}: {head.stderr.strip()}")
    sha = head.stdout.strip()
    remote = _run_git(worktree, "ls-remote", "origin")
    if remote.returncode != 0:
        print(
            f"{PROG}: origin unreachable — refusing delete ({remote.stderr.strip()})",
            file=sys.stderr,
        )
        return False, sha
    for line in remote.stdout.splitlines():
        if not line.strip():
            continue
        remote_sha = line.split()[0]
        if remote_sha == sha:
            return True, sha
    return False, sha


def git_common_workdir(worktree: Path) -> Path:
    common = _run_git(worktree, "rev-parse", "--git-common-dir")
    if common.returncode != 0:
        _die(f"cannot resolve git common dir: {common.stderr.strip()}")
    common_path = Path(common.stdout.strip())
    if not common_path.is_absolute():
        common_path = (worktree / common_path).resolve()
    if common_path.name == ".git":
        return common_path.parent
    return common_path


def worktree_remove(worktree: Path) -> int:
    worktree = worktree.resolve()
    if not worktree.exists():
        _die(f"worktree path does not exist: {worktree}")
    on_origin, sha = head_sha_on_origin(worktree)
    if not on_origin:
        print(
            f"{PROG}: REFUSE worktree-remove {worktree}: "
            f"HEAD {sha} is not on origin — push before deleting",
            file=sys.stderr,
        )
        return 1
    parent = git_common_workdir(worktree)
    result = _run_git(parent, "worktree", "remove", str(worktree))
    if result.returncode != 0:
        print(
            f"{PROG}: git worktree remove failed: {result.stderr.strip()}",
            file=sys.stderr,
        )
        return 1
    print(f"{PROG}: removed {worktree} (HEAD {sha} is on origin)", file=sys.stderr)
    return 0


def cmd_scan(root: Path) -> int:
    findings = scan_tree(root)
    if findings:
        for row in findings:
            print(f"{PROG}: {row}", file=sys.stderr)
        print(
            f"{PROG}: REJECT {len(findings)} substring cmdline match(es). "
            "Match argv[0]/argv[1] via `argv-running`.",
            file=sys.stderr,
        )
        return 1
    print(f"{PROG}: scan clean under {root}", file=sys.stderr)
    return 0


def cmd_argv_running(name: str) -> int:
    if argv_running(name):
        return 0
    print(f"{PROG}: no process with argv[0]/argv[1] basename {name!r}", file=sys.stderr)
    return 1


def cmd_count_argv(name: str, has: tuple[str, str] | None) -> int:
    n = len(iter_matching(name, has=has))
    print(str(n))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog=PROG,
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    scan_p = sub.add_parser("scan", help="reject pgrep -f / pkill -f / ps|grep in bin/ and lib/")
    scan_p.add_argument("--root", type=Path, default=None, help="repo root (default: parent of lib/)")

    run_p = sub.add_parser("argv-running", help="exit 0 if NAME is argv[0] or argv[1] basename of a live process")
    run_p.add_argument("name", help="basename to match against argv[0] and argv[1] only")

    count_p = sub.add_parser(
        "count-argv",
        help="print how many processes match argv[0]/argv[1] NAME, optionally FLAG VALUE as adjacent tokens",
    )
    count_p.add_argument("name", help="basename to match against argv[0] and argv[1] only")
    count_p.add_argument(
        "--has",
        nargs=2,
        metavar=("FLAG", "VALUE"),
        help="also require adjacent argv tokens FLAG VALUE. FLAG may omit leading dashes (provider -> --provider).",
    )

    wt_p = sub.add_parser("worktree-remove", help="remove a worktree only if HEAD is on origin")
    wt_p.add_argument("path", type=Path, help="worktree path")

    args = parser.parse_args(argv)
    if args.cmd == "scan":
        root = args.root
        if root is None:
            root = Path(__file__).resolve().parent.parent
        return cmd_scan(root)
    if args.cmd == "argv-running":
        return cmd_argv_running(args.name)
    if args.cmd == "count-argv":
        has = None
        if args.has:
            flag, value = args.has
            if not flag.startswith("-"):
                flag = "--" + flag
            has = (flag, value)
        return cmd_count_argv(args.name, has)
    if args.cmd == "worktree-remove":
        return worktree_remove(args.path)
    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    sys.exit(main())
