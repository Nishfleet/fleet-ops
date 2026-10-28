"""PRs never rot (fleet-ops#10573): what happens to one open PR that is stuck, conflicting or blocked.

agent.yml runs this file from the deploy clone (main), so a PR cannot change the rule that judges it:
its `stuck` job (the hourly sweep's stuck PRs and agent-dispatch.yml's conflicting PRs, with the App
token, so a label it adds starts the orchestrate job) and its review job's send-back step right after
a block (with the runner login, `--blocked`). Input is the environment: REPO, PR, SHA, REASON, URL.

The rules, in order:
1. Stale: a head commit 7 or more days old closes the PR with a comment and keeps the branch. Its open
   issue gets `agent-ready` again with a link to the branch; a PR with no open issue gets one filed
   from its title and body.
2. Rounds: a round is a head the reviewer blocked or this program sent back. Under 2 rounds the PR's
   issue (gh's closingIssuesReferences, so any branch name) gets `needs-orchestrator`, and the
   orchestrate job continues the PR's own head branch. At 2 or more the issue gets
   `needs-orchestrator` and `strong-only` and one comment, and is not sent back again.
3. A PR with no open issue is filed for the orchestrator as a `Stuck PR #N` issue, as before.

To switch it off, delete this file and its two calls in agent.yml; tests: tests/test_pr_rot.py.
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

STALE = timedelta(days=7)
ROUNDS = 2
PARKED = {"agent-blocked", "needs-split", "needs-orchestrator", "needs-nish-decision", "epic"}
LIVE = {"queued", "in_progress", "waiting", "pending", "requested"}
BLOCKED = re.compile(r"^reviewer: ([0-9a-f]{40}) blocked\.", re.M)
REWORK = re.compile(r"^rework: PR #(\d+) at ([0-9a-f]{7})", re.M)
RUN = re.compile(r"actions/runs/(\d+)")


def rounds(pr, sha, pr_comments, issue_comments):
    heads = {m[:7] for c in pr_comments if c.get("user", {}).get("login") == "github-actions[bot]" for m in BLOCKED.findall(c.get("body") or "")}
    heads |= {s for c in issue_comments for n, s in REWORK.findall(c.get("body") or "") if int(n) == pr}
    return len(heads | {sha[:7]})


def run_live(run, ref):
    work = [j for j in run.get("jobs") or [] if j.get("name", "").endswith("/ work")]
    mine = [j for j in work if f"({ref})" in j["name"]] or work
    return any(j.get("status") in LIVE for j in mine) if mine else run.get("status") in LIVE


def decide(pr, sha, issue, pr_comments, issue_comments, head_date, now, live=False, blocked_only=False):
    n = pr["number"]
    if pr.get("state") != "open" or pr["head"]["sha"] != sha:
        return {"do": "skip", "why": "head moved or PR closed; the newer event decides"}
    if blocked_only and not any(m == sha for c in pr_comments if c.get("user", {}).get("login") == "github-actions[bot]" for m in BLOCKED.findall(c.get("body") or "")):
        return {"do": "skip", "why": f"no block on {sha[:7]}"}
    if now - head_date >= STALE:
        return {"do": "stale", "issue": issue["number"] if issue else None}
    if issue is None:
        return {"do": "skip", "why": "no open issue; the sweep files it"} if blocked_only else {"do": "file"}
    labels = {x["name"] for x in issue.get("labels", [])}
    r = rounds(n, sha, pr_comments, issue_comments)
    if r >= ROUNDS:
        if any(f"rounds: PR #{n} " in (c.get("body") or "") for c in issue_comments):
            return {"do": "skip", "why": f"#{issue['number']} already handed to its owner"}
        return {"do": "owner", "issue": issue["number"], "rounds": r}
    if (issue.get("issue_dependencies_summary") or {}).get("blocked_by", 0) or labels & PARKED:
        return {"do": "skip", "why": f"#{issue['number']} is parked, queued or blocked; its owner has it"}
    if any((c.get("body") or "").startswith(f"rework: PR #{n} at {sha[:7]}") for c in issue_comments):
        return {"do": "skip", "why": f"#{issue['number']} already has the rework note for {sha[:7]}"}
    if live:
        return {"do": "skip", "why": f"#{issue['number']} run live"}
    return {"do": "rework", "issue": issue["number"], "rounds": r}


def gh(*args, check=True):
    p = subprocess.run(["gh", *args], capture_output=True, text=True)
    if check and p.returncode:
        sys.exit(f"gh {' '.join(args[:3])} failed: {p.stderr.strip()}")
    return p.stdout


def gh_json(*args):
    return json.loads(gh(*args) or "null")


def comments(repo, n):
    return [c for page in gh_json("api", "--paginate", "--slurp", f"repos/{repo}/issues/{n}/comments?per_page=100") for c in page]


def open_issue(repo, n):
    for ref in gh_json("pr", "view", str(n), "-R", repo, "--json", "closingIssuesReferences")["closingIssuesReferences"]:
        if f"{ref['repository']['owner']['login']}/{ref['repository']['name']}".lower() != repo.lower():
            continue
        issue = gh_json("api", f"repos/{repo}/issues/{ref['number']}")
        if issue.get("state") == "open":
            return issue
    return None


def file_stuck(repo, pr, sha, reason, url):
    n, marker = pr["number"], f"stuck-pr: #{pr['number']}"
    why = f"PR #{n} ({pr['head']['ref']}) is stuck at {sha[:7]}: {reason}." + (f" Blocking comment: {url}" if url else "")
    old = [i for i in gh_json("issue", "list", "-R", repo, "--state", "open", "-L", "100", "--search", f'"{marker}" in:body', "--json", "number,body")
           if any(line.startswith(marker + " ") for line in i["body"].split("\n"))]
    if old:
        i = old[0]["number"]
        if any(f"{marker} {sha}" in t for t in [old[0]["body"]] + [c["body"] for c in comments(repo, i)]):
            return f"#{i} already reports #{n} at {sha}"
        gh("issue", "comment", str(i), "-R", repo, "--body", f"{marker} {sha}\n\n{why}")
        return f"updated #{i} for #{n} at {sha}"
    body = (f"{marker} {sha}\n\n{why}\n\nTake the PR over: fix the blocker lines or merge main on its branch and push (a new head gets a fresh "
            f"review and the sweep arms it once approved), or close it as superseded. {pr['html_url']}")
    link = gh("issue", "create", "-R", repo, "--title", f"Stuck PR #{n}: {reason}", "--body", body).strip()
    gh("issue", "edit", link, "-R", repo, "--add-label", "needs-orchestrator")
    return f"filed {link} for #{n} at {sha}"


def act(repo, pr, sha, d, reason, url):
    n, ref = pr["number"], pr["head"]["ref"]
    tree = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/tree/{ref}"
    if d["do"] == "stale":
        i = d["issue"]
        if i is None:
            body = f"Re-filed from PR #{n}, closed after 7 days with no new commit (fleet-ops#10573). Reuse branch `{ref}`: {tree}\n\n{pr.get('body') or ''}"
            i = gh("issue", "create", "-R", repo, "--title", pr["title"], "--body", body, "--label", "agent-ready").strip().rsplit("/", 1)[-1]
        else:
            gh("issue", "edit", str(i), "-R", repo, "--add-label", "agent-ready")
            gh("issue", "edit", str(i), "-R", repo, "--remove-label", "needs-orchestrator,orchestrator-tried,agent-in-progress", check=False)
            gh("issue", "comment", str(i), "-R", repo, "--body", f"stale: PR #{n} had no new commit for 7 days and is closed. Reuse branch `{ref}`: {tree}")
        gh("pr", "close", str(n), "-R", repo, "--comment", f"stale: no new commit for 7 days, closed (fleet-ops#10573). The branch is kept; #{i} carries the work again.")
        return f"closed #{n} as stale; #{i} is agent-ready"
    if d["do"] == "file":
        return file_stuck(repo, pr, sha, reason, url)
    if d["do"] == "rework":
        gh("issue", "edit", str(d["issue"]), "-R", repo, "--add-label", "needs-orchestrator", "--remove-label", "orchestrator-tried")
        gh("issue", "comment", str(d["issue"]), "-R", repo, "--body",
           f"rework: PR #{n} at {sha[:7]}: {reason}.{' ' + url if url else ''} Round {d['rounds']} of {ROUNDS}: the orchestrator continues `{ref}`, merges main (never a rebase), fixes it and pushes.")
        return f"#{d['issue']}: rework round {d['rounds']} for #{n}"
    if d["do"] == "owner":
        gh("issue", "edit", str(d["issue"]), "-R", repo, "--add-label", "needs-orchestrator,strong-only")
        gh("issue", "comment", str(d["issue"]), "-R", repo, "--body",
           f"rounds: PR #{n} has had {d['rounds']} review or CI rounds, the limit is {ROUNDS}. Handed to its owner (strong-only); it is not sent back again. {pr['html_url']}")
        return f"#{d['issue']}: handed to its owner after {d['rounds']} rounds"
    return d["why"]


def main():
    repo, n, sha = os.environ["REPO"], int(os.environ["PR"]), os.environ["SHA"]
    blocked_only = "--blocked" in sys.argv[1:]
    reason = os.environ.get("REASON") or f"the review blocked {sha[:7]}"
    pr = gh_json("api", f"repos/{repo}/pulls/{n}")
    url = os.environ.get("URL") or (pr["html_url"] if blocked_only else "")
    if (pr["head"].get("repo") or {}).get("full_name", "").lower() != repo.lower():
        print(f"#{n} is from a fork; nothing to do")
        return
    head_date = datetime.fromisoformat(gh("api", f"repos/{repo}/commits/{sha}", "--jq", ".commit.committer.date").strip().replace("Z", "+00:00"))
    issue = open_issue(repo, n)
    issue_comments = comments(repo, issue["number"]) if issue else []
    live = False
    started = [c["body"] for c in issue_comments if (c.get("body") or "").startswith("agent run started:")]
    if started and (m := RUN.search(started[-1])):
        live = run_live(gh_json("run", "view", m.group(1), "-R", repo, "--json", "status,jobs"), pr["head"]["ref"])
    d = decide(pr, sha, issue, comments(repo, n), issue_comments, head_date, datetime.now(timezone.utc), live, blocked_only)
    print(act(repo, pr, sha, d, reason, url))


if __name__ == "__main__":
    main()
