#!/usr/bin/env python3
"""Cursor keystone lane output wrapper (fleet-ops#1545).

Pi's `.ts` extensions cannot execute inside cursor-agent's runtime, so the
packet+verdict contract is ported to Cursor's native extension points: a rules
file (`~/.cursor/rules/`) imposes the prompt contract, and this wrapper is the
**output wrapper** half — the guard_pi_packet.py hook pattern applied to
cursor-agent output.

The wrapper reads one Cursor agent-transcript (JSONL, the same shape
`fleet-findings-queued` scans) and classifies the run exactly like
lib/guard_pi_packet.py classifies a pi packet log: verdict line present?,
lane fault?, suspiciously short output with no verdict?  The verdict-line
grammar and the decision logic are NOT reimplemented here — they are imported
verbatim from lib/guard_pi_packet.py (`classify_packet_text`).  This file is
only the input adapter (cursor transcript -> text), which is config, not
checker logic.  If a check cannot be ported by reuse + config, this reports
the gap rather than reimplementing it (issue framing).

Exit codes (mirrors guard_pi_packet):
  0  clean, or not a cursor transcript the wrapper can judge (no packet run)
  2  verdict/lane problem found — one-line reason on stderr
"""

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)

from guard_pi_packet import classify_packet_text  # noqa: E402

# Packet format reused from the pi lane: a run must end with a machine-checkable
# verdict line. The verdict-line grammar is the same one guard_pi_packet uses
# (RESULT|DRILL|RESTORE-WAVE|SKIP|OK) plus the PACKET-VERDICT line the packet
# extension prints.  A cursor-agent run cannot run the .ts extension, so the
# rules file instructs the agent to end every packet run with the same verdict
# line; this wrapper checks that the run did.
VERDICT_LINE = re.compile(
    r"^(?:PACKET-VERDICT|RESULT|DRILL|RESTORE-WAVE|SKIP|OK)\b", re.M
)

# A packet run claims an issue in the queue. Detect that claim marker so the
# wrapper only judges runs that were packet work (never ad-hoc prompts).
CLAIM_RE = re.compile(
    r"claim/issue-\d+"
    r"|(?:Nishfleet/\S+|github\.com/Nishfleet/\S+)#\d+"
    r"|Closes #\d+",
    re.I,
)


def transcript_texts(path: str) -> dict:
    """Extract user prompt, assistant texts, tool names, and final status from
    a Cursor agent-transcript JSONL.  Returns a dict; never raises."""
    user_texts: list[str] = []
    assistant_texts: list[str] = []
    assistant_content: list[str] = []  # text + tool names interleaved
    tools: list[str] = []
    final_status: str | None = None
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                typ = obj.get("type")
                if typ == "turn_ended":
                    final_status = obj.get("status")
                    continue
                role = obj.get("role")
                msg = obj.get("message") or {}
                content = msg.get("content") if isinstance(msg, dict) else None
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    text = ""
                    for chunk in content:
                        if not isinstance(chunk, dict):
                            continue
                        kind = chunk.get("type")
                        if kind == "text":
                            text += str(chunk.get("text") or "") + "\n"
                        elif kind == "tool_use":
                            tools.append(str(chunk.get("name") or ""))
                            assistant_content.append(f"tool:{chunk.get('name')}")
                        elif kind == "toolCall":  # Pi-style fallback
                            tools.append(str(chunk.get("name") or ""))
                            assistant_content.append(f"tool:{chunk.get('name')}")
                else:
                    continue
                if role == "user":
                    user_texts.append(text)
                elif role == "assistant":
                    assistant_texts.append(text)
                    if text:
                        assistant_content.append(text)
    except FileNotFoundError:
        return {
            "user": [], "assistant": [], "content": [],
            "tools": [], "final_status": None, "missing": True,
        }
    except Exception:
        return {
            "user": user_texts, "assistant": assistant_texts,
            "content": assistant_content, "tools": tools,
            "final_status": final_status, "missing": False,
        }
    return {
        "user": user_texts, "assistant": assistant_texts,
        "content": assistant_content, "tools": tools,
        "final_status": final_status, "missing": False,
    }


def classify_transcript(path: str) -> list[str]:
    """Run the canonical verdict/lane classification against a cursor
    transcript. All decision logic comes from guard_pi_packet.classify_packet_text."""
    data = transcript_texts(path)
    if data["missing"]:
        return ["transcript missing — cannot judge the run; do NOT report it as a clean packet"]
    # Only packet runs are judged: the queue contract requires a packet run to
    # carry its issue identity (claim/issue-<N> or Nishfleet/<repo>#<N>) in the
    # run. Interactive chats and ad-hoc Q&A with no claim marker are not packet
    # work and are not judged (fleet-ops#1545: never ad-hoc prompts).
    if not any(CLAIM_RE.search(t) for t in data["user"] + data["assistant"]):
        return []
    joined = "\n".join(data["content"])
    problems = classify_packet_text(
        joined,
        verdict_re=VERDICT_LINE,
    )
    return problems


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("transcript", nargs="?", help="Cursor agent-transcript JSONL path")
    ap.add_argument(
        "--root",
        default=os.environ.get("CURSOR_TRANSCRIPT_ROOT", os.path.expanduser("~/.cursor/projects")),
        help="Cursor projects root (default ~/.cursor/projects)",
    )
    ap.add_argument(
        "--latest",
        action="store_true",
        help="pick the most recently modified transcript under --root (packet runs land in per-project agent-transcripts)",
    )
    args = ap.parse_args(argv)

    path = args.transcript
    if not path and args.latest:
        cands: list[tuple[float, str]] = []
        for dirpath, _dirs, files in os.walk(args.root):
            for fn in files:
                if fn.endswith(".jsonl") and "agent-transcripts" in dirpath:
                    fp = os.path.join(dirpath, fn)
                    try:
                        cands.append((os.path.getmtime(fp), fp))
                    except OSError:
                        continue
        if cands:
            cands.sort(reverse=True)
            path = cands[0][1]
    if not path:
        print("guard-cursor-packet: no transcript given and --latest found none", file=sys.stderr)
        return 0
    if not os.path.isfile(path):
        print(f"guard-cursor-packet: transcript not found: {path}", file=sys.stderr)
        return 0

    problems = classify_transcript(path)
    if problems:
        print(
            "guard-cursor-packet: the cursor run at "
            + path
            + " shows: "
            + "; ".join(problems)
            + ". Do NOT report this run as dispatched/working.",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())