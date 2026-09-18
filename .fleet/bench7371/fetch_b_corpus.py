#!/usr/bin/env python3
"""Benchmark B corpus acquisition for fleet-ops#7371 (decision-resolved 2026-09-17).

Corpus: closed issues in Nishfleet/fleet-ops + Nishfleet/0509 that at ANY time
carried nish-reserved / question / escalate-senior / needs-orchestrator
(newest first, up to 200), plus 100 random closed controls with none of those
label events. Candidate discovery = current-label search (the label events then
verified per issue) PLUS a decision-resolved/blocked-on text search that
recovers historically-labelled issues whose label was later removed.

Per issue we capture: title, body, state, labels now, label events (labeled/
unlabeled history), comments (author + body + created), and whether closure was
by a merged PR. Pre-decision text = title + body + comments BEFORE the first
nish3451 comment or the first comment containing decision-resolved:.
"""
import json, random, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

OUT = Path(".fleet/bench7371")
REPOS = ["Nishfleet/fleet-ops", "Nishfleet/0509"]
EVENT_LABELS = ["nish-reserved", "question", "escalate-senior", "needs-orchestrator"]
N_LABELLED, N_CONTROLS = 200, 100

def gh(args, retries=3):
    for i in range(retries):
        r = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
        if r.returncode == 0:
            return r.stdout
        err = r.stderr.strip()[:200]
        if "rate limit" in err.lower():
            time.sleep(60); continue
        time.sleep(2 + 3 * i)
    print(f"GH FAIL {args[:3]}: {err}", file=sys.stderr)
    return None

def search(q, n=200):
    out, page = [], 1
    while len(out) < n:
        o = gh(["-X", "GET", "search/issues", "-f", f"q={q}", "-f", "sort=created",
                "-f", "order=desc", "-f", "per_page=100", "-f", f"page={page}",
                "--jq", "{repo: .items[].repository_url, items: [.items[] | {number, title, closed_at}]}"])
        if o is None: break
        d = json.loads(o)
        items = [{"repo": it["repo"].split("repos/")[-1], **it} for it in
                 (d["items"] if isinstance(d, dict) else [])] if False else None
        break
    return out

# simpler: plain search returning items with repo
def search2(q):
    rows, page = [], 1
    while page <= 3:
        o = gh(["-X", "GET", "search/issues", "-f", f"q={q}", "-f", "sort=created",
                "-f", "order=desc", "-f", "per_page=100", "-f", f"page={page}"])
        if o is None: return rows
        try: d = json.loads(o)
        except json.JSONDecodeError: return rows
        items = d.get("items", [])
        rows += [{"repo": it["repository_url"].split("repos/")[-1], "number": it["number"],
                  "title": it["title"], "closed_at": it.get("closed_at")} for it in items]
        if len(items) < 100: break
        page += 1
    return rows

cands = {}
for repo in REPOS:
    for lab in EVENT_LABELS:
        for it in search2(f"repo:{repo} is:issue is:closed label:{lab!r}"):
            it["why"] = f"current-label:{lab}"
            cands[(it["repo"], it["number"])] = it
    # historical recovery: issues whose comments include a decision-resolved or blocked-on marker
    for marker in ("decision-resolved", "blocked-on"):
        for it in search2(f"repo:{repo} is:issue is:closed {marker} in:comments"):
            key = (it["repo"], it["number"])
            if key not in cands:
                it["why"] = f"text-marker:{marker}"
                cands[key] = it
print("candidate issues:", len(cands), flush=True)

def fetch(key):
    repo, num = key
    c = cands[key]
    d = {"repo": repo, "number": num, "title": c["title"], "why": c["why"]}
    o = gh([f"repos/{repo}/issues/{num}", "--jq",
            "{title, body, state, closed_at, labels: [.labels[].name], user: .user.login, is_pr: (.pull_request != null)}"])
    if o is None: return None
    meta = json.loads(o)
    if meta["state"] != "closed" or meta["is_pr"]:
        return None
    d.update(meta); d["body"] = (meta.get("body") or "")[:20000]
    ev = gh([f"repos/{repo}/issues/{num}/events", "--paginate", "--jq",
             '.[] | select(.event=="labeled" or .event=="unlabeled") | {event, label: .label.name, actor: .actor.login, created_at}'])
    d["label_events"] = [json.loads(l) for l in ev.splitlines() if l.strip()] if ev else []
    cm = gh([f"repos/{repo}/issues/{num}/comments", "--paginate", "--jq",
             '.[] | {user: .user.login, body: .body, created_at}'])
    comments = []
    if cm:
        for l in cm.splitlines():
            if l.strip():
                try: comments.append(json.loads(l))
                except json.JSONDecodeError: pass
    for c2 in comments: c2["body"] = (c2.get("body") or "")[:20000]
    d["comments"] = comments
    # closed by merged PR?
    o2 = gh([f"repos/{repo}/issues/{num}/timeline", "--paginate", "--jq",
             '.[] | select(.event=="cross-referenced" or .event=="closed" or .event=="connected") | {event, source: (.source.issue.number // null), source_is_pr: ((.source.issue.pull_request // null) != null), commit: (.commit_id // null)}'])
    d["timeline"] = [json.loads(l) for l in o2.splitlines() if l.strip()] if o2 else []
    return d

keys = list(cands)
fetched = []
with ThreadPoolExecutor(max_workers=4) as ex:
    for i, d in enumerate(ex.map(fetch, keys)):
        if d: fetched.append(d)
        if (i + 1) % 50 == 0: print(f"fetched {i+1}/{len(keys)}", flush=True)

def ever(d):
    return {e["label"] for e in d["label_events"] if e["event"] == "labeled" and e["label"] in EVENT_LABELS}

labelled = [d for d in fetched if ever(d)]
labelled.sort(key=lambda d: (d.get("closed_at") or ""), reverse=True)
labelled = labelled[:N_LABELLED]

# controls: closed issues with none of those label events, random 100
import hashlib
pool = [d for d in fetched if not ever(d)]
rnd = random.Random(20260917)
controls = rnd.sample(pool, min(N_CONTROLS, len(pool)))
for d in controls: d["control"] = True
for d in labelled: d["control"] = False

corpus = labelled + controls
print(f"labelled-with-event: {len(labelled)}  controls: {len(controls)}  corpus: {len(corpus)}")
json.dump(corpus, open(OUT / "b-corpus.json", "w"))
print("wrote", OUT / "b-corpus.json")
