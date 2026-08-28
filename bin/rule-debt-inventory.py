#!/usr/bin/env python3
"""Build the P1 disposition inventory for the rule-debt consolidation (fleet-ops#1537).

Joins the vault standing-rules + decisions-ledger + rule-enforcement matrix into
a single disposition table. Uses lib/rule-enforcement.py's own join output as
the authoritative id mapping, then layers the disposition analysis on top.

Output columns: kind | matrix_id | matrix_status | class | disposition | merge_target | heading

Classes (per the issue):
  binding-constraint       — live Nish-endorsed obligation that constrains action
  mechanism-exists(name)   — prose subsumed by a shipped mechanism
  duplicate-of(id)         — same obligation as another rule; merge target named
  incident-memorial        — records a past incident; lesson lives on in a mechanism
  superseded-history       — corrected/retired/superseded by a later rule
  advisory                 — senior-judged un-mechanizable, or product-direction guard

Dispositions:
  keep                     — stays in the short binding-constraints file
  collapse-into(id)        — merges into the named binding constraint
  demote-to-pointer        — one line in the short file pointing at the archive
  archive                  — moves verbatim to standing-rules-archive.md

Usage:
  rule-debt-inventory --join-json JOIN.json --matrix MATRIX.json [--json]
"""
import argparse
import json
import sys
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--join-json", required=True, help="output of: rule-enforcement.py join ...")
    ap.add_argument("--matrix", required=True)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    join = json.loads(Path(args.join_json).read_text())
    matrix = json.loads(Path(args.matrix).read_text())
    matrix_by_id = {r["id"]: r for r in matrix["rules"]}

    seen_ids = set()
    rows = []
    # covered_rows: enforced, matched to a vault rule
    for cr in join.get("covered_rows", []):
        mid = cr["id"]
        seen_ids.add(mid)
        mrow = matrix_by_id.get(mid, {})
        rows.append({
            "matrix_id": mid,
            "source": cr.get("source", mrow.get("source", "")),
            "status": cr.get("status", mrow.get("status", "")),
            "kind": "ledger" if mid.startswith("led-") else "standing",
            "mechanism": mrow.get("mechanism", "")[:120],
            "fallback_id": cr.get("fallback_id"),
        })
    # queued: matched, mechanism pending
    for q in join.get("queued", []):
        mid = q["id"]
        seen_ids.add(mid)
        mrow = matrix_by_id.get(mid, {})
        rows.append({
            "matrix_id": mid,
            "source": q.get("source", mrow.get("source", "")),
            "status": q.get("status", f"queued(#{q.get('issue')})"),
            "kind": "ledger" if mid.startswith("led-") else "standing",
            "mechanism": q.get("mechanism", mrow.get("mechanism", ""))[:120],
            "queued_issue": q.get("issue"),
            "queued_since": q.get("queued_since"),
        })
    # advisory: in the matrix but not in covered_rows or queued (the join counts
    # them separately and does not list them in covered_rows)
    for mid, mrow in matrix_by_id.items():
        if mid in seen_ids:
            continue
        if mrow.get("status", "").startswith("advisory"):
            rows.append({
                "matrix_id": mid,
                "source": mrow.get("source", ""),
                "status": mrow.get("status", ""),
                "kind": "ledger" if mid.startswith("led-") else "standing",
                "mechanism": mrow.get("mechanism", "")[:120],
            })
    # uncovered: vault rule with no matrix entry
    for u in join.get("uncovered", []):
        rows.append({
            "matrix_id": None,
            "source": u.get("source", ""),
            "status": "uncovered",
            "kind": u.get("kind", ""),
            "mechanism": "",
        })

    # Sort: standing first, then ledger, by source
    rows.sort(key=lambda r: (r["kind"] != "standing", r["source"]))

    if args.json:
        json.dump(rows, sys.stdout, indent=2)
        return

    print(f"# Rule-debt inventory (fleet-ops#1537)")
    print(f"# vault_rules={join['vault_rule_count']} matrix_rules={join['matrix_rule_count']} "
          f"covered={join['covered']} advisory={join['advisory']} queued={join['queued_ok']} "
          f"violations={join['violations']}")
    print(f"# columns: kind | matrix_id | status | source")
    print()
    for r in rows:
        mid = r["matrix_id"] or "UNCOVERED"
        src = r["source"].replace("global-standing-rules.md: ", "").replace("decisions-ledger.md: ", "")[:80]
        print(f"{r['kind'][:3]}\t{mid}\t{r['status'][:25]}\t{src}")


if __name__ == "__main__":
    main()
