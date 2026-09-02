#!/usr/bin/env python3
"""fleet-ops-drift — fail-loud drift canary for fleet-ops merge-to-live.

fleet-ops#149: on every heartbeat tick, assert that the live installed state
matches the MANIFEST and that the MANIFEST matches origin/main. Any divergence
is a LOUD finding that exits 1, so fleet-heartbeat.service lands in --state=failed
and the standard escalation matrix fires.

fleet-ops#176: also assert PATH identity. Live dests must resolve under the
canonical deploy checkout, not a hotfix / issue worktree / worktree-parent.
A DRIFT-SOURCE finding auto-files (deduped) so the class cannot sit silent.

fleet-ops#285: also assert ExecStart binaries exist. A leftover .service
whose ExecStart path is gone (binary renamed to .bak, unit files left
behind) is invisible to extra-symlink and extra-enabled checks: the files
are regular, not symlinks, and the timer is often disabled. DRIFT-MISSING-EXEC
auto-files (deduped) so that class cannot sit silent.

fleet-ops#370: the hand-built fleet-heartbeat.service.d/10-deploy-checkout.conf
drop-in papered over auto-reverted #313 and pointed FLEET_OPS_DRIFT_BIN at a
GC-able agent-worktree, so the canary compared the clone against itself.
DRIFT-PAPER-OVER auto-files (deduped) if that drop-in or a worktree canary
path comes back. Extra-symlink / DRIFT-VOLATILE miss .conf drop-ins.

fleet-ops#477: the canonical deploy-clone must stay on branch main. A named
non-main branch (auditor/hotfix) makes merge-to-live DEPLOY-BLOCKED once the
branch is not an ancestor of origin/main. DRIFT-OFF-MAIN auto-files (deduped).
`--file-off-main` files that class without running the rest of the canary so
fleet-ops-deploy can file when it blocks before the canary runs.

fleet-ops#2725: the deploy-clone on main but dirty (uncommitted tracked
changes) or diverged (HEAD not an ancestor of origin/main) also blocks
merge-to-live, but the off-main auto-file does not fire (the branch IS
main). DRIFT-CHECKOUT auto-files that class (deduped).
`--file-deploy-blocked-main` files that class without running the rest of
the canary so fleet-ops-deploy can file when it blocks before the canary
runs.

Environment seams (overridden by tests):
  FLEET_OPS_CHECKOUT              path to the fleet-ops deploy checkout
  FLEET_OPS_AUDIT_LOG             drift audit log (default: ~/.local/state/fleet-ops/drift-audit.log)
  FLEET_OPS_TRIAGE                heartbeat triage file for LOUD lines
  FLEET_OPS_SKIP_FETCH            set to 1 to skip the git fetch (offline tests)
  FLEET_OPS_SYSTEMCTL             path to systemctl (default: systemctl)
  FLEET_OPS_WORKSPACES_ROOT       default /home/nish/workspaces
  FLEET_OPS_CANONICAL_CHECKOUT    default <workspaces>/tooling/fleet-ops-deploy-clone
  FLEET_OPS_ALLOW_NONCANONICAL    set to 1 to skip the source-path gate
  FLEET_OPS_DRIFT_FILE            1 (default) auto-file DRIFT-SOURCE, DRIFT-MISSING-EXEC, DRIFT-PAPER-OVER, DRIFT-PRODUCTS-SYMLINK, DRIFT-OFF-MAIN, DRIFT-DEPLOY-BLOCKED-MAIN, DRIFT-VOLATILE, DRIFT-METRICS-DROPIN; 0 skip gh
  FLEET_OPS_DRIFT_CLOSE           1 (default) close a drift issue on a later green tick once it carries `resolved-at:`; 0 only comment (fleet-ops#1156)
  FLEET_OPS_DRIFT_REPO            default Nishfleet/fleet-ops
  FLEET_OPS_RETARGET_BIN          fleet-ops-retarget-products (default: next to this file)
  FLEET_OPS_PRODUCTS_LINK         products/fleet-ops symlink (default: <workspaces>/products/fleet-ops)
  GH                              gh binary (tests stub this)
"""

from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path


HOME = Path(os.environ.get("HOME", "/home/nish"))
CHECKOUT = os.environ.get("FLEET_OPS_CHECKOUT", "")
AUDIT_LOG = Path(os.environ.get("FLEET_OPS_AUDIT_LOG", HOME / ".local" / "state" / "fleet-ops" / "drift-audit.log"))
TRIAGE = Path(os.environ.get("FLEET_OPS_TRIAGE", "/home/nish/workspaces/agent-state/FLEET-HEARTBEAT-TRIAGE.md"))
SKIP_FETCH = os.environ.get("FLEET_OPS_SKIP_FETCH", "") == "1"
SYSTEMCTL = os.environ.get("FLEET_OPS_SYSTEMCTL", "systemctl")
GH = os.environ.get("GH", "gh")
DRIFT_REPO = os.environ.get("FLEET_OPS_DRIFT_REPO", "Nishfleet/fleet-ops")


def issue_file_py() -> str:
    env = os.environ.get("FLEET_ISSUE_FILE_LIB")
    if env:
        return env
    here = Path(__file__).resolve().parent
    cand = here.parent / "lib" / "issue-file.py"
    installed = HOME / ".local" / "lib" / "pi-packet" / "issue-file.py"
    if cand.is_file():
        return str(cand)
    if installed.is_file():
        return str(installed)
    return str(cand)
DRIFT_FILE = os.environ.get("FLEET_OPS_DRIFT_FILE", "1") == "1"
DRIFT_CLOSE = os.environ.get("FLEET_OPS_DRIFT_CLOSE", "1") == "1"
ALLOW_NONCANONICAL = os.environ.get("FLEET_OPS_ALLOW_NONCANONICAL", "") == "1"
WORKSPACES_ROOT = Path(os.environ.get("FLEET_OPS_WORKSPACES_ROOT", "/home/nish/workspaces"))
CANONICAL_CHECKOUT = Path(
    os.environ.get(
        "FLEET_OPS_CANONICAL_CHECKOUT",
        str(WORKSPACES_ROOT / "tooling" / "fleet-ops-deploy-clone"),
    )
)
SOURCE_MARKER = "canonical-checkout-drift: fleet-ops#176"
ORPHAN_EXEC_MARKER = "orphan-execstart: fleet-ops#285"
PAPER_OVER_MARKER = "paper-over-dropin: fleet-ops#370"
PRODUCTS_MARKER = "products-symlink-stale: fleet-ops#410"
OFF_MAIN_MARKER = "deploy-clone-off-main: fleet-ops#477"
HOTPATCH_MARKER = "stale-overwrite-hot-patch: fleet-ops#463"
VOLATILE_MARKER = "volatile-unit-path: fleet-ops#369"
# fleet-ops#2725: the deploy-clone on main but dirty/diverged is a distinct
# class from off-main (the branch IS main). It blocks merge-to-live with the
# same DEPLOY-BLOCKED line but had no auto-file path, so it sat silent until
# the blind-audit caught it 30+ min later. This marker gives the class its
# own auto-file + observe-to-close wiring.
DEPLOY_BLOCKED_MAIN_MARKER = "deploy-blocked-on-main: fleet-ops#2725"
# fleet-ops#2920: a MANIFEST-listed fleet-metrics-export drop-in missing
# from the live merged unit. The general check_live_matches_origin_main runs
# after check_checkout, which exits on DRIFT-OFF-MAIN — so while the
# deploy-clone is stuck on a non-main branch (the #2920 root cause), new
# organs' drop-ins never reach live and the dark-organ symptom is invisible.
# This marker gives the class its own auto-file + observe-to-close wiring.
METRICS_DROPIN_MARKER = "metrics-export-dropin-missing: fleet-ops#2920"

DRIFT_MARKERS = (
    SOURCE_MARKER,
    ORPHAN_EXEC_MARKER,
    PAPER_OVER_MARKER,
    PRODUCTS_MARKER,
    OFF_MAIN_MARKER,
    HOTPATCH_MARKER,
    VOLATILE_MARKER,
    DEPLOY_BLOCKED_MAIN_MARKER,
    METRICS_DROPIN_MARKER,
)

PAPER_OVER_DROPIN = (
    HOME / ".config" / "systemd" / "user" / "fleet-heartbeat.service.d" / "10-deploy-checkout.conf"
)
_EXECSTART_PREFIXES = frozenset("-@+!")

FLEET_PREFIXES = (
    "pi-",
    "siterep-",
    "fleet-",
    "agent-cron-",
    "intake-",
    "oomd-",
    "codex-",
    "escalation-",
    "stop-",
    "unit-escalation",
)

MANAGED_DIRS = (
    HOME / ".local" / "bin",
    HOME / ".config" / "systemd" / "user",
    HOME / ".pi" / "agent" / "prompts",
    HOME / ".config" / "fleet-worker",
    HOME / ".local" / "lib" / "pi-packet",
    HOME / ".local" / "state" / "pi-packet",
)


def now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg: str) -> None:
    print(f"[{now_iso()}] [fleet-ops-drift] {msg}", file=sys.stderr)


def loud(tag: str, msg: str) -> None:
    log(f"LOUD [{tag}] {msg}")
    try:
        with TRIAGE.open("a", encoding="utf-8") as f:
            f.write(f"\n[{now_iso()}] [{tag}] {msg}\n")
    except OSError as e:
        log(f"WARN: could not append to triage {TRIAGE}: {e}")


def audit(unit: str, action: str, why: str) -> None:
    AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
    with AUDIT_LOG.open("a", encoding="utf-8") as f:
        f.write(f"{now_iso()} {unit} {action} actor=fleet-ops-drift why={why}\n")


def fail_loud(tag: str, msg: str) -> None:
    loud(tag, msg)
    audit("fleet-ops", "drift", msg)
    sys.exit(1)


def resolved(path: Path) -> Path:
    try:
        return path.resolve()
    except OSError:
        return path


def is_under(path: Path, root: Path) -> bool:
    path_s = str(resolved(path))
    root_s = str(resolved(root))
    return path_s == root_s or path_s.startswith(root_s + os.sep)


def auto_file_drift(marker: str, title: str, extra: str, msg: str) -> None:
    """File one issue for a drift class. Dedup on marker in open issue bodies."""
    if not DRIFT_FILE:
        log(f"file skipped (FLEET_OPS_DRIFT_FILE!=1) marker={marker}")
        return
    try:
        proc = subprocess.run(
            [GH, "issue", "list", "-R", DRIFT_REPO, "--state", "open", "--limit", "50", "--json", "number,body"],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            for item in json.loads(proc.stdout):
                body = item.get("body") or ""
                if marker in body:
                    log(f"dedup: open {DRIFT_REPO}#{item.get('number')} already carries {marker}")
                    return
    except (OSError, json.JSONDecodeError) as e:
        log(f"WARN: gh issue list failed for {marker}: {e}")

    full = f"{msg}\n\n{extra}\n\n{marker}\n"
    try:
        env = os.environ.copy()
        env["GH"] = GH
        proc = subprocess.run(
            [sys.executable, issue_file_py(), "file", "-R", DRIFT_REPO, "--title", title, "--body", full],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
        if proc.returncode == 0:
            log(f"filed: {title}")
        else:
            log(f"WARN: gh issue create failed for {marker}: {proc.stderr.strip()}")
    except OSError as e:
        log(f"WARN: gh issue create failed for {marker}: {e}")


def auto_file_source_drift(msg: str) -> None:
    """File one issue for canonical-checkout drift. Dedup on SOURCE_MARKER."""
    extra = (
        "Live dests must resolve under the canonical deploy checkout "
        f"({resolved(CANONICAL_CHECKOUT)}), not a hotfix / issue worktree / "
        "worktree-parent. install.sh and fleet-ops-deploy refuse that class; "
        "this canary auto-files when it still appears."
    )
    auto_file_drift(
        SOURCE_MARKER,
        "Live fleet-ops installed from non-canonical checkout",
        extra,
        msg,
    )


def auto_file_orphan_exec(msg: str) -> None:
    """File one issue for leftover units whose ExecStart binary is missing."""
    extra = (
        "A user .service file whose ExecStart binary is gone is leftover "
        "after a decommission (binary renamed to .bak, GitHub-hosted "
        "replacement running, unit files never removed). Remove the unit "
        "files and run systemctl --user daemon-reload. Do not restart a slice."
    )
    auto_file_drift(
        ORPHAN_EXEC_MARKER,
        "Orphan systemd unit: ExecStart binary missing",
        extra,
        msg,
    )


def auto_file_paper_over(msg: str) -> None:
    """File one issue if the #313 paper-over drop-in or worktree canary returns."""
    extra = (
        "fleet-heartbeat.service pins FLEET_OPS_CHECKOUT to the deploy-clone. "
        "Do not add fleet-heartbeat.service.d/10-deploy-checkout.conf and do "
        "not point FLEET_OPS_DRIFT_BIN at agent-worktrees. install.sh and "
        "fleet-ops-deploy remove the drop-in; this canary auto-files when it "
        "still appears (fleet-ops#370)."
    )
    auto_file_drift(
        PAPER_OVER_MARKER,
        "Paper-over heartbeat drop-in or worktree drift canary is back",
        extra,
        msg,
    )


def auto_file_products_symlink(msg: str) -> None:
    """File one issue if products/fleet-ops cannot retarget to the deploy-clone."""
    extra = (
        "products/fleet-ops must point at the canonical deploy-clone. "
        "fleet-ops-retarget-products applies that when no git worktrees "
        "remain on the pre-rewrite parent; it must not delete the parent. "
        "Waiting on attached worktrees is expected (exit 2) and is not "
        "this class. This canary auto-files when apply fails (fleet-ops#410)."
    )
    auto_file_drift(
        PRODUCTS_MARKER,
        "products/fleet-ops still not the deploy-clone",
        extra,
        msg,
    )


def auto_file_off_main(msg: str) -> None:
    """File one issue if the deploy-clone is on a named non-main branch."""
    extra = (
        "The canonical deploy-clone must stay on branch main. Park auditor "
        "or hotfix work as its own worktree; do not check that branch out on "
        "the live clone. Heartbeat merge-to-live will DEPLOY-BLOCK once HEAD "
        "is not an ancestor of origin/main (squash-merged auditor commits "
        "diverge). This canary auto-files that class (fleet-ops#477)."
    )
    auto_file_drift(
        OFF_MAIN_MARKER,
        "Live fleet-ops-deploy-clone is on a named branch, not main",
        extra,
        msg,
    )


def auto_file_deploy_blocked_main(msg: str) -> None:
    """File one issue if the deploy-clone is on main but dirty or diverged.

    fleet-ops#2725: a dirty working tree (uncommitted tracked changes) or a
    HEAD that is not an ancestor of origin/main (a hot-patch commit not yet
    on origin/main) blocks merge-to-live with the same DEPLOY-BLOCKED line
    as off-main, but the off-main auto-file does not fire (the branch IS
    main). Without this auto-file the block sat silent for 30+ min until
    the blind-audit caught it. The drift canary and fleet-ops-deploy both
    call this so the class is filed from whichever runs first.
    """
    extra = (
        "The canonical deploy-clone is on branch main but merge-to-live is "
        "blocked: either the working tree has uncommitted tracked changes "
        "(a hot-patch not yet on a PR) or HEAD is not an ancestor of "
        "origin/main (a local commit not yet merged). fleet-ops-deploy "
        "refuses to fast-forward until the checkout is clean and an "
        "ancestor of origin/main. Resolve by committing the change on a "
        "branch/PR and merging it, or by discarding the local hot-patch if "
        "it is already superseded (git checkout/restore the file, or "
        "git reset --hard origin/main when the local commit is obsolete). "
        "This canary auto-files that class (fleet-ops#2725)."
    )
    auto_file_drift(
        DEPLOY_BLOCKED_MAIN_MARKER,
        "Live fleet-ops-deploy-clone is on main but dirty/diverged, blocking merge-to-live",
        extra,
        msg,
    )


def auto_file_volatile(msg: str) -> None:
    """File one issue if a unit file or enable-link resolves into a volatile path.

    A wants-link into /tmp (or /run, agent-worktrees) is one tmpfiles-clean
    run or reboot from dangling, dropping the unit and any self-management
    loop that runs through it. install.sh --check only verifies MANIFEST
    fragment dests, not the wants-links systemctl enable creates, so this
    canary is the only guard for that class (fleet-ops#369).
    """
    extra = (
        "Re-symlink the wants-link to the deploy-clone's unit file: "
        "systemctl --user reenable <unit>, or remove the link then "
        "systemctl --user daemon-reload && systemctl --user enable <unit>. "
        "A dangling link (target already deleted) takes the same reenable. "
        "Do not restart a slice."
    )
    auto_file_drift(
        VOLATILE_MARKER,
        "Installed unit or enable-link resolves into a volatile path",
        extra,
        msg,
    )


def auto_file_metrics_dropin(msg: str) -> None:
    """File one issue when a MANIFEST-listed metrics-export drop-in is absent
    from the live merged unit (fleet-ops#2920).

    The deploy-clone being on a non-main branch is the known root cause
    (fleet-ops#477): install.sh runs from that checkout, so a MANIFEST that
    predates a new organ's drop-in never lands it. The off-main block is
    filed separately by check_checkout / fleet-ops-deploy; this filing is
    for the dark-organ symptom itself so it cannot sit silent behind the
    off-main exit.
    """
    extra = (
        "Repair: restore the deploy-clone to main and run bin/fleet-ops-deploy, "
        "or install the missing drop-in from `git show origin/main:<src>` "
        "into ~/.config/systemd/user/fleet-metrics-export.service.d/ and "
        "`systemctl --user daemon-reload`. The deploy-clone on a non-main "
        "branch (fleet-ops#477) is the root cause — install.sh runs from "
        "that checkout so a MANIFEST predating the organ never lands the "
        "drop-in. Verify with: systemctl --user cat fleet-metrics-export.service "
        "| grep <drop-in-name>."
    )
    auto_file_drift(
        METRICS_DROPIN_MARKER,
        "fix(metrics-export): MANIFEST-listed drop-in missing from live unit",
        extra,
        msg,
    )


def _issue_blob(issue: dict[str, Any]) -> str:
    """Body plus all comment bodies, for deduping observe-to-close posts."""
    parts = [str(issue.get("body") or "")]
    for comment in issue.get("comments") or []:
        if isinstance(comment, dict):
            parts.append(str(comment.get("body") or ""))
    return "\n".join(parts)


def observe_close_drift_issues(
    checkout: Path, head: str, only_marker: str | None = None
) -> None:
    """Comment on, then close, open drift issues whose class is now green.

    Observe-to-close wiring (fleet-ops#620): when the canary is green, any
    open issue carrying a drift marker gets a `resolved-at:` comment. This
    makes the close evidence-backed rather than manual.

    Two-tick close (fleet-ops#1156, mirroring fleet-exec-review-canary
    fleet-ops#729 and fleet-decisions-ledger fleet-ops#650): the first green
    tick posts `resolved-at:`; a later green tick — once that marker is
    already present — closes the issue with `gh issue close --reason
    completed`. A still-red class never reaches this code (the matching
    check fail-louds first), so a dirty drift issue is never closed. The
    close is gated by ``FLEET_OPS_DRIFT_CLOSE`` (default 1); tests that
    only exercise the comment path set it to 0.

    When ``only_marker`` is given, only that marker is considered. Per-check
    callers use this so a class that is binary (e.g. off-main: branch is
    main or not) can be observed-to-closed the moment its own check
    passes, independent of later checks that may still be red (fleet-ops#774).
    """
    if not DRIFT_FILE:
        log("observe-to-close skipped (FLEET_OPS_DRIFT_FILE!=1)")
        return

    marker_names = {
        SOURCE_MARKER: "canonical-checkout drift",
        ORPHAN_EXEC_MARKER: "orphan ExecStart",
        PAPER_OVER_MARKER: "paper-over drop-in",
        PRODUCTS_MARKER: "products/fleet-ops symlink",
        OFF_MAIN_MARKER: "off-main deploy-clone",
        HOTPATCH_MARKER: "hot-patch",
        DEPLOY_BLOCKED_MAIN_MARKER: "deploy-blocked on main",
        METRICS_DROPIN_MARKER: "metrics-export drop-in missing",
    }

    markers = (only_marker,) if only_marker else DRIFT_MARKERS

    try:
        proc = subprocess.run(
            [GH, "issue", "list", "-R", DRIFT_REPO, "--state", "open", "--limit", "50", "--json", "number,body,comments"],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            log(f"WARN: gh issue list failed for observe-to-close: {proc.stderr.strip()}")
            return
        issues = json.loads(proc.stdout) if proc.stdout.strip() else []
    except (OSError, json.JSONDecodeError) as e:
        log(f"WARN: gh issue list failed for observe-to-close: {e}")
        return

    for issue in issues:
        if not isinstance(issue, dict):
            continue
        number = issue.get("number")
        if not isinstance(number, int):
            continue
        blob = _issue_blob(issue)
        for marker in markers:
            if marker not in blob:
                continue
            resolved_marker = f"resolved-at: {marker}"
            if resolved_marker in blob:
                # Tick 2+: the green tick that posted `resolved-at:` already
                # landed on a prior heartbeat. Close now (fleet-ops#1156).
                if not DRIFT_CLOSE:
                    log(f"dedup observe: {DRIFT_REPO}#{number} already carries {resolved_marker}")
                    break
                name = marker_names.get(marker, marker)
                try:
                    cp = subprocess.run(
                        [GH, "issue", "close", str(number), "-R", DRIFT_REPO, "--reason", "completed"],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    if cp.returncode == 0:
                        log(f"OBSERVE-CLOSED: {name} -> {DRIFT_REPO}#{number}")
                    else:
                        log(f"WARN: gh issue close failed for {DRIFT_REPO}#{number}: {cp.stderr.strip()}")
                except OSError as e:
                    log(f"WARN: gh issue close failed for {DRIFT_REPO}#{number}: {e}")
                break
            comment = (
                f"{resolved_marker}\n"
                f"checkout: {resolved(checkout)}\n"
                f"HEAD: {head}\n"
                f"observed-at: {now_iso()}\n\n"
                "Drift canary is green; this class is resolved on a real "
                "heartbeat tick (fleet-ops#620 observe-to-close).\n"
            )
            try:
                cp = subprocess.run(
                    [GH, "issue", "comment", str(number), "-R", DRIFT_REPO, "--body", comment],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if cp.returncode == 0:
                    name = marker_names.get(marker, marker)
                    log(f"OBSERVED-RESOLVED: {name} -> {DRIFT_REPO}#{number}")
                else:
                    log(f"WARN: gh issue comment failed for {DRIFT_REPO}#{number}: {cp.stderr.strip()}")
            except OSError as e:
                log(f"WARN: gh issue comment failed for {DRIFT_REPO}#{number}: {e}")
            break


def auto_file_install_refuse(dest: str, repo: str, diff: str) -> None:
    """File one issue for a live file that is newer and differs from the repo copy."""
    extra = (
        "install.sh refused to overwrite a live file whose mtime is newer "
        "than the repo copy because the content differs. A hot-patch is in "
        "place. Resolve by merging the change through the normal PR path or "
        "restore the live file to the repo copy, then re-run the heartbeat."
    )
    title = f"Live fleet-ops file hot-patched: {Path(dest).name}"
    body = f"Live file `{dest}` is newer and differs from repo `{repo}`:\n\n```diff\n{diff}\n```"
    auto_file_drift(HOTPATCH_MARKER, title, extra, body)


def retarget_products_bin() -> Path:
    env = os.environ.get("FLEET_OPS_RETARGET_BIN", "")
    if env:
        return Path(env)
    sibling = Path(__file__).resolve().parent / "fleet-ops-retarget-products"
    if sibling.is_file():
        return sibling
    return HOME / ".local" / "bin" / "fleet-ops-retarget-products"


def check_products_symlink() -> None:
    """Retarget products/fleet-ops when safe; fail loud only on apply errors.

    Attached worktrees on the pre-rewrite parent are the expected drain
    state (helper exit 2). That must not trip the canary or auto-file.
    """
    if ALLOW_NONCANONICAL:
        log("products-symlink gate skipped (FLEET_OPS_ALLOW_NONCANONICAL=1)")
        return
    helper = retarget_products_bin()
    if not helper.is_file():
        log(f"products-symlink gate skipped (missing {helper})")
        return
    rc, stdout, stderr = run([str(helper), "--apply"], check=False)
    text = "\n".join(part for part in (stdout.strip(), stderr.strip()) if part)
    if text:
        for line in text.splitlines():
            log(line)
    if rc == 0:
        return
    if rc == 2:
        log("products/fleet-ops still on worktree parent; attached worktrees remain (fleet-ops#410)")
        return
    msg = text or f"{helper} --apply exited {rc}"
    auto_file_products_symlink(msg)
    fail_loud("DRIFT-PRODUCTS-SYMLINK", msg)


def check_canonical_source(checkout: Path, expected_dests: dict[str, Path]) -> None:
    """Fail if the checkout or a live dest points at a non-canonical workspaces tree.

    Content compare against origin/main cannot see this class: a hotfix
    worktree at the same blob still leaves live symlinks pointing at a
    tree that can diverge or be deleted (fleet-ops#176).
    """
    if ALLOW_NONCANONICAL:
        log("canonical-source gate skipped (FLEET_OPS_ALLOW_NONCANONICAL=1)")
        return

    findings: list[str] = []
    checkout_r = resolved(checkout)
    canon_r = resolved(CANONICAL_CHECKOUT)
    ws_r = resolved(WORKSPACES_ROOT)

    if is_under(checkout_r, ws_r) and checkout_r != canon_r:
        findings.append(f"checkout {checkout_r} is not the canonical checkout {canon_r}")

    for dest, src in expected_dests.items():
        dest_path = Path(dest)
        if dest.startswith("/etc/"):
            continue
        # fleet-ops#2910: seat-caps.json is intentionally a regular file copy
        # (not a symlink) so `git reset --hard` on the deploy-clone cannot
        # silently rewrite the live config. Exempt it from the must-be-a-
        # symlink check; check_live_matches_origin_main still compares its
        # bytes to origin/main, and install.sh still guards cap downgrades.
        if src.name == "seat-caps.json":
            continue
        if dest_path.is_symlink():
            try:
                target = dest_path.resolve()
            except OSError:
                continue
            if is_under(target, ws_r) and not is_under(target, canon_r):
                findings.append(f"WRONG-SYMLINK: {dest} -> {target} (want under {canon_r})")
        elif dest_path.is_file() and is_under(checkout_r, ws_r):
            findings.append(
                f"DIFF-FILE: {dest} is a regular file, not a symlink into {canon_r}"
            )

    if findings:
        msg = "live install source is not the canonical checkout:\n" + "\n".join(findings)
        auto_file_source_drift(msg)
        fail_loud("DRIFT-SOURCE", msg)
    log(f"live dests resolve under canonical checkout {canon_r}")


def run(cmd: list[str], cwd: Path | None = None, check: bool = True, capture: bool = True) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            capture_output=capture,
            text=True,
            check=False,
            env={**os.environ, "XDG_RUNTIME_DIR": os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")},
        )
    except FileNotFoundError as e:
        if check:
            fail_loud("DRIFT-FATAL", f"command not found: {cmd[0]}: {e}")
        return 127, "", str(e)
    if check and proc.returncode != 0:
        fail_loud("DRIFT-FATAL", f"{' '.join(cmd)} failed (rc={proc.returncode}): {proc.stderr.strip()}")
    return proc.returncode, proc.stdout, proc.stderr


def find_checkout() -> Path:
    if CHECKOUT:
        return Path(CHECKOUT).resolve()
    self = Path(__file__).resolve()
    return self.parents[1]


def is_fleet_unit(name: str) -> bool:
    return name.startswith(FLEET_PREFIXES)


def fleet_managed_units(checkout: Path) -> set[str]:
    """Names of units fleet-ops actually ships a source file for.

    A unit is fleet-managed (and thus "extra-enabled drift" if enabled but
    not expected) only when this checkout's systemd/ dir contains a source
    file for it. Exact names match directly; a template source ``base@.suffix``
    matches any instance ``base@<anything>.suffix``. Units with a fleet-y name
    prefix but NO source here (e.g. codex-remote-control.service, owned by the
    codex setup; pi-transport-check.path/timer, owned by the pi setup) are
    externally managed and not this canary's business — the old prefix-only
    is_fleet_unit false-positived on them and turned every heartbeat tick red.
    """
    managed: set[str] = set()
    systemd_dir = checkout / "systemd"
    if not systemd_dir.is_dir():
        return managed
    for entry in systemd_dir.iterdir():
        if not entry.is_file():
            continue
        name = entry.name
        if "@" in name:
            base, suffix = name.split("@", 1)
            if not suffix.startswith("."):
                continue
            # Template: base@.suffix matches base@<instance>.suffix.
            managed.add(name)
            managed.add(f"{base}@{suffix}")  # canonical template form
        else:
            managed.add(name)
    return managed


def is_fleet_managed_unit(name: str, managed: set[str]) -> bool:
    """True iff fleet-ops ships a source unit file matching ``name``.

    Handles template instances: ``pi-intake@rogue.timer`` is fleet-managed
    because ``pi-intake@.timer`` is shipped. Externally-owned units
    (no source in this checkout) return False even if name-prefixed.
    """
    if name in managed:
        return True
    if "@" in name:
        base, rest = name.split("@", 1)
        # rest is "<instance>.<type>"; the template is "base@.<type>".
        if "." in rest:
            ext = rest.rsplit(".", 1)[1]
            if f"{base}@.{ext}" in managed:
                return True
    return False


def unit_has_install(path: Path) -> bool:
    try:
        with path.open("r", encoding="utf-8") as f:
            return re.search(r"^\[Install\]\s*$", f.read(), re.MULTILINE) is not None
    except OSError:
        return False


def parse_manifest(checkout: Path) -> tuple[dict[str, Path], set[str]]:
    """Return (dest->src mapping, set of unit names that should be enabled)."""
    manifest = checkout / "MANIFEST"
    if not manifest.exists():
        fail_loud("DRIFT-FATAL", f"MANIFEST missing at {manifest}")

    entries: dict[str, Path] = {}
    expected_enabled: set[str] = set()
    user_systemd_dir = str(HOME / ".config" / "systemd" / "user") + os.sep

    with manifest.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            src, dest = parts[0], parts[1]
            entries[dest] = (checkout / src).resolve()

            if not dest.startswith(user_systemd_dir):
                continue

            basename = os.path.basename(dest)
            if "@" in basename:
                continue

            repo_file = checkout / src
            if not repo_file.exists():
                continue
            if not unit_has_install(repo_file):
                continue

            expected_enabled.add(basename)

    return entries, expected_enabled


def parse_intake_repos(checkout: Path) -> list[str]:
    intake_json = checkout / "config" / "intake-repos.json"
    if not intake_json.exists():
        return []

    try:
        data = json.loads(intake_json.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        fail_loud("DRIFT-FATAL", f"intake-repos.json is invalid JSON: {e}")

    return [r["name"] for r in data.get("repos", []) if isinstance(r, dict) and r.get("name")]


def git_show_bytes(checkout: Path, spec: str) -> bytes | None:
    """Return `git show <spec>` bytes, or None if the object is missing."""
    proc = subprocess.run(
        ["git", "-C", str(checkout), "show", spec],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def live_file_bytes(dest: Path) -> bytes | None:
    try:
        if dest.is_file() or dest.is_symlink():
            return dest.read_bytes()
    except OSError:
        return None
    return None


def is_volatile_outside_checkout(resolved: Path, checkout: Path) -> bool:
    """True if resolved lives under /tmp, /run, or agent-worktrees, and is not the checkout.

    Test checkouts themselves often live under /tmp; those are not volatile.
    The timer-symlink incident (fleet-ops#372) was an enable-link into
    /tmp/fleet-ops-p13, outside the deploy checkout, one tmpfiles-clean
    from dropping fleet-heartbeat.timer.
    """
    resolved_s = str(resolved)
    checkout_s = str(checkout.resolve())
    if resolved_s == checkout_s or resolved_s.startswith(checkout_s + os.sep):
        return False
    if resolved_s == "/tmp" or resolved_s.startswith("/tmp/"):
        return True
    if resolved_s == "/run" or resolved_s.startswith("/run/"):
        return True
    if "agent-worktrees" in resolved.parts:
        return True
    return False


def check_metrics_export_dropins(checkout: Path) -> None:
    """Fail when a MANIFEST-listed fleet-metrics-export drop-in is absent
    from the live merged unit (fleet-ops#2920).

    Runs BEFORE check_checkout so the dark-organ symptom is surfaced even
    while the deploy-clone is on a non-main branch — the root cause that
    makes check_live_matches_origin_main unreachable (check_checkout exits
    on DRIFT-OFF-MAIN first). MANIFEST is read from the origin/main blob,
    never the working tree, so an off-main checkout cannot mask the
    expected drop-in set.

    The off-main root cause is filed independently by check_checkout and
    fleet-ops-deploy; this check files the missing-drop-in symptom itself.
    """
    if not SKIP_FETCH:
        rc, _, err = run(["git", "-C", str(checkout), "fetch", "origin"], check=False)
        if rc != 0:
            # Don't fail-loud here: check_checkout re-fetches and owns the
            # fetch-failure class. This check just degrades to the stale
            # origin/main below, or skips if that is also unresolvable.
            log(f"metrics-dropin check: git fetch origin failed ({err.strip()}); trying stale origin/main")
    rc, origin_main, _ = run(["git", "-C", str(checkout), "rev-parse", "origin/main"], check=False)
    if rc != 0:
        # No origin/main to read the expected drop-in set from (e.g. a
        # non-canonical hotfix checkout in tests, or a freshly-cloned repo
        # with no remote ref). Skip rather than fail-loud so the existing
        # DRIFT-SOURCE / DRIFT-CHECKOUT checks still surface the bad
        # checkout class (fleet-ops#176, #477).
        log("metrics-dropin check: origin/main unresolvable; skipping (defer to DRIFT-SOURCE/DRIFT-CHECKOUT)")
        return
    origin_main = origin_main.strip()

    manifest_bytes = git_show_bytes(checkout, f"{origin_main}:MANIFEST")
    if manifest_bytes is None:
        fail_loud("DRIFT-ORIGIN", f"origin/main ({origin_main[:12]}) has no MANIFEST")

    expected_dropins: list[str] = []
    for line in manifest_bytes.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        src, dest = parts[0], parts[1]
        if "/fleet-metrics-export.service.d/" in dest and dest.endswith(".conf"):
            expected_dropins.append(dest)

    if not expected_dropins:
        log("no fleet-metrics-export drop-ins in MANIFEST")
        return

    # `systemctl --user cat` prints a `# <drop-in-path>` comment line at the
    # top of each drop-in fragment, so substring matching on the dest path
    # confirms the drop-in is loaded into the merged unit (not just present
    # on disk before a daemon-reload).
    rc, cat_out, cat_err = run(
        [SYSTEMCTL, "--user", "cat", "fleet-metrics-export.service"], check=False
    )
    if rc != 0:
        msg = (
            f"systemctl --user cat fleet-metrics-export.service failed "
            f"(rc={rc}): {(cat_err or cat_out).strip()}"
        )
        auto_file_metrics_dropin(msg)
        fail_loud("DRIFT-METRICS-DROPIN", msg)
    merged = cat_out + cat_err

    missing = [d for d in expected_dropins if d not in merged]
    if missing:
        msg = (
            "MANIFEST-listed fleet-metrics-export drop-in(s) missing from "
            f"the live merged unit (origin/main {origin_main[:12]}):\n"
            + "\n".join(missing)
        )
        auto_file_metrics_dropin(msg)
        fail_loud("DRIFT-METRICS-DROPIN", msg)
    log(f"all {len(expected_dropins)} fleet-metrics-export drop-ins present in live unit")


def check_live_matches_origin_main(checkout: Path) -> None:
    """Compare live dest bytes to origin/main blobs, never the working tree.

    install.sh --check compares dests to the checkout working tree. When dests
    are symlinks into that checkout, that is a self-comparison and cannot see
    origin/main drift. This check reads `git show origin/main:<src>` so the
    expected bytes never come from the working tree.
    """
    rc, origin_main, _ = run(["git", "-C", str(checkout), "rev-parse", "origin/main"], check=False)
    if rc != 0:
        fail_loud("DRIFT-CHECKOUT", f"git rev-parse origin/main failed: {origin_main}")
    origin_main = origin_main.strip()

    manifest_bytes = git_show_bytes(checkout, f"{origin_main}:MANIFEST")
    if manifest_bytes is None:
        fail_loud("DRIFT-ORIGIN", f"origin/main ({origin_main[:12]}) has no MANIFEST")

    findings: list[str] = []
    for line in manifest_bytes.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        src, dest = parts[0], parts[1]
        if dest.startswith("/etc/"):
            continue
        expected = git_show_bytes(checkout, f"{origin_main}:{src}")
        if expected is None:
            findings.append(f"{dest}: origin/main missing {src}")
            continue
        dest_path = Path(dest)
        actual = live_file_bytes(dest_path)
        if actual is None:
            findings.append(f"{dest}: missing (want origin/main:{src})")
            continue
        if actual != expected:
            findings.append(f"{dest} does not match origin/main:{src}")

    if findings:
        fail_loud(
            "DRIFT-ORIGIN",
            "live-installed state does not match origin/main:\n" + "\n".join(findings),
        )
    log(f"live dests match origin/main ({origin_main[:12]}) blobs")


def is_agent_worktree_path(path: Path) -> bool:
    """True if path is under an agent-worktrees directory (GC-able)."""
    if "agent-worktrees" in path.parts:
        return True
    return "/agent-worktrees/" in str(path)


def check_papered_heartbeat_dropin() -> None:
    """Fail if the #313 paper-over drop-in is back (fleet-ops#370).

    DRIFT-VOLATILE only looks at unit files and enable-links. A .conf drop-in
    that overrides FLEET_OPS_DRIFT_BIN is invisible to that check.
    """
    dropin = PAPER_OVER_DROPIN
    if not dropin.exists() and not dropin.is_symlink():
        log("no paper-over heartbeat drop-in")
        return
    msg = (
        f"paper-over drop-in present: {dropin} (fleet-ops#370). "
        "Canonical checkout is pinned on fleet-heartbeat.service; "
        "this drop-in previously pointed FLEET_OPS_DRIFT_BIN at a GC-able "
        "agent-worktree and masked origin/main drift."
    )
    auto_file_paper_over(msg)
    fail_loud("DRIFT-PAPER-OVER", msg)


def check_volatile_canary_bin() -> None:
    """Fail if FLEET_OPS_DRIFT_BIN points at a GC-able agent-worktree.

    Do not inspect __file__: workers run this test from
    agent-worktrees/issue-fleet-ops-N, which is a legitimate checkout of
    the code under test. The production bug was the *override* pointing
    the installed canary at a different worktree than the deploy-clone.
    """
    env_bin = os.environ.get("FLEET_OPS_DRIFT_BIN", "")
    if not env_bin:
        log("FLEET_OPS_DRIFT_BIN unset (installed canary path)")
        return
    env_p = Path(env_bin)
    try:
        env_r = env_p.resolve()
    except OSError:
        env_r = env_p
    if not (is_agent_worktree_path(env_p) or is_agent_worktree_path(env_r)):
        log("FLEET_OPS_DRIFT_BIN is not an agent-worktree path")
        return
    msg = (
        "FLEET_OPS_DRIFT_BIN is a GC-able agent-worktree (fleet-ops#370): "
        f"{env_bin} -> {env_r}"
    )
    auto_file_paper_over(msg)
    fail_loud("DRIFT-PAPER-OVER", msg)


def check_volatile_unit_paths(checkout: Path) -> None:
    """Fail if any installed unit file or enable-link resolves into a volatile path."""
    user_systemd = HOME / ".config" / "systemd" / "user"
    if not user_systemd.is_dir():
        return

    findings: list[str] = []
    for item in user_systemd.rglob("*"):
        if not item.is_symlink() and not item.is_file():
            continue
        name = item.name
        is_unit_like = name.endswith((".service", ".timer", ".path", ".slice", ".socket", ".target"))
        is_enable_link = any(part.endswith(".wants") or part.endswith(".requires") for part in item.parts)
        if not is_unit_like and not is_enable_link:
            continue
        try:
            if item.is_symlink():
                target = item.resolve()
            else:
                continue
        except OSError:
            continue
        if str(target) == "/dev/null":
            continue
        if is_volatile_outside_checkout(target, checkout):
            findings.append(f"{item} -> {target}")

    if findings:
        msg = (
            "installed unit file or enable-link resolves into a volatile path "
            "(/tmp, /run, agent-worktrees):\n" + "\n".join(findings)
        )
        auto_file_volatile(msg)
        fail_loud("DRIFT-VOLATILE", msg)
    log("no unit file or enable-link resolves into a volatile path")


def check_checkout(checkout: Path) -> None:
    rc, _, err = run(["git", "-C", str(checkout), "rev-parse", "--git-dir"], check=False)
    if rc != 0:
        fail_loud("DRIFT-FATAL", f"{checkout} is not a git checkout: {err.strip()}")

    if not SKIP_FETCH:
        rc, _, err = run(["git", "-C", str(checkout), "fetch", "origin"], check=False)
        if rc != 0:
            fail_loud("DRIFT-CHECKOUT", f"git fetch origin failed: {err.strip()}")

    rc, head, _ = run(["git", "-C", str(checkout), "rev-parse", "HEAD"], check=False)
    if rc != 0:
        fail_loud("DRIFT-CHECKOUT", f"git rev-parse HEAD failed: {head}")
    head = head.strip()

    rc, origin_main, _ = run(["git", "-C", str(checkout), "rev-parse", "origin/main"], check=False)
    if rc != 0:
        fail_loud("DRIFT-CHECKOUT", f"git rev-parse origin/main failed: {origin_main}")
    origin_main = origin_main.strip()

    rc, branch, _ = run(
        ["git", "-C", str(checkout), "symbolic-ref", "--short", "HEAD"],
        check=False,
    )
    branch = branch.strip() if rc == 0 else ""
    if branch and branch != "main":
        msg = (
            f"canonical checkout is on branch {branch}, not main "
            f"(HEAD {head[:12]}, origin/main {origin_main[:12]}; fleet-ops#477)"
        )
        auto_file_off_main(msg)
        fail_loud("DRIFT-OFF-MAIN", msg)

    # fleet-ops#2725: a HEAD that is not an ancestor of origin/main is a
    # diverged/hot-patch commit on main — merge --ff-only would refuse it,
    # so merge-to-live is blocked. This is a distinct class from plain
    # stale-behind (HEAD is an ancestor, just behind) which deploy
    # fast-forwards. Auto-file so the block does not sit silent until the
    # blind-audit catches it 30+ min later.
    if head != origin_main:
        rc_anc, _, _ = run(
            ["git", "-C", str(checkout), "merge-base", "--is-ancestor", "HEAD", "origin/main"],
            check=False,
        )
        if rc_anc != 0:
            msg = (
                f"canonical checkout on main is diverged: HEAD {head[:12]} "
                f"is not an ancestor of origin/main {origin_main[:12]} "
                f"(hot-patch commit not on origin/main; fleet-ops#2725)"
            )
            auto_file_deploy_blocked_main(msg)
            fail_loud("DRIFT-CHECKOUT", msg)
        # Plain stale-behind (HEAD is an ancestor, just behind origin/main)
        # is not a block: deploy fast-forwards it. Keep the fail_loud so a
        # canary-only run still flags drift, but do not auto-file — the
        # next deploy tick resolves it.
        fail_loud("DRIFT-CHECKOUT", f"checkout stale: HEAD {head[:12]} != origin/main {origin_main[:12]}")

    rc, porcelain, _ = run(
        ["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=no"],
        check=False,
    )
    if rc != 0:
        fail_loud("DRIFT-CHECKOUT", f"git status failed: {porcelain}")
    if porcelain.strip():
        msg = (
            f"canonical checkout on main has uncommitted tracked changes "
            f"(HEAD {head[:12]}, origin/main {origin_main[:12]}; "
            f"hot-patch not yet on a PR; fleet-ops#2725):\n{porcelain.strip()}"
        )
        auto_file_deploy_blocked_main(msg)
        fail_loud("DRIFT-CHECKOUT", msg)

    # Off-main class is binary: branch is main or not. Observe-to-close the
    # matching open issue as soon as we know the branch is main, so the
    # `resolved-at:` comment is not held hostage to a later check that may
    # still be red (fleet-ops#774). The end-of-canary observe_close_drift_issues
    # call dedups on the comment blob, so this is idempotent.
    observe_close_drift_issues(checkout, head, only_marker=OFF_MAIN_MARKER)
    # fleet-ops#2725: deploy-blocked-on-main is also binary once we reach here
    # (clean + on main + at origin/main means the block is gone). Observe-to-
    # close its open issue the same tick, independent of later checks.
    observe_close_drift_issues(checkout, head, only_marker=DEPLOY_BLOCKED_MAIN_MARKER)

    log(f"checkout {checkout} is at origin/main ({head[:12]}) and clean")


def check_manifest_install(checkout: Path) -> None:
    rc, out, err = run([str(checkout / "install.sh"), "--check"], cwd=checkout, check=False)
    if rc == 2:
        fail_loud("DRIFT-INSTALL", f"install.sh --check usage error: {out}{err}")
    if rc != 0:
        diffs = (out + err).strip()
        fail_loud("DRIFT-INSTALL", f"MANIFEST install drift:\n{diffs}")
    log("install.sh --check: clean")


def check_enabled_units(checkout: Path, expected_enabled: set[str]) -> None:
    expected_enabled = set(expected_enabled)
    managed = fleet_managed_units(checkout)

    for repo in parse_intake_repos(checkout):
        expected_enabled.add(f"pi-intake@{repo}.timer")
        expected_enabled.add(f"pi-scout@{repo}.timer")

    missing: list[str] = []
    for unit in sorted(expected_enabled):
        rc, _, _ = run([SYSTEMCTL, "--user", "is-enabled", unit], check=False, capture=False)
        if rc != 0:
            missing.append(unit)

    rc, out, _ = run(
        [SYSTEMCTL, "--user", "list-unit-files", "--state=enabled", "--no-legend", "--plain"],
        check=False,
    )
    if rc != 0:
        fail_loud("DRIFT-UNITS", f"systemctl list-unit-files failed: {out}")

    extra: list[str] = []
    for line in out.strip().splitlines():
        unit = line.split()[0] if line.split() else ""
        if not unit:
            continue
        if unit in expected_enabled:
            continue
        if is_fleet_managed_unit(unit, managed):
            extra.append(unit)

    if missing or extra:
        parts: list[str] = []
        if missing:
            parts.append(f"missing-enabled: {', '.join(sorted(missing))}")
        if extra:
            parts.append(f"extra-enabled: {', '.join(sorted(extra))}")
        fail_loud("DRIFT-UNITS", "; ".join(parts))

    log(f"enabled units match MANIFEST + intake-repos ({len(expected_enabled)} expected)")


def is_fleet_path(path: Path) -> bool:
    return "fleet-ops" in str(path)


def check_extra_symlinks(checkout: Path, expected_dests: set[str]) -> None:
    checkout_str = str(checkout.resolve())
    managed = fleet_managed_units(checkout)
    findings: list[str] = []

    for d in MANAGED_DIRS:
        if not d.is_dir():
            continue
        for item in d.iterdir():
            if not item.is_symlink():
                continue
            if str(item) in expected_dests:
                continue
            try:
                target = item.resolve()
            except OSError:
                findings.append(f"{item} -> <broken>")
                continue
            target_str = str(target)

            # Masked unit (intake-reconcile masks via symlink to /dev/null):
            # legit disabled-state marker, not drift.
            if target_str == "/dev/null":
                continue

            # Template instance (e.g. pi-intake@0509.timer) of a shipped
            # template (pi-intake@.timer): legit enabled instance, not drift.
            # The instance symlink may target a template in this checkout OR
            # a prior checkout path; either way it is fleet-managed by name.
            if is_fleet_managed_unit(item.name, managed):
                continue

            if target_str.startswith(checkout_str + os.sep):
                findings.append(f"{item} -> {target} (extra from current checkout)")
                continue

            if is_fleet_path(target) or is_fleet_path(item):
                findings.append(f"{item} -> {target} (outside current checkout)")
                continue

            if str(d) == str(HOME / ".config" / "systemd" / "user") and is_fleet_unit(item.name):
                findings.append(f"{item} -> {target} (extra fleet unit)")

    if findings:
        fail_loud("DRIFT-EXTRAS", "hand-installed extras or stale symlinks:\n" + "\n".join(findings))

    log("no extra fleet symlinks in managed directories")


def parse_execstart_binary(line: str, home: Path) -> str | None:
    """Return the ExecStart binary path, or None if the line is not checkable.

    Strips systemd command prefixes (- @ + ! !!), takes the first token
    (or a double-quoted path), expands %h to home. Lines that still contain
    a specifier after that are skipped — they are not this leftover class.
    """
    if not line.startswith("ExecStart="):
        return None
    val = line.split("=", 1)[1].strip()
    while val:
        if val.startswith("!!"):
            val = val[2:]
            continue
        if val[0] in _EXECSTART_PREFIXES:
            val = val[1:]
            continue
        break
    if val.startswith('"'):
        end = val.find('"', 1)
        path = val[1:end] if end > 0 else val[1:]
    else:
        parts = val.split()
        path = parts[0] if parts else ""
    if not path:
        return None
    path = path.replace("%h", str(home))
    if "%" in path:
        return None
    return path


def check_missing_execstarts() -> None:
    """Fail if a user .service ExecStart binary does not exist.

    Catches leftover units after a binary is decommissioned (fleet-ops#285).
    Extra-symlink and extra-enabled checks miss this class: the files are
    regular, not MANIFEST dests, and the timer is often disabled.
    """
    unit_dir = HOME / ".config" / "systemd" / "user"
    if not unit_dir.is_dir():
        return

    findings: list[str] = []
    for path in sorted(unit_dir.glob("*.service")):
        if path.is_symlink():
            try:
                if str(path.resolve()) == "/dev/null":
                    continue
            except OSError:
                continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            binary = parse_execstart_binary(line, HOME)
            if binary is None:
                continue
            if not os.path.isabs(binary):
                continue
            if os.path.exists(binary):
                continue
            extra = ""
            timer = path.with_suffix(".timer")
            if timer.exists():
                extra = f" (sibling timer {timer.name} also present)"
            findings.append(f"{path.name}: ExecStart={binary} missing{extra}")

    if findings:
        msg = "user unit ExecStart binary is missing:\n" + "\n".join(findings)
        auto_file_orphan_exec(msg)
        fail_loud("DRIFT-MISSING-EXEC", msg)
    log("no user unit ExecStart points at a missing binary")


def main(argv: list[str] | None = None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    if args[:1] == ["--file-install-refuse"]:
        if len(args) < 4:
            log("usage: fleet-ops-drift.py --file-install-refuse <dest> <repo> <diff-file>")
            sys.exit(2)
        dest, repo, diff_path = args[1], args[2], Path(args[3])
        diff = diff_path.read_text(encoding="utf-8", errors="replace") if diff_path.is_file() else ""
        auto_file_install_refuse(dest, repo, diff)
        sys.exit(0)

    if args[:1] == ["--file-off-main"]:
        msg = (
            args[1]
            if len(args) > 1
            else "canonical deploy-clone is on a named branch other than main (fleet-ops#477)"
        )
        auto_file_off_main(msg)
        sys.exit(0)

    if args[:1] == ["--file-deploy-blocked-main"]:
        msg = (
            args[1]
            if len(args) > 1
            else "canonical deploy-clone is on main but dirty/diverged, blocking merge-to-live (fleet-ops#2725)"
        )
        auto_file_deploy_blocked_main(msg)
        sys.exit(0)

    checkout = find_checkout()
    expected_dests, expected_enabled = parse_manifest(checkout)

    check_papered_heartbeat_dropin()
    check_volatile_canary_bin()
    check_products_symlink()
    # fleet-ops#2920: run before check_canonical_source / check_checkout so a
    # missing metrics-export drop-in is surfaced even while the deploy-clone
    # is off-main or dests are hand-installed copies (DRIFT-SOURCE / DRIFT-
    # OFF-MAIN exit before check_live_matches_origin_main, hiding the dark-
    # organ symptom). This check reads MANIFEST from the origin/main blob and
    # the live merged unit, so it does not trust the checkout working tree.
    check_metrics_export_dropins(checkout)
    check_canonical_source(checkout, expected_dests)
    check_checkout(checkout)
    check_manifest_install(checkout)
    check_live_matches_origin_main(checkout)
    check_enabled_units(checkout, expected_enabled)
    check_extra_symlinks(checkout, set(expected_dests.keys()))
    check_volatile_unit_paths(checkout)
    check_missing_execstarts()

    rc, head_out, _ = run(["git", "-C", str(checkout), "rev-parse", "HEAD"], check=False)
    head = head_out.strip() if rc == 0 else "unknown"
    observe_close_drift_issues(checkout, head)

    log("drift canary: clean")
    audit("fleet-ops", "drift-ok", "checkout-and-installed-state-match-main")
    sys.exit(0)


if __name__ == "__main__":
    main()
