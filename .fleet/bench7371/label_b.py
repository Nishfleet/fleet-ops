#!/usr/bin/env python3
"""Benchmark B blind labelling + Jev replay for fleet-ops#7371 (decision-resolved 2026-09-17).

Corpus: .fleet/bench7371/b-corpus.json (200 labelled-by-event + 100 controls).
Truth rules (from the decision-resolved text, applied MECHANICALLY, blind to Jev):
  reserved := a `nish-reserved` label EVENT, OR a comment by nish3451 that resolves it
             (first nish3451 comment OR decision-resolved: marker), OR a
             decisions-ledger citation (vault).
  auto_fixable := closed by a merged PR with none of the reserved label events.
Pre-decision text = title + body + comments BEFORE the first nish3451 comment or
the first comment containing `decision-resolved:`.

Labels are produced BEFORE any Jev call (the JSONL here is written label-first).
Output: .fleet/bench7371/b-labels.jsonl  one row per corpus item:
  {repo, number, control, truth_reserved, reserved_class, truth_auto_fixable,
   pre_text, pre_text_sha256, label_events, closed_by_pr}
"""
import json, hashlib, re
from pathlib import Path

OUT = Path(".fleet/bench7371")
CORPUS = OUT / "b-corpus.json"
OUTFILE = OUT / "b-labels.jsonl"

CANONICAL_CLASSES = [
    "money/pricing", "privacy", "security", "legal", "brand", "product direction",
    "customer-data deletion", "destructive/irreversible steps",
    "authority Nish explicitly reserved", "auto_fixable",
]

LEDGER_PATH = Path.home() / "workspaces/tooling/nish-vault/_system/shared-memory/findings-ledger.jsonl"

def load_ledger_citations():
    cites = set()
    if not LEDGER_PATH.exists():
        return cites
    text = LEDGER_PATH.read_text(errors="replace")
    for m in re.finditer(r"(?:fleet-ops|0509)?#(\d+)", text):
        cites.add(int(m.group(1)))
    return cites


classify_placeholder = None

ledger_cites = load_ledger_citations()
print(f"decisions-ledger citation ids loaded: {len(ledger_cites)}" if ledger_cites else "ledger not readable -> no ledger truth signal", flush=True)

def truth_row(d):
    events = [e for e in d.get("label_events", []) if e.get("event") == "labeled"]
    labels_ever = {e["label"] for e in events}
    comments = d.get("comments", [])
    first_nish = None
    resolved_idx = None
    for i, cm in enumerate(comments):
        if first_nish is None and (d.get("user") == "nish3451" or False):
            pass
        if d.get("user") == "nish3451" and i == 0:
            first_nish = i
        if comments[i].get("user") == "nish3451" and first_nish is None:
            first_nish = i
        if "decision-resolved" in (comments[i].get("body") or "") and resolved_idx is None:
            resolved_idx = i
    cut = min([x for x in (first_nish, resolved_idx) if x is not None], default=len(comments))
    pre = [(c.get("user"), (c.get("body") or "")) for c in comments[:cut]]
    body = d.get("body") or ""
    pre_text = (d.get("title") or "") + "\n" + body + "\n" + "\n".join(
        f"@{u}: {b}" for u, b in pre)
    # truth: reserved if nish-reserved event, or a nish3451 comment, or decision-resolved
    # marker, or a decisions-ledger citation of this issue (vault, mechanical join)
    nish_commented = has_nish_comment(comments)
    resolved_marker = any("decision-resolved" in (c.get("body") or "") for c in comments)
    ledger_cited = d["number"] in ledger_cites
    reserved = ("nish-reserved" in labels_ever) or nish_commented or resolved_marker or ledger_cited
    reserved_class = classify_reserved(pre_text) if reserved else "auto_fixable"
    # auto_fixable := closed by a merged PR with none of the reserved events
    closed_by_merged_pr = any(t.get("source_is_pr") for t in d.get("timeline", []) if t.get("event") == "cross-referenced")
    auto_fixable = (not reserved) and closed_by_merged_pr
    return {
        "repo": d["repo"], "number": d["number"], "control": d.get("control", False),
        "truth_reserved": bool(reserved),
        "reserved_class": reserved_class,
        "truth_auto_fixable": bool(auto_fixable),
        "closed_by_merged_pr": bool(closed_by_merged_pr),
        "labels_ever": sorted(labels_ever & {"nish-reserved", "question", "escalate-senior", "needs-orchestrator"}),
        "nish_comment": nish_commented, "resolved_marker": resolved_marker,
        "ledger_cited": bool(ledger_cited),
        "pre_text": pre_text[:6000],
        "pre_text_sha256": hashlib.sha256(pre_text.encode()).hexdigest()[:16],
    }

def has_nish_comment(comments):
    return any(c.get("user") == "nish3451" for c in comments)

classify_reserved_unused = None  # (kept single definition of classify_reserved above)

def classify_reserved(pre_text):
    """Assign the reserved class by the canonical list, blind, keyword-first."""
    t = pre_text.lower()
    if any(k in t for k in ("pricing", "price", "payment wall", "paid", "spend cap", "$", "budget", "money", "upgrade", "revenue")):
        return "money/pricing"
    if any(k in t for k in ("privacy", "gdpr", "personal data", "pii")):
        return "privacy"
    if any(k in t for k in ("secret", "credential", "token leak", "security", "vulnerab", "exploit", "auth bypass")):
        return "security"
    if any(k in t for k in ("legal", "license", "gdpr-violation", "trademark", "copyright", "dmca", "terms")):
        return "legal"
    if any(k in t for k in ("brand", "name change", "domain", "logo", "public-facing tone")):
        return "brand"
    if any(k in t for k in ("customer data", "delete data", "data deletion", "purge user")):
        return "customer-data deletion"
    if any(k in t for k in ("irreversible", "destructive", "rm -rf", "drop table", "prod migration", "production d1")):
        return "destructive/irreversible steps"
    if any(k in t for k in ("direction", "roadmap", "which product", "priorit", "scope of the product", "positioning")):
        return "product direction"
    return "authority Nish explicitly reserved"

rows = []
for d in json.load(open(CORPUS)):
    rows.append(truth_row(d))
with open(OUTFILE, "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
print(f"labelled rows: {len(rows)}")
tr = sum(1 for r in rows if r["truth_reserved"])
af = sum(1 for r in rows if r["truth_auto_fixable"])
print(f"truth reserved: {tr}  auto_fixable: {af}  neither/other: {len(rows)-tr-af}")
from collections import Counter
print("reserved classes:", dict(Counter(r["reserved_class"] for r in rows if r["truth_reserved"])))