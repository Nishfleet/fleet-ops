#!/usr/bin/env python3
# Healthchecks.io URL is operator-set via GH_WEBHOOK_HEALTHCHECKS_FAIL_URL;
# we never derive it from event data. Audit-confirmed safe (same
# suppression as lib/credential-expiry-canary.py + lib/verify-fleet-sync-pat.py).
# nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected
"""gh-webhook-canary-deadman — fleet-ops#1464 dead-man's switch.

Watches /var/lib/prometheus/node-exporter/fleet-gh-webhook-canary.prom.
If fleet_gh_webhook_canary_last_green_seconds is missing OR more than
GH_WEBHOOK_DEADMAN_STALE_AFTER seconds old, this unit:

  1. Appends a LOUD entry to the alert-repair triage file
     (default: ~/.local/state/pi-packet/alert-repair-triage.md) so the
     next repair sweep sees it.
  2. Pings the configured healthchecks.io fail URL (if any) so an
     external dead-man's switch wakes the on-call.
  3. Writes fleet_gh_webhook_canary_deadman_paged_total to the prom
     file so the alert-repair rail itself can observe the paged signal
     (counter, monotonic).

Silent when the canary is healthy.

This is the standard dead-man's switch inversion: alert on missing
success, never on present failure alone. The canary timer must fire
roughly every 5 min for the series to stay fresh.

Environment seams:

  GH_WEBHOOK_CANARY_PROM        default .../fleet-gh-webhook-canary.prom
  GH_WEBHOOK_DEADMAN_STALE_AFTER default 900 (15 min — three canary ticks)
  GH_WEBHOOK_DEADMAN_TRIAGE_FILE default ~/.local/state/pi-packet/alert-repair-triage.md
  GH_WEBHOOK_HEALTHCHECKS_FAIL_URL  optional. If empty, the deadman only
                                     pages the local alert-repair rail.
  GH_WEBHOOK_DEADMAN_DRY         1 = compute decision, write to stdout,
                                  no network/triage writes (used by tests)
  GH_WEBHOOK_RECEIVER_PROM      default .../fleet-gh-webhook-receiver.prom.
                                  If set, the deadman ALSO checks the
                                  receiver heartbeat (not just the canary).
                                  A receiver that returns HTTP 200 but writes
                                  un-scrapeable prom labels (fleet-ops#1607,
                                  single-quoted via Python repr) keeps the
                                  canary green while
                                  FleetGhWebhookReceiverAbsent stays red —
                                  the canary-only check cannot see this class.
"""
from __future__ import annotations

import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

PROM = os.environ.get(
    "GH_WEBHOOK_CANARY_PROM",
    "/var/lib/prometheus/node-exporter/fleet-gh-webhook-canary.prom",
)
STALE_AFTER = int(os.environ.get("GH_WEBHOOK_DEADMAN_STALE_AFTER", "900"))
TRIAGE_FILE = os.environ.get(
    "GH_WEBHOOK_DEADMAN_TRIAGE_FILE",
    str(Path.home() / ".local" / "state" / "pi-packet" / "alert-repair-triage.md"),
)
HEALTHCHECKS = os.environ.get("GH_WEBHOOK_HEALTHCHECKS_FAIL_URL", "")
DRY = os.environ.get("GH_WEBHOOK_DEADMAN_DRY", "") == "1"

META_RE = re.compile(r"^#.*$")
CANARY_SERIES_RE = re.compile(
    r"^fleet_gh_webhook_canary_last_green_seconds\s+(\S+)\s*$"
)
# fleet-ops#1569: also watch the receiver's own heartbeat. The canary
# POSTs to the receiver's /webhook and bumps the canary prom file — but
# a receiver that returns 200 yet writes un-scrapeable prom labels (the
# #1607 single-quote class) keeps the canary green while
# FleetGhWebhookReceiverAbsent stays firing. The canary-only check cannot
# see this class; reading the receiver prom file closes the gap.
RECEIVER_SERIES_RE = re.compile(
    r"^fleet_gh_webhook_receiver_last_green_seconds[\{\s].*"
)


def _read_ts(path: str, series_re: re.Pattern) -> float | None:
    p = Path(path)
    if not p.is_file():
        return None
    try:
        text = p.read_text()
    except OSError:
        return None
    for line in text.splitlines():
        line = META_RE.sub("", line).strip()
        m = series_re.match(line)
        if not m:
            continue
        for tok in m.group(0).split():
            try:
                return float(tok) if tok else None
            except ValueError:
                continue
    return None


def read_canary_ts(path: str) -> float | None:
    return _read_ts(path, CANARY_SERIES_RE)


RECEIVER_PROM = os.environ.get(
    "GH_WEBHOOK_RECEIVER_PROM",
    "/var/lib/prometheus/node-exporter/fleet-gh-webhook-receiver.prom",
)
RECEIVER_DEADMAN_STALE_AFTER = int(
    os.environ.get("GH_WEBHOOK_DEADMAN_STALE_AFTER", "900")
)


def already_paged_recently(triage: Path, window_sec: int = 1800) -> bool:
    """Throttle: if we already paged within ``window_sec``, do not re-page.

    Returns True when the last paged entry is recent enough that another
    page would be noise (the deadman timer still runs every 5 min, so a
    fresh page in the last 30 min means the repair rail already saw it).
    """
    if not triage.is_file():
        return False
    try:
        text = triage.read_text()
    except OSError:
        return False
    now = time.time()
    # Find the LAST '[...] gh-webhook-canary-deadman:' line's ts.
    last_ts = None
    for line in text.splitlines():
        m = re.match(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z\] gh-webhook-canary-deadman:", line)
        if m:
            try:
                dt = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(
                    tzinfo=timezone.utc
                )
                last_ts = dt.timestamp()
            except ValueError:
                continue
    if last_ts is None:
        return False
    return (now - last_ts) < window_sec


def page_local(triage_path: str, ts: float, last_green: float, status: str) -> None:
    p = Path(triage_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    iso = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ago = int(ts - last_green) if last_green > 0 else -1
    msg = (
        f"[{iso}] gh-webhook-canary-deadman: GitHub push-channel canary is "
        f"{status} (last_green_age={ago}s, stale_after={STALE_AFTER}s) "
        f"prom={PROM}. Likely causes: tunnel down, receiver service "
        f"dead, or VM unreachable. Repair rail: bring "
        f"gh-webhook-receiver.service back, then verify "
        f"gh-webhook-canary.timer is firing.\n"
    )
    if DRY:
        sys.stdout.buffer.write(b"---TRIAGE---\n")
        sys.stdout.buffer.write(msg.encode())
        return
    with p.open("a") as f:
        f.write(msg)


def page_healthchecks(url: str) -> tuple[int, str]:
    if not url:
        return 0, "(no URL configured — local-only page)"
    if DRY:
        return 0, f"(DRY=1 — would ping {url})"
    try:
        # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
        with urllib.request.urlopen(url, timeout=10) as resp:
            return resp.status, ""
    except urllib.error.HTTPError as e:
        return e.code, f"HTTP {e.code}"
    except (urllib.error.URLError, OSError) as e:
        return 0, f"network error: {e}"


def update_deadman_prom(file_path: str, total: int, last_status: str) -> None:
    """Append a deadman counter to the canary prom file."""
    try:
        text = Path(file_path).read_text() if Path(file_path).is_file() else ""
        # Strip any prior deadman block so the file stays single-source.
        text = re.sub(
            r"\n# HELP fleet_gh_webhook_canary_deadman_paged_total.*?(?=\n# |\n*$)",
            "",
            text,
            flags=re.DOTALL,
        )
        addition = (
            "\n# HELP fleet_gh_webhook_canary_deadman_paged_total "
            "Cumulative dead-man pages (local alert-repair triage write or "
            "healthchecks.io ping) the canary deadman has issued.\n"
            "# TYPE fleet_gh_webhook_canary_deadman_paged_total counter\n"
            f"fleet_gh_webhook_canary_deadman_paged_total {total}\n"
            "# HELP fleet_gh_webhook_canary_deadman_last_status "
            "Status of the most recent deadman evaluation: ok (canary fresh), "
            "stale (canary last_green older than threshold), missing "
            "(series not present at all).\n"
            "# TYPE fleet_gh_webhook_canary_deadman_last_status gauge\n"
            f"fleet_gh_webhook_canary_deadman_last_status{{status=\"{last_status}\"}} 1\n"
        )
        new = text.rstrip() + addition
        tmp = Path(file_path).with_suffix(Path(file_path).suffix + ".tmp")
        tmp.write_text(new)
        os.replace(tmp, file_path)
    except OSError as e:
        print(f"gh-webhook-canary-deadman: prom write skipped: {e}", file=sys.stderr)


def _eval_status(now: float, last_green: float | None,
                 stale_after: int) -> str:
    """Return ok / stale / missing for a single heartbeat series."""
    if last_green is None:
        return "missing"
    if (now - last_green) > stale_after:
        return "stale"
    return "ok"


def _receiver_healthy(now: float) -> tuple[bool, str]:
    """Check the receiver prom file independently of the canary.

    fleet-ops#1569 root-cause class: the receiver returns HTTP 200 but
    writes un-scrapeable prom labels (single-quoted via Python repr —
    the original #1464 bug). The canary POST will succeed and bump the
    canary prom file, but FleetGhWebhookReceiverAbsent stays firing
    because Prometheus cannot scrape the receiver's broken prom file.
    The canary-only deadman cannot see this — it must also read the
    receiver prom file.

    Returns (healthy, detail). healthy=False means the receiver heartbeat
    is missing or stale.
    """
    if not Path(RECEIVER_PROM).is_file():
        # No receiver prom file at all — this is a different failure
        # class (PROM_FILE path wrong, or the receiver never ran). Do NOT
        # treat as a deadman trigger: the canary check already covers a
        # dead receiver (the canary POST will fail). Missing receiver
        # prom is a PRE-EXISTING / deployment concern, not this deadman's
        # mandate. The canary is the authoritative liveness probe.
        return True, "receiver prom file absent (canary is authoritative)"
    last = _read_ts(RECEIVER_PROM, RECEIVER_SERIES_RE)
    if last is None:
        return True, "receiver prom file has no scrapeable heartbeat (canary is authoritative)"
    status = _eval_status(now, last, RECEIVER_DEADMAN_STALE_AFTER)
    if status != "ok":
        return False, f"receiver_last_green={last} status={status}"
    return True, f"receiver_last_green={last} ok"


def main(argv: list[str]) -> int:
    now = time.time()
    last_green = read_canary_ts(PROM)
    receiver_ok, receiver_detail = _receiver_healthy(now)
    triage = Path(TRIAGE_FILE)

    canary_status = _eval_status(now, last_green, STALE_AFTER)
    # The overall page decision considers BOTH the canary and the receiver.
    # canary_status stays an accurate reflection of the canary; receiver_ok
    # is an independent trigger (fleet-ops#1569).
    should_page = (canary_status != "ok") or (not receiver_ok)
    page_reason = canary_status if canary_status != "ok" else (
        "receiver-stale" if not receiver_ok else "ok"
    )

    if DRY:
        print(f"---DEADMAN-EVAL---")
        print(f"last_green={last_green}")
        print(f"now={now:.0f}")
        print(f"stale_after={STALE_AFTER}")
        print(f"canary_status={canary_status}")
        print(f"receiver_ok={receiver_ok} receiver_detail={receiver_detail}")
        print(f"should_page={should_page} page_reason={page_reason}")
        print(f"already_paged_recently={already_paged_recently(triage)}")
        return 0

    if not should_page:
        update_deadman_prom(PROM, total=0, last_status="ok")
        return 0

    if already_paged_recently(triage):
        update_deadman_prom(PROM, total=0, last_status=page_reason)
        return 0

    # Describe WHY we are paging — canary failure or receiver failure.
    if canary_status != "ok":
        ago = int(now - (last_green or 0)) if last_green and last_green > 0 else -1
        detail = f"canary {canary_status} (last_green_age={ago}s, stale_after={STALE_AFTER}s)"
    else:
        detail = f"receiver heartbeat stale ({receiver_detail})"
    page_reason_text = (
        f"{detail} — canary prom={PROM} "
        f"{'receiver prom=' + RECEIVER_PROM if not receiver_ok else ''}. "
        "Likely causes: tunnel down, receiver service dead, "
        "or VM unreachable. Repair rail: bring "
        "gh-webhook-receiver.service back, then verify "
        "gh-webhook-canary.timer is firing."
    )
    page_local(TRIAGE_FILE, now, last_green or 0.0, page_reason_text)
    hc_status, hc_msg = page_healthchecks(HEALTHCHECKS)
    update_deadman_prom(PROM, total=1, last_status=page_reason)

    print(
        f"gh-webhook-canary-deadman: paged (canary={canary_status}, "
        f"receiver_ok={receiver_ok}, hc_status={hc_status}, "
        f"hc_msg={hc_msg!r})",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
