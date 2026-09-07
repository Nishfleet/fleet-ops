#!/usr/bin/env python3
"""Cursor sessionEnd hook -> cursor keystone lane packet guard (fleet-ops#1545).

Cursor's native extension-point parallel of the Claude PostToolUse hook that
runs `guard_pi_packet.py`. Installed as a user hook via ~/.cursor/hooks.json:

    {"version":1,"hooks":{"sessionEnd":[{"command":"python3 ./hooks/guard_cursor_packet.py"}]}}

The sessionEnd hook event may receive a JSON payload on stdin. This shim
ignores the payload envelope and checks the most recent Cursor
agent-transcript under the projects root, reusing the canonical
verdict/lane classification from lib/guard_pi_packet.py via
lib/guard_cursor_packet.py (no new checker logic).

Exit codes (mirror guard_pi_packet):
  0  clean session, or nothing to judge
  2  verdict/lane problem found in the latest cursor run — one-line reason on
     stderr, and (when FLEET_HEARTBEAT_TRIAGE is set) a LOUD line appended so
     the heartbeat can see the empty run.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

from guard_cursor_packet import classify_transcript  # noqa: E402


def _payload_conversation() -> str | None:
    """sessionEnd payloads carry conversation_id; probe it if present."""
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return None
        data = json.loads(raw)
        cid = data.get("conversation_id") or data.get("conversationId")
        return str(cid) if cid else None
    except Exception:
        return None


def main() -> int:
    root = os.environ.get(
        "CURSOR_TRANSCRIPT_ROOT", os.path.expanduser("~/.cursor/projects")
    )
    cid = _payload_conversation()

    # Prefer the transcript that matches the conversation that just ended.
    path = None
    if cid:
        for dirpath, _dirs, files in os.walk(root):
            for fn in files:
                if fn.endswith(".jsonl") and cid in dirpath:
                    candidate = os.path.join(dirpath, fn)
                    if path is None or os.path.getmtime(candidate) > os.path.getmtime(path):
                        path = candidate
    if path is None:
        # No payload/conversation id: judge the most recent run under the root.
        best = None
        best_mtime = -1
        for dirpath, _dirs, files in os.walk(root):
            for fn in files:
                if fn.endswith(".jsonl") and "agent-transcripts" in dirpath:
                    candidate = os.path.join(dirpath, fn)
                    try:
                        mtime = os.path.getmtime(candidate)
                    except OSError:
                        continue
                    if mtime > best_mtime:
                        best, best_mtime = candidate, mtime
        path = best

    if not path:
        return 0

    problems = classify_transcript(path)
    if problems:
        reason = (
            "guard-cursor-packet: cursor run at "
            + path
            + " shows: "
            + "; ".join(problems)
            + ". Do NOT report this run as dispatched/working."
        )
        print(reason, file=sys.stderr)
        triage = os.environ.get("FLEET_HEARTBEAT_TRIAGE", "")
        if triage:
            try:
                with open(triage, "a") as f:
                    f.write(
                        f"\n[{__import__('time').strftime('%Y-%m-%dT%H:%M:%SZ', __import__('time').gmtime())}] "
                        f"[CURSOR-PACKET-VERDICT] {reason}\n"
                    )
            except OSError:
                pass
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())