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
import hashlib
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
# Per-session DEBUG-PLAYBOOK-MISSING LOUD lines are the detector's own
# deterrent log. The detector already files one daily aggregate
# (fleet-ops#4384). Queuing them as loud/debug-playbook-missing created a
# never-green issue: any other in-window session re-emits the same
# rule-level signal every tick, so observe-to-close never fires
# (fleet-ops#4620). GATE-BLOCK still queues (a real session-close gate
# failure). FAIL still queues (the daily rollup).
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
SKIP_TAGS = {
    "DEBUG-PLAYBOOK-MISSING",
    "CLAIM-REAP-STARTED",
    "CLAIM-RELEASED",
}
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


# Auto-file iteration order (fleet-ops#4957). The per-session
# `loud/failed-command-swallowed/*` flood emits 40+ keys per tick, and plain
# alphabetical order reaches `f` long before `r`/`s`/`t`, so the cap of 5 was
# always spent on the flood and `loud/red-pr-repair/*` was starved
# indefinitely. Order the loop by class severity instead. The class is the
# segment right after `loud/`; matching is by prefix so `escalation-`
# covers `escalation-foo`. Unmapped classes sort after every mapped one and
# keep plain alphabetical order among themselves via the `sig` tiebreak.
# The cap itself is unchanged — this only decides WHAT the cap is spent on.
SIGNAL_CLASS_PRIORITY = (
    "red-pr-repair",
    "red-pr-escalate",
    "timer-no-next",
    "drift-install",
    "exec-review-disarm",
    "escalation-",
    "straitly-",
    "degraded-lanes",
)
# Tail priority for every class NOT named above. `failed-command-swallowed`
# is deliberately NOT in the tuple: it is the bottom tier, one whole step
# BELOW the tail (see SIGNAL_CLASS_PRIORITY_FLOOD). Keeping it out of the
# tuple is what lets every unmapped class — `claim-reap-needed`,
# `decisions-ledger-fail`, `deploy-blocked`, `deploy-install`, ... — sort
# ABOVE the flood and keep today's plain alphabetical order among itself.
SIGNAL_CLASS_PRIORITY_TAIL = len(SIGNAL_CLASS_PRIORITY)
# The only class that sorts after the tail, so the 40+ keys/tick flood can
# never outrank a class that is filed today.
SIGNAL_CLASS_PRIORITY_FLOOD = SIGNAL_CLASS_PRIORITY_TAIL + 1
SIGNAL_CLASS_FLOOD_PREFIX = "failed-command-swallowed"


def signal_class_priority(sig: str) -> int:
    # The class is the segment after `loud/` for canonical
    # `loud/<class>/<key>` signals. The repo also carries real signals with
    # no `loud/` prefix (`timer-manifest/<unit>`, `decisions-ledger/<slug>`,
    # `cred-expiry/<provider>`, `exec-review-receipt/<slug>`,
    # `chain-e2e-drill/fixture`); for those the class is the first segment.
    # A keyless (`loud/<class>`) or prefixless (`loud`) string must not raise.
    if sig.startswith("loud/"):
        parts = sig.split("/", 2)
        cls = parts[1] if len(parts) > 1 else sig
    else:
        cls = sig.split("/", 1)[0]
    for idx, prefix in enumerate(SIGNAL_CLASS_PRIORITY):
        if cls.startswith(prefix):
            return idx
    if cls.startswith(SIGNAL_CLASS_FLOOD_PREFIX):
        return SIGNAL_CLASS_PRIORITY_FLOOD
    return SIGNAL_CLASS_PRIORITY_TAIL


def signal_sort_key(sig: str) -> tuple[int, str]:
    return (signal_class_priority(sig), sig)


def signal_starve_state_path() -> Path:
    state_dir = os.environ.get("FLEET_SIGNAL_RECONCILE_STATE_DIR")
    if state_dir:
        return Path(state_dir) / "signal-starve.json"
    return Path.home() / ".local" / "state" / "fleet-heartbeat" / "signal-starve.json"


def oldest_unfiled_age(capped_sigs: list[str], now: datetime) -> int:
    """Whole seconds since the oldest `first_unfiled_at` recorded for the
    capped keys in the starve-state file (fleet-ops#4957).

    A deliberately tolerant reader: a missing, unreadable, malformed or
    key-less state file yields 0 so a bad state file can never crash or
    change the tick. Phase 2 owns the writer; this only reads.
    """
    try:
        payload = json.loads(signal_starve_state_path().read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            return 0
        # Accept either {"signals": {sig: {...}}} or a flat {sig: {...}}.
        entries = payload.get("signals")
        if not isinstance(entries, dict):
            entries = payload
        ages: list[float] = []
        for sig in capped_sigs:
            entry = entries.get(sig)
            if not isinstance(entry, dict):
                continue
            first = entry.get("first_unfiled_at")
            if not isinstance(first, str) or not first:
                continue
            try:
                first_dt = _parse_iso(first)
            except (TypeError, ValueError):
                # One unparsable entry must not zero the age of the others.
                continue
            if first_dt.tzinfo is None or first_dt.utcoffset() is None:
                # A naive timestamp would make `now - first_dt` raise
                # TypeError, which the outer backstop would swallow into a 0
                # for EVERY entry. Skip just this entry instead.
                continue
            ages.append((now - first_dt).total_seconds())
        if not ages:
            return 0
        return max(0, int(max(ages)))
    except Exception:  # noqa: BLE001 — telemetry must never crash the tick
        return 0


# Starved-signal detector (fleet-ops#4957 accept item 3). A key that stays
# unfiled for more than STARVE_TICKS consecutive ticks means the cap is being
# spent on other classes, so the alarm itself never becomes an issue. That is
# a control-plane fault and must produce its own ONE deduped issue rather than
# a log line, because a log line is exactly what a single flapping green tick
# erases — which is how fleet-ops#4623 was closed with no fix landed.
STARVE_TICKS = 3
# `-FAIL`-shaped on purpose: the existing routing_labels() helper sends any
# `*-FAIL` tag to `escalate-senior` + `critical-path`, which is where a
# pile-up of unfiled alarms belongs (the cap being hit is a control-plane
# fault, not ordinary queue work).
STARVE_TAG = "SIGNAL-STARVE-FAIL"
# Short, stable tag for the tick-log line so the fact is greppable next to
# the SIGNAL-RECONCILE-CAP line it explains.
STARVE_LOUD_TAG = "SIGNAL-STARVE"


def _load_starve_state() -> dict[str, Any]:
    """Tolerant reader of the whole starve-state payload (fleet-ops#4957).

    Same tolerance as oldest_unfiled_age(): a missing, unreadable, malformed
    or wrongly-typed file yields {} so a bad state file can never crash the
    tick or change what gets filed. A missing file is normal on the first
    tick and silent; anything else logs a WARN so the fault is visible.
    """
    path = signal_starve_state_path()
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    except OSError as e:
        log(f"WARN: could not read starve state {path}: {e}")
        return {}
    try:
        payload = json.loads(raw)
    except ValueError as e:
        log(f"WARN: could not parse starve state {path}: {e}; treating as empty")
        return {}
    if not isinstance(payload, dict):
        log(f"WARN: starve state {path} is {type(payload).__name__}, not an object; treating as empty")
        return {}
    return payload


def _starve_entries(payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Per-key entries, from either {"signals": {...}} or a flat file."""
    entries = payload.get("signals")
    if not isinstance(entries, dict):
        entries = payload
    return {
        sig: entry
        for sig, entry in entries.items()
        if isinstance(sig, str) and isinstance(entry, dict)
    }


def starve_state_writable_here() -> bool:
    """True when this run may write the starve-state file (fleet-ops#4957).

    The offline seam `FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON` replaces the
    live issue list with a fixture, and `bin/chain-e2e-drill` drives the real
    reconciler that way with no state dir of its own. An unguarded writer
    would therefore let every drill (and every test) run prune the LIVE state
    file and reset the counters of a genuinely starved key, so the detector
    would never reach its threshold on a real fleet. A run may write only
    when it is the authoritative live tick, or when it has been given its own
    `FLEET_SIGNAL_RECONCILE_STATE_DIR` (the test seam).
    """
    if os.environ.get("FLEET_SIGNAL_RECONCILE_STATE_DIR"):
        return True
    return not os.environ.get("FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON")


def write_starve_state(entries: dict[str, Any], reported_token: str = "") -> None:
    """Persist the per-tick starve state; WARN, never raise (fleet-ops#4957).

    `entries` carries EXACTLY the keys capped on this tick, so a key that was
    filed this tick, that already had an open issue (deduped/heartbeat) or
    that went green has nothing carried forward and is dropped here — this
    file cannot leak dead keys the way the red-pr-repair state dir does in the
    same issue. No capped keys at all prunes the file outright, so it cannot
    grow without bound either.

    `reported_token` is the ONE top-level dedupe key (the current starvation
    set's `loud/signal-starve/<slug>-<hash>` token), not a per-key marker:
    suppression belongs to the set, so a CHANGED set is a new token and files
    its own issue instead of being muted by one key's stale marker.

    The temp name is unique per process (pid + random suffix) because two
    concurrent runs sharing one fixed `<file>.tmp` made one of them lose its
    write (FileNotFoundError on the rename) and re-file duplicates. No flock:
    the live tick is serial, so this only has to survive tests and an
    accidental overlap, not to provide mutual exclusion.
    """
    path = signal_starve_state_path()
    try:
        if not entries:
            path.unlink(missing_ok=True)
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f"{path.name}.{os.getpid()}.{os.urandom(4).hex()}.tmp")
        tmp.write_text(
            json.dumps(
                {"signals": entries, "reported_token": reported_token},
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        tmp.replace(path)
    except Exception as e:  # noqa: BLE001 — an unwritable state file must never fail the tick
        log(f"WARN: could not write starve state {path}: {e}")


def starve_signal_for(starved: list[str]) -> str:
    """Stable, collision-free dedupe token for a starved key set (fleet-ops#4957).

    The dedupe key IS the sorted key list, so the same starved set files once
    and does not re-file on tick 5, 6, 7. Deliberately not shaped like the
    `loud/<class>/<key>` signals the canaries emit, so it cannot collide with
    or shadow a real detector signal.

    A readable slug is not enough on its own: two DISTINCT sets sharing a long
    common prefix slugged to the SAME token past the truncation, so the second
    set's alarm was silently muted. Hence the readable 48-char prefix PLUS the
    first 12 hex of a sha1 over the exact newline-joined sorted keys —
    deterministic for one set (same set, same token) and different for
    different sets. Single backticked token, no whitespace, so
    BACKTICK_SIGNAL_RE still reads it back next tick.
    """
    keys = sorted(starved)
    prefix = _safe_slug("-".join(keys), 48) or "unknown"
    digest = hashlib.sha1("\n".join(keys).encode("utf-8")).hexdigest()[:12]
    return f"loud/signal-starve/{prefix}-{digest}"


def _starve_age_seconds(entry: dict[str, Any], now: datetime) -> Any:
    """Whole seconds since the entry's first_unfiled_at, "?" if uncomparable.

    The subtraction is INSIDE the try on purpose: `now` may be a naive
    `--now`/`FLEET_SIGNAL_RECONCILE_NOW` override while the state file holds a
    `Z`-suffixed (aware) timestamp, and `aware - naive` raises TypeError.
    Raised out of `reconcile()` that TypeError aborts the whole tick —
    observe-to-close, the state write, the summary and the exit code all lost
    — which is the exact silent abort this detector exists to remove. A `now`
    with no usable offset can never yield an age either, so it reports "?"
    rather than guessing.
    """
    if now.tzinfo is None or now.utcoffset() is None:
        return "?"
    first = entry.get("first_unfiled_at")
    if not isinstance(first, str) or not first:
        return 0
    try:
        first_dt = _parse_iso(first)
        if first_dt.tzinfo is None or first_dt.utcoffset() is None:
            return "?"
        return max(0, int((now - first_dt).total_seconds()))
    except (TypeError, ValueError, OverflowError):
        return "?"


def _starve_first_unfiled_at_usable(value: Any) -> bool:
    """True only if `value` is a parsable, timezone-aware ISO timestamp.

    A garbage or naive `first_unfiled_at` used to be carried forward verbatim
    forever: the entry's age stayed "?" and `oldest_unfiled_age()` stayed 0
    for good. Treating it as absent lets the tick reset it to `now_str`, so
    the counter self-heals instead of rotting.
    """
    if not isinstance(value, str) or not value:
        return False
    try:
        dt = _parse_iso(value)
    except (TypeError, ValueError):
        return False
    return dt.tzinfo is not None and dt.utcoffset() is not None


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
    for issue in issues:
        body = (issue.get("body") or "") + "\n" + "\n".join(
            str(c.get("body") or "") for c in (issue.get("comments") or [])
        )
        if f"{signal}\n" in body or body.endswith(signal):
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
        for m in BACKTICK_SIGNAL_RE.finditer(body):
            sig = m.group(1).strip()
            if sig:
                open_by_signal[sig] = issue

    # File or heartbeat-comment.
    filed_count = 0
    capped_sigs: list[str] = []
    comment_cache: dict[int, list[dict[str, Any]]] = {}
    ordered_signals = sorted(
        current_signals,
        key=signal_sort_key,
    )
    for sig in ordered_signals:
        alarm = signal_to_alarm[sig]
        existing = open_by_signal.get(sig)
        if existing:
            summary["deduped"] += 1
            _hydrate_comments(existing, repo, gh, dry_run, comment_cache)
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

    # Starvation telemetry (fleet-ops#4957): make the shortfall a number, not
    # an inference. Both summary keys are set unconditionally so the --json
    # shape does not change, but the starve-state file is only read on the
    # ticks that actually have capped keys — the majority have none.
    summary["n_unfiled"] = len(capped_sigs)
    summary["oldest_unfiled_age"] = 0
    if capped_sigs:
        summary["oldest_unfiled_age"] = oldest_unfiled_age(capped_sigs, now)
        loud(
            triage,
            "SIGNAL-RECONCILE-CAP",
            f"auto-file cap reached ({cap}); n_unfiled={summary['n_unfiled']} "
            f"oldest_unfiled_age={summary['oldest_unfiled_age']}; "
            f"unfiled signals: {', '.join(capped_sigs)}",
        )

    # Starved-signal detector (fleet-ops#4957 accept item 3): a key that stays
    # unfiled for more than STARVE_TICKS consecutive ticks must itself produce
    # ONE deduped issue naming the starved keys, so a stealth starve cannot be
    # cleared by a flapping single green tick. Runs once per tick, right after
    # the cap check, and is as tolerant as the reader: a malformed or
    # unwritable state file logs a WARN and never crashes the tick or changes
    # what is filed.
    #
    # The state is rebuilt from THIS tick's capped keys only. A key filed this
    # tick, a key that already had an open issue (deduped/heartbeat) and a key
    # that left current_signals (went green) all lose their entry — only capped
    # keys may retain state, which is exactly the leak the red-pr-repair state
    # dir shows in this issue.
    prev_payload = _load_starve_state()
    prev_starve = _starve_entries(prev_payload)
    starve_entries: dict[str, Any] = {}
    for sig in capped_sigs:
        prev_entry = prev_starve.get(sig) or {}
        first_unfiled_at = prev_entry.get("first_unfiled_at")
        if not _starve_first_unfiled_at_usable(first_unfiled_at):
            # Same ISO8601-with-timezone shape (now_str) that _parse_iso and
            # oldest_unfiled_age() read, so the phase-1 telemetry and this
            # writer always agree about a key's age. A garbage or naive value
            # is reset, not carried forward forever.
            first_unfiled_at = now_str
        try:
            unfiled_ticks = int(prev_entry.get("consecutive_unfiled") or 0)
        except (TypeError, ValueError):
            unfiled_ticks = 0
        starve_entries[sig] = {
            "first_unfiled_at": first_unfiled_at,
            "consecutive_unfiled": unfiled_ticks + 1,
        }

    starved = sorted(
        sig
        for sig, entry in starve_entries.items()
        if entry["consecutive_unfiled"] > STARVE_TICKS
    )
    summary["starved"] = len(starved)
    summary["starve_filed"] = 0
    reported_token = ""
    if starved:
        starve_signal = starve_signal_for(starved)
        detail = "; ".join(
            f"{sig} unfiled {starve_entries[sig]['consecutive_unfiled']} ticks "
            f"(age {_starve_age_seconds(starve_entries[sig], now)}s)"
            for sig in starved
        )
        # Two cheap dedupe mechanisms, both used: (a) the backticked
        # `loud/signal-starve/<slug>-<hash>` token in the body is seen next
        # tick by open_by_signal()'s BACKTICK_SIGNAL_RE; (b) the single
        # top-level `reported_token` in the state file covers the case where
        # that token path misses (issue-list hiccup, issue closed out of
        # band), so tick 5 cannot re-file. The suppression key is the TOKEN
        # — i.e. the exact sorted key list — not a per-key marker: a CHANGED
        # starved set has a new token and therefore files its own issue,
        # which is what "dedupe key = the sorted key list" means. A set that
        # reverts to an already-reported exact list is caught by
        # `already_open` as long as its issue is open.
        already_open = starve_signal in open_by_signal
        already_reported = prev_payload.get("reported_token") == starve_signal
        # Preserve the previous token only while the set is unchanged. It is
        # (re)set on a SUCCESSFUL filing below, never just because a filing
        # was attempted: a failed filing must not mute the next tick, since no
        # issue exists to suppress against.
        reported_token = starve_signal if already_reported else ""
        if file_issues and not already_open and not already_reported:
            # This is a detector alarm ABOUT the cap, not a signal being
            # auto-filed: filed_count is deliberately left untouched here, so
            # the cap stays exactly what it was (5 by default) and in force.
            # At most one starve issue per starved key set per tick.
            title = issue_title(
                STARVE_TAG,
                f"{len(starved)} signal(s) unfiled > {STARVE_TICKS} ticks: "
                f"{', '.join(starved)}",
                signal=starve_signal,
            )
            body = (
                f"{len(starved)} detector signal(s) stayed unfiled on more than "
                f"{STARVE_TICKS} consecutive heartbeat ticks (fleet-ops#4957).\n\n"
                f"The auto-file cap is saturated on every one of those ticks, "
                f"so these are the keys that lost: the lowest-priority keys "
                f"were never filed. This is the cap alarm, not a report that "
                f"some other class of work took their place.\n\n"
                f"- starved signals: {', '.join(starved)}\n"
                f"- unfiled: {detail}\n"
                f"- observed tick: `{now_str}`\n"
                f"- detector→queue reconciler: fleet-ops#362\n"
                f"- dedupe key: the sorted key list above — filed once per "
                f"starved set, never once per tick\n\n"
                "This is the cap alarm, not a signal being auto-filed: it does "
                "NOT consume the auto-file cap.\n\n"
                "Do NOT close this issue on PR merge alone. The reconciler "
                "closes it only when the starve clears — when every key above "
                "is filed or goes green on a real heartbeat tick.\n\n"
                f"`{starve_signal}`\n"
            )
            # No verify_filed_signal() here on purpose: unlike a signal issue,
            # this alarm does not depend on the returned pointer to stay
            # deduped — the `reported_token` in the state file below covers it.
            rc, out = file_issue(
                repo,
                title,
                body,
                routing_labels(STARVE_TAG),
                issue_file,
                dry_run,
            )
            if rc == 0:
                summary["starve_filed"] = 1
                reported_token = starve_signal
                log(f"starve-filed {starve_signal} -> {out}")
            else:
                log(
                    f"WARN: failed to file starve issue {starve_signal} "
                    f"(rc={rc}): {out}"
                )
        loud(
            triage,
            STARVE_LOUD_TAG,
            f"{len(starved)} signal(s) unfiled > {STARVE_TICKS} consecutive "
            f"ticks — {detail}; dedupe token {starve_signal}; cap={cap} still "
            f"in force (n_unfiled={len(capped_sigs)})",
        )
        # Keep the starve token live while the starve persists so the next
        # tick's observe-to-close pass cannot retire the issue it just filed —
        # the flapping-single-green-tick failure this detector exists to stop.
        # It leaves current_signals, and the issue is retired, when the starve
        # clears. Only the CURRENT set's token is kept alive: a superseded
        # set's issue closes as its token leaves, and the next distinct set
        # files a fresh one. Trade-off, accepted deliberately: ONE open starve
        # issue at a time, superseded by the next distinct set — two open
        # starve issues would be a flood, and the superseded one is stale by
        # definition.
        current_signals.add(starve_signal)

    if dry_run:
        log("starve-state: not written (dry-run)")
    elif not starve_state_writable_here():
        # Only reachable on the offline `FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON`
        # seam without its own `FLEET_SIGNAL_RECONCILE_STATE_DIR` (tests, and
        # `bin/chain-e2e-drill`). A log() would leave a REAL caller that sets
        # that seam green forever while starvation detection silently died,
        # so a non-dry run says it LOUD and appends it to the triage file.
        loud(
            triage,
            "SIGNAL-STARVE-STATE-SKIP",
            "starve-state NOT written: offline open-issues seam set without "
            "FLEET_SIGNAL_RECONCILE_STATE_DIR — starvation detection is "
            "inert for this run (fleet-ops#4957)",
        )
        log(
            "starve-state: not written (dry-run, or offline open-issues seam "
            "without FLEET_SIGNAL_RECONCILE_STATE_DIR)"
        )
    else:
        # `reported_token` is the CURRENT set's token on a starvation tick and
        # "" on any tick with no starved keys, so a later re-starve of the
        # same set can file again.
        write_starve_state(starve_entries, reported_token)

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
        f"closed={summary['closed']} rerouted={summary['rerouted']} capped={summary['capped']} "
        f"starved={summary['starved']} starve_filed={summary['starve_filed']}"
    )
    if args.json:
        print(json.dumps(summary, sort_keys=True))

    if summary["capped"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
