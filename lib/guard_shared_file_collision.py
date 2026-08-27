#!/usr/bin/env python3
"""PreToolUse(Write|Edit|MultiEdit): warn when another agent already has an
open PR touching this shared control-plane file.

fleet-ops#539. Canonical logic. The hook shim at
bin/guard_shared_file_collision_hook.py is installed to
~/.claude/hooks/guard_shared_file_collision.py by MANIFEST.

Shared files: fleet control plane, systemd units, lib/seat-lib.sh,
config/seat-caps.json, hooks, global-standing-rules.md, decisions-ledger.md.

Warn only, never block. The warning is emitted as a Claude hook
`additionalContext` plus a human-readable line to stderr.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

FILE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")

# Path substrings that mark a file as shared enough to guard.  `fleet-ops`
# catches the whole control-plane repo and its installed symlinks.
WATCHED = (
    "fleet-ops",
    "/systemd/",
    ".claude/hooks/",
    ".claude/settings.json",
    "global-standing-rules.md",
    "decisions-ledger.md",
    "seat-lib.sh",
    "seat-caps.json",
    "entitled-seats.json",
    "intake-repos.json",
    "pi-extensions-allowlist.json",
    "role-quality-gates.json",
    "quality-routing.json",
)

CACHE_TTL = 600

FLEET_OPS_REMOTE = "Nishfleet/fleet-ops"
VAULT_REMOTE = "nish3451/nish-vault"

# Fallback repo for paths that are not inside a git checkout but are clearly
# owned by one of the two shared repos.
REPO_FALLBACKS = (
    (".claude/hooks/", VAULT_REMOTE),
    (".claude/settings.json", FLEET_OPS_REMOTE),
    (".config/systemd/user/", FLEET_OPS_REMOTE),
    (".local/lib/pi-packet/", FLEET_OPS_REMOTE),
    (".pi/agent/prompts/", FLEET_OPS_REMOTE),
    ("workspaces/tooling/nish-vault/", VAULT_REMOTE),
    ("global-standing-rules.md", VAULT_REMOTE),
    ("decisions-ledger.md", VAULT_REMOTE),
    ("seat-caps.json", FLEET_OPS_REMOTE),
    ("entitled-seats.json", FLEET_OPS_REMOTE),
    ("seat-lib.sh", FLEET_OPS_REMOTE),
)

REMOTE_RE = re.compile(
    r"(?:github\.com[/:]|@github\.com:)([^/]+)/([^/\s]+?)(?:\.git)?$"
)
SHIM_EXEC_RE = re.compile(
    r'''(?:exec|source)\s+["']?([^"'\s;]+)["']?''', re.I
)
SHIM_PATH_RE = re.compile(
    r'''(?:sys\.path\.insert\(0,\s*(?:os\.path\.expanduser\()?["']([^"']+)["']\)?)''',
    re.I,
)
SHIM_FROM_RE = re.compile(r'''from\s+(\S+)\s+import\s+main\b''', re.I)


def _tool_paths(tool_input: dict) -> list[str]:
    """Extract every file-like path from a Claude tool payload."""
    paths: list[str] = []
    if not isinstance(tool_input, dict):
        return paths

    for key in ("file_path", "notebook_path", "path"):
        val = tool_input.get(key)
        if isinstance(val, str):
            paths.append(val)
        elif isinstance(val, list):
            for p in val:
                if isinstance(p, str):
                    paths.append(p)

    file_paths = tool_input.get("file_paths")
    if isinstance(file_paths, list):
        for p in file_paths:
            if isinstance(p, str):
                paths.append(p)

    # MultiEdit may carry an 'edits' list of {file_path, ...}.
    edits = tool_input.get("edits")
    if isinstance(edits, list):
        for e in edits:
            if isinstance(e, dict):
                for key in ("file_path", "path"):
                    p = e.get(key)
                    if isinstance(p, str):
                        paths.append(p)

    return paths


def _is_shared(path: str) -> bool:
    return any(tok in path for tok in WATCHED)


def _canonical_for_hook(path: str) -> str | None:
    """If path is a ~/.claude/hooks shim, return the canonical source file."""
    if ".claude/hooks/" not in path:
        return None

    real = os.path.realpath(path)
    if real != path and os.path.exists(real):
        # Already a symlink; realpath has done the work.
        return real

    if not os.path.isfile(path):
        return None

    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read(4096)
    except OSError:
        return None

    # exec ".../canonical.sh"
    m = SHIM_EXEC_RE.search(text)
    if m:
        target = os.path.expanduser(m.group(1))
        if os.path.isabs(target):
            return target
        return os.path.join(os.path.dirname(path), target)

    # sys.path.insert(0, ".../guards") + from guard_foo import main
    m = SHIM_PATH_RE.search(text)
    m2 = SHIM_FROM_RE.search(text)
    if m and m2:
        module_dir = os.path.expanduser(m.group(1))
        module = m2.group(1)
        for cand in (
            os.path.join(module_dir, f"{module}.py"),
            os.path.join(module_dir, module, "__init__.py"),
        ):
            if os.path.isfile(cand):
                return cand

    return None


def _parse_remote(url: str) -> str | None:
    url = url.strip()
    m = REMOTE_RE.search(url)
    if not m:
        return None
    return f"{m.group(1)}/{m.group(2)}"


def _git_output(cwd: str, *args: str) -> str:
    try:
        proc = subprocess.run(
            ["git", "-C", cwd] + list(args),
            capture_output=True,
            text=True,
            timeout=5,
        )
        return proc.stdout.strip() if proc.returncode == 0 else ""
    except Exception:
        return ""


def _repo_from_git(path: str) -> tuple[str, str] | None:
    """Return (owner/repo, repo_toplevel) for a file inside a git checkout."""
    cwd = os.path.dirname(os.path.abspath(path)) if os.path.exists(path) else os.getcwd()
    top = _git_output(cwd, "rev-parse", "--show-toplevel")
    if not top or not os.path.isdir(top):
        return None
    url = _git_output(top, "remote", "get-url", "origin")
    if not url:
        return None
    repo = _parse_remote(url)
    return (repo, top) if repo else None


def _repo_fallback(path: str) -> str | None:
    for tok, repo in REPO_FALLBACKS:
        if tok in path:
            return repo
    return None


def _repo_and_rel(path: str) -> tuple[str, str] | None:
    """Return (owner/repo, repo-relative-or-basename path) for a file."""
    resolved = _canonical_for_hook(path) or os.path.realpath(path)

    git = _repo_from_git(resolved)
    if git:
        repo, top = git
        try:
            rel = os.path.relpath(resolved, top)
        except ValueError:
            rel = os.path.basename(resolved)
        return repo, rel

    # Not in a git checkout; try the original path for overrides.
    repo = _repo_fallback(path)
    if repo:
        return repo, os.path.basename(path)

    return None


def _cache_path(repo: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", repo)
    return os.path.join("/tmp", f"guard-shared-file-prs-{safe}.json")


def _open_prs(repo: str) -> list[dict]:
    """Fetch open PRs with their file lists, caching for CACHE_TTL seconds."""
    cache_override = os.environ.get("GUARD_SHARED_FILE_PR_CACHE")
    if cache_override:
        try:
            with open(cache_override, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return []

    cache = _cache_path(repo)
    try:
        mtime = os.path.getmtime(cache)
        if time.time() - mtime < CACHE_TTL:
            with open(cache, encoding="utf-8") as f:
                return json.load(f)
    except Exception:
        pass

    try:
        proc = subprocess.run(
            [
                "gh",
                "pr",
                "list",
                "-R",
                repo,
                "--state",
                "open",
                "--limit",
                "100",
                "--json",
                "number,title,author,files",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if proc.returncode != 0:
            return []
        data = json.loads(proc.stdout or "[]")
        if not isinstance(data, list):
            return []

        tmp_fd, tmp_path = tempfile.mkstemp(
            prefix="guard-shared-file-prs-", dir="/tmp"
        )
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.replace(tmp_path, cache)
        return data
    except Exception:
        return []


def _matching_prs(prs: list[dict], target: str) -> list[dict]:
    """PRs whose file list touches the target (by repo-relative path or basename)."""
    target_base = os.path.basename(target)
    hits: list[dict] = []
    for pr in prs:
        for f in pr.get("files") or []:
            p = f.get("path", "")
            if p == target or os.path.basename(p) == target_base:
                hits.append(pr)
                break
    return hits


def _warn(repo: str, target: str, prs: list[dict]) -> str:
    lines = [
        f"shared-file collision guard: {target} on {repo} is already touched by "
        f"{len(prs)} OPEN PR(s):"
    ]
    for pr in prs[:4]:
        who = (pr.get("author") or {}).get("login", "?")
        title = (pr.get("title") or "")[:80]
        lines.append(f"  #{pr['number']} ({who}) {title}")
    lines.append(
        "Another agent may be mid-fix. Read those PRs before editing, "
        "or you will duplicate the diff (this happened with #44/#48 on seat-lib.sh)."
    )
    return "\n".join(lines)


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0

    if not isinstance(data, dict):
        return 0

    tool_name = data.get("tool_name", "")
    if tool_name not in FILE_TOOLS:
        return 0

    tool_input = data.get("tool_input") or {}
    paths = _tool_paths(tool_input)
    if not paths:
        return 0

    warnings: list[str] = []
    by_repo: dict[str, list[tuple[str, list[dict]]]] = {}

    for raw in paths:
        if not isinstance(raw, str) or not raw:
            continue
        abspath = os.path.abspath(os.path.expanduser(raw))
        if not _is_shared(abspath):
            continue

        repo_rel = _repo_and_rel(abspath)
        if not repo_rel:
            continue
        repo, target = repo_rel
        by_repo.setdefault(repo, []).append((target, abspath))

    for repo, targets in by_repo.items():
        prs = _open_prs(repo)
        if not prs:
            continue
        for target, _ in targets:
            hits = _matching_prs(prs, target)
            if hits:
                warnings.append(_warn(repo, target, hits))

    if not warnings:
        return 0

    msg = "\n\n".join(warnings)
    print(msg, file=sys.stderr)
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "additionalContext": msg,
                }
            }
        )
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
