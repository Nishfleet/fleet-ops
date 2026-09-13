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

fleet-ops#5602: a stray sibling artifact (*.bak* / *.orig next to a
MANIFEST-managed path) no longer holds merge-to-live red until a judge
hand-archives it. DRIFT-QUARANTINE moves the artifact to
agent-state/backups/manifest-sprawl/, names the writer in QUARANTINE.log,
auto-files the class once (deduped), and re-runs install.sh --check — the
gate is red at most the tick that found the sprawl.

fleet-ops#5663: `--file-install-refuse` also reconciles the divergence
itself — pushes the live content onto a machine-owned reconcile/<src>
branch, opens (or refreshes) a PR, and arms auto-merge — and names the
hot-patch writer from its dated .pre-* sibling + actions.log line + the
journald unit window (UNATTRIBUTED with candidates when none exist).

Environment seams (overridden by tests):
  FLEET_OPS_CHECKOUT              path to the fleet-ops deploy checkout
  FLEET_OPS_AUDIT_LOG             drift audit log (default: ~/.local/state/fleet-ops/drift-audit.log)
  FLEET_OPS_TRIAGE                heartbeat triage file for LOUD lines
  FLEET_OPS_SKIP_FETCH            set to 1 to skip the git fetch (offline tests)
  FLEET_OPS_SYSTEMCTL             path to systemctl (default: systemctl)
  FLEET_OPS_WORKSPACES_ROOT       default /home/nish/workspaces
  FLEET_OPS_CANONICAL_CHECKOUT    default <workspaces>/tooling/fleet-ops-deploy-clone
  FLEET_OPS_ALLOW_NONCANONICAL    set to 1 to skip the source-path gate
  FLEET_OPS_DRIFT_FILE            1 (default) auto-file DRIFT-SOURCE, DRIFT-MISSING-EXEC, DRIFT-PAPER-OVER, DRIFT-PRODUCTS-SYMLINK, DRIFT-OFF-MAIN, DRIFT-DEPLOY-BLOCKED-MAIN, DRIFT-VOLATILE, DRIFT-METRICS-DROPIN, DRIFT-QUARANTINE; 0 skip gh
  FLEET_OPS_DRIFT_CLOSE           1 (default) close a drift issue on a later green tick once it carries `resolved-at:`; 0 only comment (fleet-ops#1156)
  FLEET_OPS_DRIFT_REPO            default Nishfleet/fleet-ops
  FLEET_OPS_DRIFT_RECONCILE       1 (default) open/refresh a reconcile/<src> PR on
                                  --file-install-refuse (fleet-ops#5663); 0 skip
  FLEET_OPS_ACTIONS_LOGS          ':'-separated actions.log paths the hot-patch
                                  attribution reads (fleet-ops#5663)
  FLEET_OPS_JOURNALCTL            journalctl binary for the unit-window fallback
  FLEET_OPS_RETARGET_BIN          fleet-ops-retarget-products (default: next to this file)
  FLEET_OPS_PRODUCTS_LINK         products/fleet-ops symlink (default: <workspaces>/products/fleet-ops)
  FLEET_OPS_QUARANTINE_DIR        sprawl quarantine dir (default:
                                  <workspaces>/agent-state/backups/manifest-sprawl; fleet-ops#5602)
  FLEET_OPS_ACTIONS_LOG           console actions.log read for sprawl writer
                                  attribution (default: <workspaces>/agent-state/actions.log)
  GH                              gh binary (tests stub this)
"""

from __future__ import annotations

import datetime
import json
import os
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


def _ensure_worker_token() -> None:
    """Use the nishfleet-worker App token for any GitHub write (fleet-ops#3445).

    Fail closed if the App cannot mint and no token was inherited from a parent
    organ, so a dead App never falls through to the human gh identity. Human gh
    is read-only for organs. GH Actions (tests) has no App creds and stubs gh
    as read-only, so skip minting there.
    """
    if os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_ACTIONS") == "true":
        return
    # A test injects a fake gh (GH != 'gh'); no human gh write is possible, so
    # skip minting there too. Production callers never set GH.
    if os.environ.get("GH", "gh") != "gh":
        return
    wt = os.environ.get(
        "NISHFLEET_WORKER_TOKEN_BIN",
        f"{os.environ.get('HOME', '/home/nish')}/.local/bin/worker-token",
    )
    try:
        out = subprocess.run(
            [wt, "--print"], capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("fleet-ops#3445: worker-token --print failed - refusing human-gh writes: %s" % exc, file=sys.stderr)
        sys.exit(1)
    if out.returncode != 0:
        print("fleet-ops#3445: worker-token --print rc=%s - refusing human-gh writes: %s" % (out.returncode, out.stderr.strip()[:200]), file=sys.stderr)
        sys.exit(1)
    for line in out.stdout.splitlines():
        if line.startswith("export GH_TOKEN="):
            os.environ["GH_TOKEN"] = line[len("export GH_TOKEN="):].strip()
            return
    print("fleet-ops#3445: worker-token --print output not an export GH_TOKEN line - refusing human-gh writes", file=sys.stderr)
    sys.exit(1)


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
# fleet-ops#5663: a NONFATAL REFUSE on a live-newer file auto-opens a
# reconciliation PR (live content -> repo file, auto-merge armed) instead of
# waiting on a judge hand-carry. 0 disables the reconcile (issue still filed).
DRIFT_RECONCILE = os.environ.get("FLEET_OPS_DRIFT_RECONCILE", "1") == "1"
# Writer attribution for the hot-patch issue/PR (fleet-ops#5663): a conforming
# writer leaves a dated .pre-* sibling plus an actions.log line naming the file;
# the detector also lists journald user units active around the write so an
# unattributed patch still names its candidates. Colon-separated log paths.
ACTIONS_LOGS = os.environ.get(
    "FLEET_OPS_ACTIONS_LOGS",
    "/home/nish/workspaces/agent-state/actions.log:"
    + str(HOME / ".local" / "state" / "pi-packet" / "actions.log"),
).split(":")
JOURNALCTL = os.environ.get("FLEET_OPS_JOURNALCTL", "journalctl")
ALLOW_NONCANONICAL = os.environ.get("FLEET_OPS_ALLOW_NONCANONICAL", "") == "1"
WORKSPACES_ROOT = Path(os.environ.get("FLEET_OPS_WORKSPACES_ROOT", "/home/nish/workspaces"))
CANONICAL_CHECKOUT = Path(
    os.environ.get(
        "FLEET_OPS_CANONICAL_CHECKOUT",
        str(WORKSPACES_ROOT / "tooling" / "fleet-ops-deploy-clone"),
    )
)
# fleet-ops#5602: a stray sibling artifact (*.bak* / *.orig next to a
# MANIFEST-managed path) used to hold the merge-to-live gate red until a
# judge hand-archived it. The canary now quarantines the artifact under
# agent-state/backups/manifest-sprawl/ — the same backups root the
# 2026-09-11T23:43Z hand-repair used — records who wrote it in
# QUARANTINE.log, and auto-files the class once (deduped).
QUARANTINE_DIR = Path(
    os.environ.get(
        "FLEET_OPS_QUARANTINE_DIR",
        str(WORKSPACES_ROOT / "agent-state" / "backups" / "manifest-sprawl"),
    )
)
# Writer attribution reads the fleet console log for lines naming the
# artifact or its managed file (fleet-ops#5602).
ACTIONS_LOG = Path(
    os.environ.get(
        "FLEET_OPS_ACTIONS_LOG",
        str(WORKSPACES_ROOT / "agent-state" / "actions.log"),
    )
)
SOURCE_MARKER = "canonical-checkout-drift: fleet-ops#176"
ORPHAN_EXEC_MARKER = "orphan-execstart: fleet-ops#285"
PAPER_OVER_MARKER = "paper-over-dropin: fleet-ops#370"
PRODUCTS_MARKER = "products-symlink-stale: fleet-ops#410"
OFF_MAIN_MARKER = "deploy-clone-off-main: fleet-ops#477"
# MANIFEST entries installed as file COPIES (not symlinks) by design; exempt
# from the must-be-a-symlink check. Keep in lockstep with MANIFEST
# (fleet-ops#2910 seat-caps.json, #3838 pi-models.json, #3858 the gap).
COPY_INSTALLED_SRC_NAMES = {"seat-caps.json", "pi-models.json", "model-candidates.json"}
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
# fleet-ops#5602: stray sibling artifact quarantined out of the managed
# tree. The filed issue names the writer + quarantine path; the class is
# green again the same tick, so observe-to-close lands `resolved-at:` on
# the next green tick and closes on the one after.
SPRAWL_MARKER = "manifest-sprawl-quarantine: fleet-ops#5602"

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
    SPRAWL_MARKER,
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


def auto_file_drift(marker: str, title: str, extra: str, msg: str) -> tuple[int | None, str]:
    """File one issue for a drift class. Dedup on marker in open issue bodies.

    Returns (number, body) of an already-open issue carrying the marker, or
    (None, "") when a new issue was filed / filing was skipped or failed.
    """
    if not DRIFT_FILE:
        log(f"file skipped (FLEET_OPS_DRIFT_FILE!=1) marker={marker}")
        return None, ""
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
                    number = item.get("number")
                    log(f"dedup: open {DRIFT_REPO}#{number} already carries {marker}")
                    return (number if isinstance(number, int) else None), body
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
    return None, ""


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
        SPRAWL_MARKER: "manifest-sprawl quarantine",
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


def _journal_units_at(epoch: float, window_s: int = 600) -> list[str]:
    """User units that logged in a +/-window around a timestamp.

    fleet-ops#5663: fallback writer attribution — when a hot-patch leaves no
    .pre-* sibling and no actions.log line, the units alive at the write are
    the candidate writers. Best-effort: journalctl missing/failing/empty all
    degrade to [].
    """
    units: list[str] = []
    fmt = "%Y-%m-%d %H:%M:%S UTC"
    since = datetime.datetime.fromtimestamp(epoch - window_s, datetime.timezone.utc).strftime(fmt)
    until = datetime.datetime.fromtimestamp(epoch + window_s, datetime.timezone.utc).strftime(fmt)
    try:
        proc = subprocess.run(
            [JOURNALCTL, "--user", "--since", since, "--until", until, "-o", "json", "--no-pager"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0:
        return []
    seen: set[str] = set()
    for line in proc.stdout.splitlines():
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(rec, dict):
            continue
        unit = rec.get("_SYSTEMD_USER_UNIT") or rec.get("USER_UNIT") or rec.get("UNIT") or ""
        if isinstance(unit, str) and unit and unit not in seen:
            seen.add(unit)
            units.append(unit)
    return sorted(units)[:8]


# actions.log stamps are bracketed (`[2026-09-11T22:09:11Z]`, also HH:MM-only
# `[2026-09-11T23:09Z]`), but some lines carry a bare leading ISO ts or a
# bracketed ts at the END — try the bracket anywhere, then a leading bare ts.
_ACTIONS_TS_BRACKET = re.compile(r"\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?Z?)\]")
_ACTIONS_TS_LEAD = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?Z?)\b")


def _actions_log_hits(name: str, mtime: float) -> list[str]:
    """actions.log lines naming `name` within 24h before / 15min after mtime."""
    hits: list[str] = []
    for logpath in ACTIONS_LOGS:
        lp = Path(logpath)
        if not lp.is_file():
            continue
        try:
            lines = lp.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            if name not in line:
                continue
            stripped = line.strip()
            m = _ACTIONS_TS_BRACKET.search(stripped) or _ACTIONS_TS_LEAD.match(stripped)
            if not m:
                continue
            raw = m.group(1)
            for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%MZ", "%Y-%m-%dT%H:%M:%S"):
                try:
                    ts = datetime.datetime.strptime(raw, fmt).replace(tzinfo=datetime.timezone.utc).timestamp()
                    break
                except ValueError:
                    ts = -1
            if ts < 0:
                continue
            if mtime - 86400 <= ts <= mtime + 900:
                hits.append(f"{lp.name}: {line.strip()}")
    return hits[-3:]


def hotpatch_attribution(dest: str) -> str:
    """Best-effort name of the writer that hot-patched a live file.

    fleet-ops#5663: the 2026-09-11T21:31Z models.json hot-patch left no dated
    backup and no actions.log line, so it was unattributable and recovery
    needed a judge hand-carry. A conforming writer leaves a dated `.pre-*`
    sibling plus an actions.log line (`.bak*` is banned next to MANIFEST dests
    — fleet-ops#3273 sprawl); this reads those artifacts and the journald unit
    window around the file mtime, so a conforming writer is named and a
    non-conforming one is reported UNATTRIBUTED with candidate units.
    """
    live = Path(os.path.realpath(dest))
    if not live.exists():
        return f"writer: unknown (live file {live} missing at detect time)"
    mtime = live.stat().st_mtime
    mtime_iso = datetime.datetime.fromtimestamp(mtime, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    parts: list[str] = []

    # (a) dated backup siblings the writer left — the sanctioned name is
    # <name>.pre-<why>-<ts> (`.bak*` trips the #3273 sprawl check); detection
    # accepts any <name>.* sibling so a stray still counts as evidence.
    backups: list[tuple[float, str]] = []
    try:
        for sib in live.parent.iterdir():
            if not sib.name.startswith(live.name + "."):
                continue
            try:
                backups.append((sib.stat().st_mtime, sib.name))
            except OSError:
                continue
    except OSError:
        pass
    backups.sort(reverse=True)
    for bak_m, bak_name in backups:
        if bak_m <= mtime + 60:
            when = datetime.datetime.fromtimestamp(bak_m, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            parts.append(f"backup sibling {bak_name} (mtime {when})")
            break

    # (b) actions.log lines naming the file around the write.
    hits = _actions_log_hits(live.name, mtime)
    if hits:
        parts.append("actions.log: " + " | ".join(hits))

    # (c) journald user units alive at the write window — always gathered so
    # an unattributed patch still names its candidates.
    units = _journal_units_at(mtime)

    if parts:
        out = "writer: " + "; ".join(parts)
        if units:
            out += "; units active at write window: " + ", ".join(units)
        return out
    if units:
        return (
            f"writer: UNATTRIBUTED — no dated .pre-* sibling of {live.name} and no "
            f"actions.log line names it (mtime {mtime_iso}); units active at "
            "write window: " + ", ".join(units)
        )
    return (
        f"writer: UNATTRIBUTED — no dated .pre-* sibling of {live.name}, no "
        f"actions.log line names it, no journald units found (mtime {mtime_iso})"
    )


def auto_file_install_refuse(dest: str, repo: str, diff: str, attribution: str = "") -> None:
    """File one issue for a live file that is newer and differs from the repo copy.

    fleet-ops#5663: the body carries the writer attribution, and dedup is
    per-dest (marker + dest=...) so a second file's hot-patch is not
    suppressed by an unrelated open hot-patch issue. On a dedup hit the new
    attribution lands as a comment so the open issue always names the latest
    writer.
    """
    extra = (
        "install.sh refused to overwrite a live file whose mtime is newer "
        "than the repo copy because the content differs. A hot-patch is in "
        "place. A reconcile/<path> PR carrying the live content is opened "
        "(auto-merge armed) by this canary (fleet-ops#5663); merging it or "
        "restoring the live file to the repo copy resolves this."
    )
    title = f"Live fleet-ops file hot-patched: {Path(dest).name}"
    body = f"Live file `{dest}` is newer and differs from repo `{repo}`:\n\n{attribution}\n\n```diff\n{diff}\n```"
    marker = f"{HOTPATCH_MARKER} dest={dest}"
    existing, existing_body = auto_file_drift(marker, title, extra, body)
    # Dedup hit: comment only when the writer evidence is NEW — a re-detected
    # patch of the same write yields the same attribution, and a comment per
    # deploy-check tick until the reconcile PR merges would be spam.
    if existing and attribution and attribution not in existing_body:
        try:
            subprocess.run(
                [GH, "issue", "comment", str(existing), "-R", DRIFT_REPO, "--body",
                 f"recurred at {now_iso()} with new writer evidence\n{attribution}"],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError:
            pass


# Credential-looking JSON fields. Live models.json carries apiKey values as
# `!`-command / `$`-env references by convention — a NEW literal value in the
# live file is a secret a hand hot-patch could have dropped, and the reconcile
# must never auto-commit one (fleet-ops#5663; hard line: secrets never get
# committed).
_SECRETISH_KEY = re.compile(
    r'"(?:apiKey|api_key|token|secret|password|privateKey|accessKey)"\s*:\s*"([^"]+)"'
)


def _new_literal_secrets(live_b: bytes, repo_b: bytes) -> list[str]:
    """Credential values present in live but not the repo copy, not a reference."""
    live_v = set(_SECRETISH_KEY.findall(live_b.decode("utf-8", "replace")))
    repo_v = set(_SECRETISH_KEY.findall(repo_b.decode("utf-8", "replace")))
    return sorted(
        v for v in live_v - repo_v
        if v and not v.startswith(("!", "$")) and "${" not in v
    )


def _redact_literal_secrets(text: str) -> str:
    """Replace literal credential values with ***REDACTED***; !/$ refs stay."""
    def _sub(m: re.Match) -> str:
        v = m.group(1)
        if v.startswith(("!", "$")) or "${" in v:
            return m.group(0)
        return m.group(0).replace(v, "***REDACTED***")

    return _SECRETISH_KEY.sub(_sub, text)


def reconcile_install_refuse(dest: str, repo: str, diff: str, attribution: str) -> None:
    """Open (or refresh) a PR carrying the live hot-patched file into the repo.

    fleet-ops#5663: a NONFATAL REFUSE means live is deliberately newer and
    different — the durable fix is repo <- live, not live <- repo. Before this,
    every recurrence (models.json 2026-09-07 / 09-11 14:48Z / 09-11 21:31Z;
    seat-caps fleet-ops#5493) waited on a judge hand-carrying the delta while
    every fleet-ops merge failed DEPLOY-INSTALL. This pushes the live content
    onto a machine-owned `reconcile/<src>` branch (one open PR per file,
    updated in place on each new refuse) and arms auto-merge so the normal
    gates land it.

    Only the live_newer_than_repo refuse reconciles: the seat-caps cap-
    DOWNGRADE refuse is a stale-checkout guard and must never push live caps
    back over a deliberate merged drop — that path never reaches here.

    Best-effort: every failure logs WARN and returns — the refuse path must
    never fail harder than it already did.
    """
    if not DRIFT_RECONCILE:
        log("reconcile skipped (FLEET_OPS_DRIFT_RECONCILE!=1)")
        return
    live = Path(os.path.realpath(dest))
    if not live.is_file():
        log(f"reconcile skipped: live file {live} missing")
        return
    repo_path = Path(repo)
    if not repo_path.is_file():
        log(f"reconcile skipped: repo copy {repo} missing")
        return

    rc, out, _ = run(
        ["git", "-C", str(repo_path.parent), "rev-parse", "--show-toplevel"],
        check=False,
    )
    if rc != 0 or not out.strip():
        log(f"reconcile skipped: {repo} is not inside a git checkout")
        return
    top_r = resolved(Path(out.strip()))

    # Same guard as refuse_noncanonical_install: a checkout under the
    # workspaces root that is not the canonical deploy clone must never push
    # reconcile PRs off its own tree.
    if is_under(top_r, resolved(WORKSPACES_ROOT)) and top_r != resolved(CANONICAL_CHECKOUT):
        log(f"reconcile skipped: checkout {top_r} is non-canonical (want {resolved(CANONICAL_CHECKOUT)})")
        return

    src_rel = os.path.relpath(str(resolved(repo_path)), str(top_r))
    if src_rel.startswith("..") or os.path.isabs(src_rel):
        log(f"reconcile skipped: {repo} not under checkout {top_r}")
        return
    branch = f"reconcile/{src_rel}"
    try:
        live_bytes = live.read_bytes()
        repo_bytes = repo_path.read_bytes()
    except OSError as e:
        log(f"WARN: reconcile could not read {live} or {repo}: {e}")
        return

    new_secrets = _new_literal_secrets(live_bytes, repo_bytes)
    if new_secrets:
        log(
            f"WARN: reconcile skipped: live {live.name} adds {len(new_secrets)} "
            "literal credential value(s) not in the repo copy — secrets never get "
            "auto-committed; the drift issue stays open for a human carry (fleet-ops#5663)"
        )
        return

    run(["git", "-C", str(top_r), "fetch", "-q", "origin"], check=False)

    # origin/main already carries the live bytes (a fix merged between the
    # refuse and this run): nothing to reconcile.
    if git_show_bytes(top_r, f"origin/main:{src_rel}") == live_bytes:
        log(f"reconcile skipped: origin/main:{src_rel} already matches live")
        return

    rc, ls_out, _ = run(
        ["git", "-C", str(top_r), "ls-remote", "--heads", "origin", f"refs/heads/{branch}"],
        check=False,
    )
    if rc != 0:
        log(f"WARN: reconcile ls-remote failed for {branch} — skipping (offline?)")
        return
    remote_branch = bool(ls_out.strip())

    open_pr = ""
    proc = subprocess.run(
        [GH, "pr", "list", "-R", DRIFT_REPO, "--state", "open", "--head", branch,
         "--json", "number"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        try:
            rows = json.loads(proc.stdout)
            if rows and isinstance(rows[0], dict):
                open_pr = str(rows[0].get("number") or "")
        except (json.JSONDecodeError, IndexError, AttributeError):
            open_pr = ""

    base = "origin/main"
    if remote_branch and open_pr:
        # Refresh in place: build on the PR branch tip so the push is a plain
        # fast-forward — never a force-push.
        run(
            ["git", "-C", str(top_r), "fetch", "-q", "origin",
             f"+refs/heads/{branch}:refs/remotes/origin/{branch}"],
            check=False,
        )
        base = f"origin/{branch}"
    elif remote_branch:
        # Stale machine branch whose PR merged or closed: delete so the fresh
        # push is a clean create (the PR retains its commits on GitHub).
        run(["git", "-C", str(top_r), "push", "origin", "--delete", branch], check=False)

    tmp = Path(tempfile.mkdtemp(prefix="fleet-ops-reconcile-"))
    pushed_sha = ""
    try:
        rc, wout, werr = run(
            ["git", "-C", str(top_r), "worktree", "add", "--detach", str(tmp), base],
            check=False,
        )
        if rc != 0:
            log(f"WARN: reconcile worktree add failed: {(werr or wout).strip()}")
            return
        target = tmp / src_rel
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(live_bytes)
        except OSError as e:
            log(f"WARN: reconcile could not write {target}: {e}")
            return
        run(["git", "-C", str(tmp), "add", "--", src_rel], check=False)
        rc, _, _ = run(["git", "-C", str(tmp), "diff", "--cached", "--quiet"], check=False)
        if rc == 0:
            log(f"reconcile: {branch} already carries live content")
        else:
            rc, cout, cerr = run(
                ["git", "-C", str(tmp),
                 "-c", "user.name=nishfleet-worker[bot]",
                 "-c", "user.email=321485391+nishfleet-worker[bot]@users.noreply.github.com",
                 "commit", "-q", "-m",
                 f"reconcile(deploy): carry live {live.name} into {src_rel} (fleet-ops#5663)"],
                check=False,
            )
            if rc != 0:
                log(f"WARN: reconcile commit failed: {(cerr or cout).strip()}")
                return
            rc, pout, perr = run(
                ["git", "-C", str(tmp), "push", "origin", f"HEAD:refs/heads/{branch}"],
                check=False,
            )
            if rc != 0:
                log(f"WARN: reconcile push of {branch} failed: {(perr or pout).strip()}")
                return
            _, pushed_sha, _ = run(["git", "-C", str(tmp), "rev-parse", "HEAD"], check=False)
            pushed_sha = pushed_sha.strip()
            log(f"reconcile: pushed {pushed_sha[:12]} to {branch}")
    finally:
        run(["git", "-C", str(top_r), "worktree", "remove", "--force", str(tmp)], check=False)
        if tmp.exists():
            shutil.rmtree(tmp, ignore_errors=True)
        run(["git", "-C", str(top_r), "worktree", "prune"], check=False)

    if open_pr:
        # Comment only when a new commit actually landed — a re-detected patch
        # of the same write pushes nothing, and a comment per deploy-check
        # tick until merge would be spam. The arm stays every-tick
        # (gh pr merge --auto is idempotent and silent).
        if pushed_sha:
            subprocess.run(
                [GH, "pr", "comment", open_pr, "-R", DRIFT_REPO, "--body",
                 f"reconcile refreshed at {now_iso()} — live `{live.name}` re-pushed to `{branch}`"
                 f" ({pushed_sha[:12]})\n{attribution}\n(fleet-ops#5663)"],
                capture_output=True,
                text=True,
                check=False,
            )
        arm = subprocess.run(
            [GH, "pr", "merge", open_pr, "-R", DRIFT_REPO, "--auto", "--squash"],
            capture_output=True,
            text=True,
            check=False,
        )
        if arm.returncode == 0:
            log(f"reconcile: refreshed open PR #{open_pr} for {branch} (auto-merge armed)")
        else:
            log(f"WARN: reconcile re-arm of PR #{open_pr} failed: {arm.stderr.strip()[:200]}")
        return

    body = (
        f"install.sh REFUSEd to overwrite live `{dest}` (mtime newer than the repo copy, "
        f"content differs) — a hot-patch is in place and every fleet-ops merge is failing "
        f"DEPLOY-INSTALL until the repo catches up. This PR carries the live content into "
        f"`{src_rel}` so merge-to-live unblocks without a judge hand-carry "
        f"(fleet-ops#5663; class marker fleet-ops#463).\n\n"
        f"{attribution}\n\n"
        f"```diff\n{diff}\n```\n\n"
        f"Verification: after merge, install.sh sees live == repo for `{src_rel}`; accept probe "
        f"`journalctl --user -u fleet-deploy-check --since -24h -o cat | grep -c \"install.sh failed\"` "
        f"-> 0 sustained across two consecutive ticks (fleet-ops#5663).\n"
        f"run-proof: fleet-ops-drift.py --file-install-refuse pushed reconcile branch `{branch}`"
        + (f" at {pushed_sha[:12]}" if pushed_sha else "")
        + f" on {now_iso()}\n"
        f"net-positive-because: machine reconcile — carries live bytes verbatim, no hand edit\n"
        f"{HOTPATCH_MARKER} dest={dest}\n"
        "reconcile-auto: fleet-ops#5663\n"
    )
    _fd, _body_path = tempfile.mkstemp(prefix="fleet-ops-reconcile-body-", suffix=".md")
    os.close(_fd)
    body_file = Path(_body_path)
    try:
        body_file.write_text(body, encoding="utf-8")
        create = subprocess.run(
            [GH, "pr", "create", "-R", DRIFT_REPO, "--head", branch, "--base", "main",
             "--title", f"reconcile(deploy): carry live {live.name} into {src_rel} (fleet-ops#5663)",
             "--body-file", str(body_file)],
            capture_output=True,
            text=True,
            check=False,
        )
        if create.returncode != 0:
            log(f"WARN: reconcile pr create failed for {branch}: {create.stderr.strip()[:200]}")
            return
        pr_url = create.stdout.strip().splitlines()[-1] if create.stdout.strip() else ""
        arm = subprocess.run(
            [GH, "pr", "merge", pr_url or branch, "-R", DRIFT_REPO, "--auto", "--squash"],
            capture_output=True,
            text=True,
            check=False,
        )
        if arm.returncode == 0:
            log(f"reconcile: opened {pr_url or 'PR'} for {branch} (auto-merge armed)")
        else:
            # A transient arm failure is not fatal: the heartbeat-tier1 queue
            # pass re-arms green reconcile/ PRs (fleet-ops#5663).
            log(f"WARN: reconcile opened {pr_url or 'PR'} but arm failed: {arm.stderr.strip()[:200]}")
    finally:
        try:
            body_file.unlink()
        except OSError:
            pass


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
        # silently rewrite the live config; check_live_matches_origin_main
        # still compares its bytes to origin/main, and install.sh still guards
        # cap downgrades. fleet-ops#3838 added config/pi-models.json
        # (-> ~/.pi/agent/models.json) as a copy for the same reason but did
        # not exempt it, so every deploy tick went LOUD DEPLOY-CHECK-FAILED on
        # a DIFF-FILE finding for a file that is a copy by design (fleet-ops#3858).
        # Exempt every MANIFEST copy-install; the set is pinned to MANIFEST by
        # tests/fleet-ops-drift-copy-install-exempt.test.sh.
        if src.name in COPY_INSTALLED_SRC_NAMES:
            continue
        # fleet-ops#3263: Pi provider extensions (template/extensions/**) are
        # installed as file COPIES, not symlinks. A symlink into the deploy-clone
        # working tree resolves their relative import `../seat-health.ts` against the
        # repo tree, where that sibling does not live -> runtime import failure on
        # every extension load (proven: Bun and Node both resolve relative imports
        # against the symlink's real path). A copy keeps resolution on the live
        # extensions dir, where seat-health.ts lives. Exempt from the symlink check.
        # src here is the RESOLVED absolute path; we need the relative src from
        # the manifest. Check if the dest is an extension path.
        dest_str = str(dest)
        if "/.pi/agent/extensions/" in dest_str:
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


def canonical_json(blob: bytes) -> str | None:
    """Canonical (sorted-key, fixed-separator) text for a JSON document.

    Returns None when the bytes are not a decodable JSON document. Used to
    compare a copy-install JSON config dest to its origin/main blob: those
    files are deliberately re-serialized on the live box (install.sh's
    seat_caps_merge_unknown_providers merge, fleet-ops#4205; an external
    writer per fleet-ops#4894), so byte equality is unachievable by design
    and a byte-only compare reports drift forever on a semantically
    identical config. install.sh --check already accepts that class
    (fleet-ops#4948); this mirrors the same rule for the drift canary.
    """
    try:
        value = json.loads(blob.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def ordered_json(blob: bytes) -> str | None:
    """Canonical (fixed-separator, document-order) text for a JSON document.

    Returns None when the bytes are not a decodable JSON document. Unlike
    canonical_json the keys are NOT sorted: for a plain .json dest a
    reordered file is drift and only whitespace is exempt (fleet-ops#5201).
    The copy-install names keep the sorted canonical because the live merge
    can legitimately reorder or collapse keys (fleet-ops#5161).
    """
    try:
        value = json.loads(blob.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


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
        # Skip npm-pin entries - these are pinned to the installed pi-coding-agent
        # package examples, not from the fleet-ops repo origin/main.
        if src.startswith("npm-pin:"):
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
            # fleet-ops#4948 parity: a copy-install JSON config (seat-caps.json,
            # pi-models.json, model-candidates.json) is legitimately
            # re-serialized live, so compare it semantically. A real
            # structural change, unparseable JSON, or any non-copy-install
            # dest still fails byte-strict. Duplicate object keys collapse the
            # same way every JSON parser collapses them (last wins), and a
            # duplicate key produces exactly this class (fleet-ops#5161).
            if Path(src).name in COPY_INSTALLED_SRC_NAMES:
                want_json = canonical_json(expected)
                got_json = canonical_json(actual)
                if want_json is not None and want_json == got_json:
                    log(
                        f"{dest}: bytes differ from origin/main:{src} but the "
                        "JSON is equivalent (copy-install re-serialization)"
                    )
                    continue
            elif dest_path.suffix == ".json":
                # fleet-ops#5201: any other .json dest can also be
                # re-serialized live at a different indent width — the exact
                # seat-caps.json shape that kept DEPLOY-CHECK red. Compare
                # the parsed documents with document order preserved: a
                # whitespace-only rewrite is reformatted-not-drifted; a
                # reordered or changed file still fails.
                want_json = ordered_json(expected)
                got_json = ordered_json(actual)
                if want_json is not None and want_json == got_json:
                    log(
                        f"{dest}: bytes differ from origin/main:{src} but the "
                        "JSON is equivalent (reformatted, not drifted)"
                    )
                    continue
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


# install.sh --check sprawl lines, e.g.
#   DIFF: /path/foo.bak-tag-20260911 (.bak next to managed MANIFEST file /path/foo)
# The parenthetical kind is fixed text (.bak / .orig), not the artifact's
# own suffix.
SPRAWL_DIFF_RE = re.compile(
    r"^DIFF: (.+?) \((\.bak|\.orig) next to managed MANIFEST file (.+?)\)\s*$",
    re.MULTILINE,
)


def last_log_hit(needle: str) -> str | None:
    """Last actions.log / drift-audit line naming `needle` (bounded tail read)."""
    if not needle:
        return None
    for logf in (ACTIONS_LOG, AUDIT_LOG):
        try:
            if not logf.is_file():
                continue
            size = logf.stat().st_size
            with logf.open("r", encoding="utf-8", errors="replace") as f:
                if size > 512 * 1024:
                    f.seek(size - 512 * 1024)
                    f.readline()  # discard a partial first line
                lines = f.read().splitlines()
        except OSError:
            continue
        for line in reversed(lines):
            if needle in line:
                text = line.strip()
                if len(text) > 200:
                    text = text[:200] + "..."
                return f"{logf.name}:{text}"
    return None


def sprawl_writer(artifact: Path, managed: str) -> str:
    """Best-effort attribution for a stray sibling artifact (fleet-ops#5602).

    Three signals: the fleet's naming convention
    (<managed-base>.bak-<tag>-<date> — the tag names the writer, e.g.
    .bak-onefleet-5588-20260911), the artifact's owner+mtime, and the last
    actions.log / drift-audit line naming the artifact or its managed file.
    """
    parts: list[str] = []
    base = Path(managed).name
    name = artifact.name
    tag = name[len(base) + 1:] if name.startswith(base + ".") else name
    parts.append(f"nametag={tag}")
    try:
        st = artifact.lstat()
        try:
            owner = pwd.getpwuid(st.st_uid).pw_name
        except (KeyError, OSError):
            owner = str(st.st_uid)
        mtime = datetime.datetime.fromtimestamp(
            st.st_mtime, datetime.timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        parts.append(f"owner={owner} mtime={mtime}")
    except OSError:
        parts.append("stat=unreadable")
    hit = last_log_hit(name) or (last_log_hit(base) if base != name else None)
    if hit:
        parts.append(f"log={hit}")
    return " ".join(parts)


def unique_quarantine_path(name: str) -> Path:
    """A collision-free destination inside the quarantine dir."""
    cand = QUARANTINE_DIR / name
    if not cand.exists() and not cand.is_symlink():
        return cand
    stamp = now_iso().replace("-", "").replace(":", "")
    cand = QUARANTINE_DIR / f"{name}.q-{stamp}"
    i = 1
    while cand.exists() or cand.is_symlink():
        i += 1
        cand = QUARANTINE_DIR / f"{name}.q-{stamp}-{i}"
    return cand


def auto_file_sprawl(msg: str) -> None:
    """File one issue when stray sibling artifacts were quarantined."""
    extra = (
        "A .bak/.orig sibling next to a MANIFEST-managed path used to hold "
        "the merge-to-live gate red until a judge hand-archived it "
        "(fleet-ops#5602). The canary now quarantines the artifact under "
        "agent-state/backups/manifest-sprawl/ and names the writer above. "
        "Backups belong outside the managed tree — the writer should park "
        "them there in the first place."
    )
    auto_file_drift(
        SPRAWL_MARKER,
        "Stray sibling artifact quarantined beside MANIFEST-managed path",
        extra,
        msg,
    )


def quarantine_sprawl_diffs(diffs: str) -> bool:
    """Move sprawl artifacts flagged by install.sh --check out of the managed
    tree, name the writer, and report. Returns True if >=1 was quarantined.

    fleet-ops#5602: a .bak/.orig sibling next to a MANIFEST-managed path
    held the whole merge-to-live gate red until a judge noticed by hand
    (4th recurrence 2026-09-11T23:42Z: global-standing-rules.canonical.md
    .bak-onefleet-5588-20260911 held DEPLOY-CHECK red while install.sh
    itself ran clean). Quarantine instead of refuse: the artifact is moved
    (never deleted), the writer is named in QUARANTINE.log and the LOUD
    line, and the caller re-checks — so the gate is red at most the tick
    that found the sprawl.
    """
    moved: list[str] = []
    for m in SPRAWL_DIFF_RE.finditer(diffs):
        artifact = Path(m.group(1).strip())
        managed = m.group(3).strip()
        writer = sprawl_writer(artifact, managed)
        try:
            QUARANTINE_DIR.mkdir(parents=True, exist_ok=True)
            dest = unique_quarantine_path(artifact.name)
            shutil.move(str(artifact), str(dest))
        except OSError as e:
            loud("DRIFT-QUARANTINE", f"could not quarantine {artifact}: {e} — left in place")
            audit("fleet-ops", "sprawl-quarantine-failed", f"{artifact} writer={writer} err={e}")
            continue
        try:
            with (QUARANTINE_DIR / "QUARANTINE.log").open("a", encoding="utf-8") as f:
                f.write(
                    f"{now_iso()} artifact={artifact} managed={managed} "
                    f"moved_to={dest} writer={writer}\n"
                )
        except OSError as e:
            log(f"WARN: could not append to quarantine ledger {QUARANTINE_DIR}/QUARANTINE.log: {e}")
        audit("fleet-ops", "sprawl-quarantine", f"{artifact} -> {dest} writer={writer}")
        moved.append(f"{artifact} -> {dest} (managed: {managed}; writer: {writer})")
    if not moved:
        return False
    msg = (
        "stray sibling artifact(s) quarantined out of the managed tree "
        "(fleet-ops#5602; backups belong outside MANIFEST dirs):\n"
        + "\n".join(moved)
    )
    loud("DRIFT-QUARANTINE", msg)
    auto_file_sprawl(msg)
    return True


def check_manifest_install(checkout: Path) -> None:
    rc, out, err = run([str(checkout / "install.sh"), "--check"], cwd=checkout, check=False)
    if rc == 2:
        fail_loud("DRIFT-INSTALL", f"install.sh --check usage error: {out}{err}")
    if rc != 0:
        diffs = (out + err).strip()
        # fleet-ops#5602: quarantine stray .bak/.orig siblings, then re-check.
        # If the sprawl was the whole drift the gate never goes red; residual
        # diffs still fail loud below.
        if quarantine_sprawl_diffs(diffs):
            rc, out, err = run([str(checkout / "install.sh"), "--check"], cwd=checkout, check=False)
            if rc == 2:
                fail_loud("DRIFT-INSTALL", f"install.sh --check usage error: {out}{err}")
            if rc == 0:
                log("install.sh --check: clean after sprawl quarantine")
                return
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
    _ensure_worker_token()

    args = list(sys.argv[1:] if argv is None else argv)
    if args[:1] == ["--file-install-refuse"]:
        if len(args) < 4:
            log("usage: fleet-ops-drift.py --file-install-refuse <dest> <repo> <diff-file>")
            sys.exit(2)
        dest, repo, diff_path = args[1], args[2], Path(args[3])
        diff = diff_path.read_text(encoding="utf-8", errors="replace") if diff_path.is_file() else ""
        # The diff lands in a public issue/PR body — never post a literal
        # credential a hand hot-patch could have dropped (fleet-ops#5663).
        diff = _redact_literal_secrets(diff)
        attribution = hotpatch_attribution(dest)
        log(f"hot-patch attribution: {attribution}")
        auto_file_install_refuse(dest, repo, diff, attribution)
        reconcile_install_refuse(dest, repo, diff, attribution)
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
