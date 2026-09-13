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
  FLEET_SIGNAL_RECONCILE_CLOSE_GRACE_S  default 21600 (6h)
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

# fleet-ops#5190 close-grace (flap guard): the escalation-completion
# stale-trip enforcer deliberately holds quiet ticks between bounded ladder
# actions (re-fire / fail-loud), so its alarm is ABSENT from most ticks
# while the chain is still open. Observe-to-close on a single quiet tick
# flapped: #4989 was closed while its chain still fired hours later. A
# signal under CLOSE_GRACE_TAGS that fired within the grace window (read
# back from triage history — the file IS the state, no new organ) is
# deferred, not closed. Scoped to the stale-trip tag: other detectors emit
# every tick while alarmed, and a blanket close delay would hold resolved
# agent-ready issues open for claimable hours.
CLOSE_GRACE_TAGS = {"ESCALATION-COMPLETION-STALE-TRIP"}
CLOSE_GRACE_SIGNAL_PREFIX = "loud/escalation-completion-stale-trip/"
# Per-session DEBUG-PLAYBOOK-MISSING LOUD lines are the detector's own
# deterrent log. The detector already files one daily aggregate
# (fleet-ops#4384). Queuing them as loud/debug-playbook-missing created a
# never-green issue: any other in-window session re-emits the same
# rule-level signal every tick, so observe-to-close never fires
# (fleet-ops#4620).
#
# DEBUG-PLAYBOOK-GATE-BLOCK is the same never-green shape: it keys on the
# rule (fleet-ops#4516/4579), so every in-window session-close gate failure
# re-derives the identical `loud/debug-playbook-gate-block`. #4946 is the
# live proof — filed 2026-09-10T12:54:23Z for session 0509-2315's edit
# no-op gate two-hit, it could not go green even after #4953 fixed the root
# cause (an edit no-op is not a failed attempt, so that session re-gates
# OK), because OTHER sessions' gate-blocks kept the same rule key alive and
# re-claimed the working alarm unit into StartLimitBurst claim-release
# churn. The gate's enforcement is untouched: bin/pi-issue-run still exits 1
# (WORK death) and fails the heartbeat tick while the debt is non-zero, and
# the selfsame session is already carried per session by the detector's own
# `signal: debug-playbook/<slug>` and daily-aggregate filings (#4384). The
# reconciler issue is the wrong carrier for it — a measurement/deterrent,
# not a queue item.
#
# FAIL still queues (the daily rollup).
#
# CLAIM-REAP-STARTED is the pi-issue-failed-reap entry log line written when
# the reaper begins its automatic cleanup after a worker failure
# (OnFailure). It fires on EVERY real reap (fleet-ops#4918: the same instance
# STARTED five times in an hour, each followed by a successful
# CLAIM-RELEASED / PACKETS-ARCHIVED). A reap starting is the expected
# recovery step, not a fault — the actionable reaper outcomes already carry
# their own loud tags (CLAIM-REAP-BRANCH-FAIL, CLAIM-REAP-LABEL-FAIL,
# CLAIM-REAP-PARSE-FAIL, CLAIM-REAP-NO-GH). Queuing STARTED produced a
# noisy per-repo signal (`loud/claim-reap-started/nishfleet-0509`) that
# refiled on every reap and could rarely go green.
#
# CLAIM-RELEASED is the same class: pi-issue-failed-reap writes it to
# confirm a SUCCESSFUL claim release back to agent-ready after a worker
# failure (the instance=... branch=... branch_deleted=yes label_flipped=yes
# comment_posted=yes summary line). It fires on EVERY real reap of an OPEN
# issue (fleet-ops#4930: the same CLAIM-RELEASED line appears once per failed
# fleet-ops or 0509 worker). The keys extend per-repo, not per-instance
# either way — derive_signals() harvests one distinct `repo` token to form
# `loud/claim-released/<repo>`, so any future reap re-emits the same key and
# observe-to-close can never go green. The reaper outcome is a healthy
# recovery step, not a fault: the actionable reaper failures already carry
# their own loud tags (CLAIM-REAP-BRANCH-FAIL, CLAIM-REAP-LABEL-FAIL,
# CLAIM-REAP-PARSE-FAIL, CLAIM-REAP-NO-GH), and repeated failure of one
# issue is tracked by RECLAIM-COUNT-INCREMENTED + the reclaim cooldown, not
# by a per-repo loud signal. Queuing RELEASED refiles a noisy per-repo issue
# on every reap, exactly the never-green loop #4918 fixed for STARTED.
#
# PACKETS-ARCHIVED is the same class: pi-issue-failed-reap writes it once the
# reaper's packet-archive sweep has moved the dead worker's packet files out of
# the way (fleet-ops#4930 / reaper archive_packets()). It fires on EVERY real
# reap that archived packet files during cleanup — a successful cleanup, not a
# fault. It carries a `repo=` key (repo_slug), so derive_signals() forms
# `loud/packets-archived/<repo>` the same per-repo way the CLAIM-* completion
# lines do, and any later reap re-emits the same key to keep that issue
# never-green. Archiving is the expected recovery step; the actionable reaper
# failures already carry their own loud tags, and there is nothing to escalate.
#
# FAILED-COMMAND-FAIL is the detector's own ROLLUP of the swallowed-failure
# debt, the same never-green shape #4620 fixed for DEBUG-PLAYBOOK-MISSING.
# bin/fleet-failed-command-flagged emits it with a constant message shape
# (`swallowed failures=<n> (filed=<f> deferred=<d>) — ...`), and
# _extract_signal_key() strips the counts as DYNAMIC_RE tokens, so every tick
# derives the SAME key `loud/failed-command-fail/swallowed-failures` no matter
# which sessions are in the window or how the counts move. The key can only
# go green on a tick where the 24h window holds zero findings across ALL
# sessions — and because the per-session exemption list is deliberately
# narrow (see lib/failed-command-flagged.py: edit-unmatch, schema-validation
# and "No changes made" are real swallowed failures, not no-match probes),
# the rolling window almost never empties. Live loop on 2026-09-10: the
# reconciler filed #4920, the senior panel admitted it, a fix issue (#4944)
# was filed for it, #4920 was closed as completed — and the very next tick
# re-derived the same key and filed #4944's successor under the identical
# signal. The debt is real, but this rollup is the wrong carrier for it: the
# actionable work is already tracked per session by the bin's own
# `signal: failed-command-flagged/<session>` filings, by the reconciler's
# session-keyed FAILED-COMMAND-SWALLOWED alarms (#4884), and by the
# find-stage lint that refuses to ship a run with an unnamed failure. The
# rollup line stays LOUD, stays in the triage file, and still fails the
# heartbeat tick (exit 1) — it is a measurement, not a queue item. Exactly
# like DEBUG-PLAYBOOK-MISSING, the detector's own aggregate (#2726 sized the
# debt deliberately) no longer needs the reconciler to file it.
#
# CLAIM-CLOSED-CLEANUP and CLAIM-CLOSED-RESET are the same class as
# CLAIM-RELEASED / PACKETS-ARCHIVED above: pi-issue-failed-reap writes both
# on EVERY real reap of a CLOSED issue (live #5007 / #5008, instance=0509-2347
# repo=Nishfleet/0509) as the successful cleanup that resets the dead worker's
# per-issue state files (reclaim-count, systemic, infra-death, prefer-class,
# last-death-class) after the work shipped and merged. A reap reaching this
# branch is the expected recovery step — the claim branch is already deleted,
# the agent-in-progress label already removed — not a fault, and the line's
# `repo=` key makes the derived signals per-repo (`loud/claim-closed-cleanup/
# <repo>`, `loud/claim-closed-reset/<repo>`), so any future reap of a CLOSED
# issue re-emits the same keys and observe-to-close can never go green. The
# actionable reaper failures already carry their own loud tags (BRANCH-FAIL /
# LABEL-FAIL / PARSE-FAIL / NO-GH). Queuing either refiles a noisy per-repo
# never-green issue on every closed-issue reap.
#
# EXEC-REVIEW-DISARM is the exec-review canary's disarm ACTION (fleet-ops#3731
# hard gate): bin/fleet-exec-review-canary emits it when it disables auto-merge
# on an armed PR that carries no verify/receipt cue. The message is
# `auto-merge DISABLED on <repo>#NNN (no verify cue ...)`, so derive_signals()
# harvests only the repo token and forms the per-repo key
# `loud/exec-review-disarm/<repo>` — ANY later disarm in that repo re-emits the
# same key, so the issue is never-green no matter which PR or how long the gap.
# The actionable per-PR work is already tracked: a worker finding is filed by
# the canary itself under `signal: exec-review-receipt/<slug>`, and a human
# finding is disarmed-only (fleet-ops#4117: the disarm + LOUD line is the
# signal, not an issue). The disarm already stopped the unverified merge; the
# LOUD line is the measurement. Queuing it just produced a per-repo never-green
# CLAIM-CLOSED-CLEANUP is the same class: pi-issue-failed-reap writes it
# once it has cleaned up a CLOSED issue's claim — it removes the stale
# agent-in-progress label and resets the reclaim/ladder markers (fleet-ops#5007:
# the instance=... repo=... branch=... branch_deleted=no label_removed=yes
# summary line). It fires on EVERY reaped CLOSED issue, keyed per-repo
# (`loud/claim-closed-cleanup/<repo>` from the repo_slug token), so any later
# closed reap re-emits the same key and observe-to-close can never go green —
# the same never-green loop #4918/#4930/#4955 fixed for CLAIM-REAP-STARTED /
# CLAIM-RELEASED / PACKETS-ARCHIVED. A closed-issue cleanup is the expected
# completion step, not a fault: branch_deleted=no there means the branch was
# already gone (a merged PR auto-deleted it or claim-reconcile's orphan sweep
# got it), and if a branch really existed and a real delete FAILED the reaper
# writes its own actionable CLAIM-REAP-BRANCH-FAIL tag that still queues. The
# actionable reaper outcomes (BRANCH-FAIL / LABEL-FAIL / PARSE-FAIL / NO-GH)
# still queue; only this completion-summary line is informational.
SKIP_TAGS = {
    "DEBUG-PLAYBOOK-MISSING",
    "DEBUG-PLAYBOOK-GATE-BLOCK",
    "CLAIM-CLOSED-CLEANUP",
    "CLAIM-REAP-STARTED",
    "CLAIM-RELEASED",
    "CLAIM-CLOSED-CLEANUP",
    "CLAIM-CLOSED-RESET",
    "PACKETS-ARCHIVED",
    "FAILED-COMMAND-FAIL",
    "EXEC-REVIEW-DISARM",
}

# Never-green class guard (fleet-ops#4983).
#
# Every SKIP_TAGS entry above was discovered only AFTER it paged: the
# reconciler filed a phantom alarm, a worker was dispatched, and the tag was
# added post-mortem — six times in one week (DEBUG-PLAYBOOK-MISSING #4620,
# CLAIM-REAP-STARTED #4918, CLAIM-RELEASED #4930, PACKETS-ARCHIVED #4955,
# FAILED-COMMAND-FAIL #4944, CLAIM-REAP-NEEDED #4945). The guard below ends
# the fire-first pattern: an UNKNOWN tag whose derived key is stable across
# varying message content is never-green by construction — every re-emission
# re-derives the identical signal, so the filed issue can only close when
# the line stops appearing, which for a routine telemetry line is never —
# and must not be queued. The class guard, not the tag, decides.
#
# Two never-green shapes are detected in derive_signals():
#
#   1. The bare `loud/<tag>` fallback (subkey "unspecified") carries no
#      occurrence discriminator at all, so the key is constant for the tag.
#      That fallback is reserved for the genuinely instance-keyed tags in
#      NEVER_GREEN_EXEMPT (and for deliberately routed classes below).
#   2. Structured telemetry: the message carries field=value pairs whose
#      occurrence-varying values never reach the derived key.
#      `instance=0509-2365 count=2 death_class=work` keys on field names and
#      constants only, so the next occurrence re-derives the identical
#      signal. A repo= value does not count as a discriminator —
#      `loud/<tag>/<repo>` partitions by repo, not by occurrence
#      (CLAIM-RELEASED / PACKETS-ARCHIVED were exactly this shape).
#
# Exempt: the hand-keyed extraction paths (their keying is already a
# decision) and any tag whose routing_labels() is not the agent-ready
# default — a senior/observe-to-close route is a declared fault or hold
# class, not an accidental rollup. If a suppressed signal turns out to be a
# real fault, fix its keying so the occurrence discriminator reaches the
# signal (e.g. carry the unit/session/PR into the emitted line) — never
# whitelist it back into queuing.
NEVER_GREEN_EXEMPT = {
    "UNIT-FAILED",                # per-unit keys
    "DEBUG-PLAYBOOK-GATE-BLOCK",  # deliberate rule key (also in SKIP_TAGS)
    "FAILED-COMMAND-SWALLOWED",   # per-session keys (fleet-ops#4884)
}
# field=value telemetry fields; a value is occurrence-varying when it holds
# an identifier-ish character (digits, path/unit/PR punctuation).
KV_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=([^\s,;:()]+)")
DYNAMIC_VALUE_RE = re.compile(r"[0-9/@#.]")


def _never_green_shaped(tag: str, msg: str, subkeys: list[str]) -> bool:
    """True when the derived signal is stable across varying message content.

    A stable key re-derives on every re-emission, so a filed issue can never
    observe green while the (routine, informational) line keeps firing.
    """
    if tag in NEVER_GREEN_EXEMPT or routing_labels(tag) != ["agent-ready"]:
        return False
    if subkeys == ["unspecified"]:
        return True
    varying = [
        v.rstrip(".")
        for v in KV_RE.findall(msg)
        if DYNAMIC_VALUE_RE.search(v)
    ]
    if not varying:
        return False
    for v in varying:
        if REPO_RE.fullmatch(v):
            continue
        slug = _safe_slug(v)
        if len(slug) >= 3 and any(slug in k for k in subkeys):
            return False
    return True
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
# fleet-ops#4512: issues filed by the reconciler itself carry the signal as a
# backticked line (`` `loud/<tag>/<key>` ``) — issue_body() never emits the
# literal `signal:` prefix SIGNAL_RE requires. Observe-to-close therefore
# never saw its own filings and could not close them on a green tick.
# fleet-ops#4579/#4620: rule-level signals (`` `loud/<tag>` `` with no `/key`
# suffix) must be recognized too — GATE-BLOCK files exactly such a bare rule
# signal, and leftover loud/debug-playbook-missing issues still need
# observe-to-close to see them.
BACKTICK_SIGNAL_RE = re.compile(r"`((?:loud/[a-z0-9-]+/[^\s`]+)|(?:loud/[a-z0-9-]+))`")
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

    # fleet-ops#4512/#4516: session-scoped alarms key on the session, not on
    # a file token harvested from the failure snippet. The DEBUG-PLAYBOOK-MISSING
    # and DEBUG-PLAYBOOK-GATE-BLOCK snippets are stdout of the first counted
    # attempt — keying on their file tokens produced noisy keys like
    # `_dirty-worktree-audit.py` harvested from an `ls bin/` listing, and
    # observe-to-close could not track the actual session.
    #
    # fleet-ops#4579/#4620: DEBUG-PLAYBOOK-MISSING is skipped in
    # derive_signals() (the detector files its own daily aggregate). GATE-BLOCK
    # still queues, keyed on the rule itself so a session id or a noisy snippet
    # file token cannot split or rename the signal (fleet-ops#4512).
    # `unspecified` is the sentinel derive_signals() maps to the bare rule key.
    if tag == "DEBUG-PLAYBOOK-GATE-BLOCK":
        return ["unspecified"]

    # fleet-ops#4884: FAILED-COMMAND-SWALLOWED is session-scoped — the LOUD
    # line carries session=<slug> — but the generic token harvester below
    # keys on a FILE_RE match pulled from the failure snippet. A python
    # traceback (json.load on empty gh output) puts /usr/lib/python3.12/
    # json/__init__.py in the snippet, so every such session keyed to
    # `__init__.py`. Two unrelated sessions (0509-2108, 0509-2144) shared
    # one signal and observe-to-close could not close until BOTH aged out;
    # any new python json.load swallowed failure re-opened the same issue.
    # Key on the session slug the detector already emits, same principle
    # as the #4512 fix for DEBUG-PLAYBOOK-GATE-BLOCK.
    if tag == "FAILED-COMMAND-SWALLOWED":
        m = re.search(r"(?:^|\s)session=([A-Za-z0-9_.-]+)", msg)
        if m and m.group(1):
            return [m.group(1)]
        return ["unspecified"]

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
    if tag in GREEN_TAGS or tag in SKIP_TAGS or tag.endswith(GREEN_SUFFIXES):
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
    # fleet-ops#4983: fail closed on never-green-shaped signals — a derived
    # key that cannot move with the message's occurrence-varying content
    # refiles the same issue forever and observe-to-close can never fire.
    if _never_green_shaped(tag, msg, subkeys):
        return []
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


def close_grace_last_seen(path: Path) -> dict[str, str]:
    """Latest triage emission per close-grace signal across the WHOLE file.

    fleet-ops#5190: the flap guard needs to know when a signal last fired,
    not just whether it is in the current tick. Scoped to CLOSE_GRACE_TAGS
    lines so the scan costs nothing for every other detector.
    """
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = TRIAGE_RE.match(line.rstrip("\n"))
            if not m or m.group(2) not in CLOSE_GRACE_TAGS:
                continue
            ts = m.group(1)
            for sig in derive_signals(m.group(2), m.group(3)):
                if sig.startswith(CLOSE_GRACE_SIGNAL_PREFIX) and ts > out.get(sig, ""):
                    out[sig] = ts
    return out


def routing_labels(tag: str) -> list[str]:
    # fleet-ops#4966: DEGRADED-LANES alarms are observe-to-close-only. The
    # heartbeat Tier 1 \u00a77 sees auto-restart lanes as "held, no work \u2014
    # StartLimitBurst / OnFailure are the right release path", so there is no
    # manual action a fleet worker can take, and every prior filing closed via
    # the reconciler's own observe-to-close with zero worker code
    # (4668/4701/4931/4947/4966). Routing them to agent-ready burned an
    # admission-priced worker seat per occurrence for nothing. File them under
    # observe-to-close (fleet-ops#1401) so the intake does not claim them; the
    # detector's observe-to-close still closes them on the green tick.
    #
    # fleet-ops#4965: same for AUDITOR-PANEL-PENDING. A pending senior panel is
    # load-borne — the per-tick start cap defers seat starts under backlog and
    # the panel self-heals via stale-SKIP recast (fleet-ops#3962) and
    # SKIP-EXHAUSTED abstention (fleet-ops#4503). There is no manual worker
    # action: identical filings #4812/#4877 closed via observe-to-close with
    # zero worker code, and #4965 alone burned 7 claims and 2 StartLimitBursts
    # on workers that re-verified the alarm and exited with no PR. The dedupe
    # path below retroactively re-labels an already-open agent-ready filing.
    #
    # fleet-ops#4990: same for FAILED-COMMAND-SWALLOWED. #4884 already re-keyed
    # the tag to the detector's own `session=<slug>` field, so every filing is
    # session-scoped and can only go green when THAT session ages out of the
    # 24h detection window. There is no manual worker action: the swallow itself
    # belongs to the originating session (over and gone by filing time), the
    # class is pinned in tests/fleet-failed-command-edit-unmatch.test.sh, and
    # every prior filing closed via observe-to-close with zero worker code
    # (#4884/#4921/#4933). Routing them to agent-ready burned 33 claims across
    # 10 filings in one day (2026-09-09/10), #4990 alone 8 claims over 5h with
    # 2 StartLimitBursts, on workers that re-verified the alarm and exited with
    # no PR. #4933/#4921 show the rule-level FILE_RE keys that used to exist are
    # gone after #4884, so the whole tag is observe-to-close-only. File under
    # observe-to-close (fleet-ops#1401) so the intake does not claim them; the
    # detector's observe-to-close still closes them on the green tick.
    #
    # fleet-ops#5057: same for ESCALATION-PANEL-PENDING. The exact loud() tag
    # asserted first in bin/pi-escalation-audit — a pending senior escalation
    # panel is load-borne (the per-tick start cap defers seat starts under
    # backlog) and self-heals via stale-SKIP recast (fleet-ops#3962) and
    # SKIP-EXHAUSTED abstention (fleet-ops#4503). There is no manual worker
    # action: every prior filing closed via observe-to-close with zero
    # worker code. Routing them to agent-ready burned an admission-priced
    # worker seat per occurrence on workers that re-verified the alarm and
    # exited with no PR. File under observe-to-close (fleet-ops#1401) so the
    # intake does not claim them; the detector's observe-to-close still
    # closes them on the green tick.
    if tag in {"DEGRADED-LANES", "AUDITOR-PANEL-PENDING", "FAILED-COMMAND-SWALLOWED", "ESCALATION-PANEL-PENDING"}:
        return ["observe-to-close"]
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


def issue_title(tag: str, msg: str, signal: str = "") -> str:
    short = re.sub(r"^signal:\s*\S+\s*", "", msg)
    short = short.split(" — ", 1)[0].split("::", 1)[0].strip()
    if len(short) > 80:
        short = short[:77] + "..."
    base = f"alarm: {tag} — {short}"
    # Embed the signal key in the title (fleet-ops#4622) so a filed-issue
    # title check can distinguish a genuine filing from a dedupe-comment
    # pointer at an unrelated issue.
    if signal:
        return f"{base} [{signal}]"
    return base


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
    # fleet-ops#5076: issue_body() writes the trailer as `` `{signal}` `` on
    # its own line, which the old substring check (`f"{signal}\n" in body` /
    # `body.endswith(signal)`) could never match — a backtick sits between the
    # key and the newline. Match the signal only when it IS the whole line —
    # bare, backticked, or behind a `signal:` key — so a prose mention of the
    # key cannot satisfy the lookup.
    marker = re.compile(
        rf"^[ \t]*(?:signal:[ \t]*)?`?{re.escape(signal)}`?[ \t]*$",
        re.MULTILINE,
    )
    for issue in issues:
        body = (issue.get("body") or "") + "\n" + "\n".join(
            str(c.get("body") or "") for c in (issue.get("comments") or [])
        )
        if marker.search(body):
            return issue
    return None


def _hydrate_comments(
    issue: dict[str, Any],
    repo: str,
    gh: str,
    dry_run: bool,
    cache: dict[int, list[dict[str, Any]]],
) -> None:
    """Attach comments to a deduped issue if they were not included in the
    bulk list (fleet-ops#4552). The bulk list omits comments to avoid the 504;
    only the heartbeat throttle needs them, so they are fetched per-issue the
    first time that issue is touched in a run.
    """
    if "comments" in issue:
        return
    number = issue.get("number")
    if not isinstance(number, int):
        issue["comments"] = []
        return
    issue["comments"] = _issue_comments(repo, number, gh, dry_run, cache)


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


def _issue_comments(
    repo: str,
    number: int,
    gh: str,
    dry_run: bool,
    cache: dict[int, list[dict[str, Any]]],
) -> list[dict[str, Any]]:
    """Return the comments for one issue, fetched lazily.

    The bulk issue list deliberately omits comments so a single GraphQL call
    does not time out at open-issue volume (fleet-ops#4552). The daily
    heartbeat throttle is the only consumer that needs comment bodies, and it
    touches a bounded set (currently-alarmed deduped issues) per tick, so it
    fetches them one issue at a time. Results are cached per run; failures are
    cached as [] so a transient timeout degrades to "no recent comment" (post
    a heartbeat) rather than crashing the reconciler.
    """
    if number in cache:
        return cache[number]
    if dry_run:
        cache[number] = []
        return cache[number]
    proc = subprocess.run(
        [gh, "issue", "view", str(number), "-R", repo, "--json", "comments"],
        capture_output=True,
        text=True,
        check=False,
    )
    comments: list[dict[str, Any]] = []
    if proc.returncode == 0 and (proc.stdout or "").strip():
        try:
            parsed = json.loads(proc.stdout)
            comments = parsed.get("comments") or []
        except json.JSONDecodeError:
            comments = []
    cache[number] = comments
    return comments


def load_open_issues(
    repo: str,
    gh: str,
    from_json: str | None,
) -> list[dict[str, Any]]:
    if from_json:
        return json.loads(Path(from_json).read_text(encoding="utf-8"))
    # fetch the issue list WITHOUT comments: requesting the full comment
    # bodies for up to 300 open issues in one GraphQL call routinely times
    # out (HTTP 504) at fleet open-issue volume, which made this loader
    # return [] every tick. With an empty open_issues the observe-to-close
    # pass had nothing to close, so green alarm issues (and the per-slug
    # DEBUG-PLAYBOOK class that re-claims them) never closed. Comments are
    # only needed for the daily-heartbeat throttle, which fetches them
    # lazily per-issue in has_recent_heartbeat_comment (fleet-ops#4552).
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
            "number,title,body,labels,createdAt",
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


def _parse_issue_number(out: str) -> str:
    """Extract a GitHub issue number from a fleet-issue-file result.

    fleet-issue-file may emit a URL, a ``#NNN`` token, or a JSON payload with
    a ``number``/``url`` field (it can also comment on a duplicate and return
    that existing issue's URL — the wrong-pointer case fleet-ops#4622 fixes).
    """
    if not out:
        return ""
    m = re.search(r"/issues/(\d+)", out)
    if m:
        return m.group(1)
    m = re.search(r"#(\d+)", out)
    if m:
        return m.group(1)
    try:
        payload = json.loads(out)
    except (json.JSONDecodeError, TypeError):
        return ""
    if isinstance(payload, dict):
        for key in ("number", "issue", "id"):
            val = payload.get(key)
            if isinstance(val, (int, str)) and str(val).isdigit():
                return str(val)
        url = payload.get("url")
        if isinstance(url, str):
            m = re.search(r"/issues/(\d+)", url)
            if m:
                return m.group(1)
    return ""


def verify_filed_signal(
    repo: str,
    out: str,
    signal: str,
    gh: str,
    dry_run: bool,
    triage: Path | None,
) -> bool:
    """Verify the issue just filed (or commented-on by dedupe) carries the
    signal key in its title (fleet-ops#4622).

    fleet-issue-file dedupes by token overlap and may COMMENT on an unrelated
    existing issue, returning its URL — a wrong pointer that would silently
    satisfy observe-to-close next tick. Fetch the returned issue's title and
    confirm it contains the signal key. On mismatch, emit a LOUD
    FILED-LINK-MISMATCH so the wrong pointer can never satisfy
    observe-to-close. Returns True on mismatch (loud), False when the title
    matches (or the number could not be resolved, e.g. dry-run).
    """
    if dry_run:
        return False
    number = _parse_issue_number(out)
    if not number:
        return False
    proc = subprocess.run(
        [gh, "issue", "view", number, "-R", repo, "--json", "title", "--jq", ".title"],
        capture_output=True,
        text=True,
        check=False,
    )
    title = (proc.stdout or "").strip()
    if proc.returncode != 0 or not title or signal not in title:
        loud(
            triage,
            "FILED-LINK-MISMATCH",
            f"filed issue #{number} title='{title or '<unavailable>'}' does not "
            f"contain signal key {signal}; a wrong pointer cannot satisfy "
            f"observe-to-close (fleet-ops#4622)",
        )
        return True
    return False


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
    close_grace_last_seen_map: dict[str, str] | None = None,
    close_grace_s: int = 0,
) -> dict[str, Any]:
    now = _parse_iso(now_str)
    if close_grace_last_seen_map is None:
        close_grace_last_seen_map = {}
    summary: dict[str, Any] = {
        "alarm_count": 0,
        "filed": 0,
        "deduped": 0,
        "heartbeat_comments": 0,
        "closed": 0,
        "rerouted": 0,
        "capped": 0,
        "close_deferred": 0,
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
        for m in BACKTICK_SIGNAL_RE.finditer(body):
            sig = m.group(1).strip()
            if sig:
                open_by_signal[sig] = issue

    # File or heartbeat-comment.
    filed_count = 0
    capped_sigs: list[str] = []
    comment_cache: dict[int, list[dict[str, Any]]] = {}
    for sig in sorted(current_signals):
        alarm = signal_to_alarm[sig]
        existing = open_by_signal.get(sig)
        if existing:
            summary["deduped"] += 1
            _hydrate_comments(existing, repo, gh, dry_run, comment_cache)
            # fleet-ops#4987/#4990: a tag routed to observe-to-close is only
            # routed for NEW filings. An already-open agent-ready (or
            # agent-in-progress) filing of the SAME tag, filed before that
            # routing landed (e.g. #4987, #4990), is deduped but never
            # downgraded, so the intake keeps claiming it and burns an
            # admission-priced worker seat on an observe-to-close-only alarm
            # with zero manual action. Retroactively re-label it so the intake
            # stops claiming it; observe-to-close still closes it on the green
            # tick regardless of label (test 14b/16c/17c).
            if routing_labels(alarm["tag"]) == ["observe-to-close"]:
                o_labels = [str(l.get("name")) for l in (existing.get("labels") or []) if l.get("name")]
                if any(lb in o_labels for lb in ("agent-ready", "agent-in-progress")):
                    remove = [lb for lb in ("agent-ready", "agent-in-progress") if lb in o_labels]
                    if gh_edit_labels(repo, existing["number"], ["observe-to-close"], remove, gh, dry_run):
                        summary["rerouted"] += 1
                        log(f"reroute #{existing['number']} (signal={sig}) {','.join(remove)} -> observe-to-close (retroactive observe-to-close-only downgrade for {alarm['tag']})")
                    else:
                        log(f"WARN: failed to downgrade #{existing['number']} (signal={sig})")
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

        title = issue_title(alarm["tag"], alarm["msg"], signal=sig)
        body = issue_body(sig, alarm["tag"], alarm["msg"], alarm["ts"])
        labels = routing_labels(alarm["tag"])
        rc, out = file_issue(repo, title, body, labels, issue_file, dry_run)
        if rc == 0:
            log(f"filed {sig} -> {out}")
            # FILED-LINK verify (fleet-ops#4622): fleet-issue-file may dedupe
            # to an unrelated issue and return its URL. Verify the returned
            # issue's title carries the signal key; on mismatch emit a LOUD
            # FILED-LINK-MISMATCH so the wrong pointer can never satisfy
            # observe-to-close next tick.
            if verify_filed_signal(repo, out, sig, gh, dry_run, triage):
                # fleet-ops#4841: a wrong pointer must NOT count as a successful
                # filing — it does not carry the signal key, so observe-to-close
                # can never close it, and counting it would waste the auto-file
                # cap on a pointer that can never go green. Do not consume the
                # cap (filed_count stays put) so the signal is re-filed on the
                # next tick once the dedupe no longer collapses it onto the
                # wrong issue.
                summary["filed_mismatches"] = summary.get("filed_mismatches", 0) + 1
                continue
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
        # fleet-ops#5190 close-grace (flap guard): a close-grace signal that
        # fired within the grace window is deferred, not closed — a single
        # quiet tick between the detector's bounded actions must not resolve
        # the alarm while the condition persists.
        last_fired = close_grace_last_seen_map.get(sig)
        if last_fired is not None:
            try:
                fired_age_s = (now - _parse_iso(last_fired)).total_seconds()
            except ValueError:
                fired_age_s = close_grace_s
            if fired_age_s < close_grace_s:
                summary["close_deferred"] += 1
                log(
                    f"observe-to-close: deferred #{issue['number']} (signal={sig} "
                    f"last fired {int(fired_age_s)}s ago < {close_grace_s}s grace — flap guard)"
                )
                continue
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
    p.add_argument("--close-grace-s", type=int, default=None)
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
    close_grace_s = (
        args.close_grace_s
        if args.close_grace_s is not None
        else int(os.environ.get("FLEET_SIGNAL_RECONCILE_CLOSE_GRACE_S") or 21600)
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
    grace_last_seen = close_grace_last_seen(triage_path) if ok_to_close else {}
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
        close_grace_last_seen_map=grace_last_seen,
        close_grace_s=close_grace_s,
    )

    log(
        f"complete: alarms={summary['alarm_count']} filed={summary['filed']} "
        f"deduped={summary['deduped']} heartbeat={summary['heartbeat_comments']} "
        f"closed={summary['closed']} rerouted={summary['rerouted']} capped={summary['capped']} "
        f"close_deferred={summary['close_deferred']}"
    )
    if args.json:
        print(json.dumps(summary, sort_keys=True))

    if summary["capped"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
