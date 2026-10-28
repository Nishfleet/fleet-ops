"""The two extra reviewers of agent.yml's review job, for a head that edits the merge guard or a workflow.

agent.yml writes the reviewer input to $RUNNER_TEMP/extra-in.txt and runs this file from the deploy clone
(main), so a PR cannot change the program that reviews it. The second (GLM) and third (Qwen) reviewers run
in parallel. A family with no healthy row after the retries is replaced by the assistant seat (DeepSeek),
a family that has not reviewed this head. Success leaves <r>.txt, <r>-row and <r>-family in $RUNNER_TEMP
for r in second and third, prints the families that reviewed (judge first) and exits 0. When the retries
and the fallback run out, it files one review-retry issue, says so on the PR and exits 1.

Each call goes to the router with curl: the answering row is only in the x-litellm-model-id response
header, the key is handed to curl on stdin (never argv, #8403), and the body is a file (an argv over
128 KiB cannot start curl). To switch it off, delete this file and its call in agent.yml; tests:
tests/test_extra_reviewers.py.
"""

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

ROUTER = "127.0.0.1:4000/v1/chat/completions"
DEPLOY = "workspaces/tooling/fleet-ops-deploy-clone"


def env(name, default=""):
    return os.environ.get(name, default)


def tmp(name):
    return Path(env("RUNNER_TEMP")) / name


def family_of(row):
    """An extra reviewer may be answered by any row of its family; the family comes from the row id."""
    r = row.lower()
    if "glm" in r:
        return "GLM"
    if "qwen" in r:
        return "Qwen"
    if "deepseek" in r or "ds4" in r:
        return "DeepSeek"
    print(f"family_of: unknown row id '{row}'", file=sys.stderr)
    return ""


def ask_row(seat, pre):
    """One router call; returns curl's exit code. A failed call leaves empty body and header files."""
    home = Path(env("HOME"))
    body, headers, req = tmp(f"{pre}-body.json"), tmp(f"{pre}-headers.txt"), tmp(f"{pre}-req.json")
    try:
        system = (home / "AGENTS.md").read_text() + (home / DEPLOY / "prompts/risky-review.md").read_text()
        req.write_text(json.dumps({"model": seat, "stream": False, "max_tokens": 32768, "messages": [
            {"role": "system", "content": system}, {"role": "user", "content": tmp("extra-in.txt").read_text()}]}))
        key = ""
        for line in (home / ".config/fleet-ops/seats/typesafe-jev.env").read_text().splitlines():  # gitleaks:allow
            if line.startswith("LITELLM_JEV_KEY="):
                key = line.split("=", 1)[1]
        cfg = f'header = "Authorization: Bearer {key}"\n' if key else ""
        rc = subprocess.run(
            ["curl", "-sS", "--connect-timeout", "30", "--max-time", "480", ROUTER, "--config", "-",
             "-H", "content-type: application/json",
             "-H", f"x-litellm-session-id: {env('FLEET_TASK_ID')}-pr{env('PR')}-{pre}-{seat}",
             "-D", str(headers), "-o", str(body), "--data-binary", f"@{req}"],
            input=cfg, text=True, check=False).returncode
    except OSError as e:
        print(f"ask_row: {e}", file=sys.stderr)
        rc = 2
    if rc != 0:
        body.write_text("")
        headers.write_text("")
    return rc


def judge_answer(pre, want, used):
    """Reads one answer. Returns (content, row, family, None) for a usable review, else (None, None, None, why)."""
    try:
        b = json.loads(tmp(f"{pre}-body.json").read_text())
    except (OSError, ValueError):
        b = None
    if not isinstance(b, dict):
        return None, None, None, "the call failed or its answer was not JSON (curl exit 0)"
    ch = b.get("choices")
    choice = ch[0] if isinstance(ch, list) and ch and isinstance(ch[0], dict) else {}
    msg = choice.get("message")
    content = (msg.get("content") if isinstance(msg, dict) else "") or ""
    content = content.rstrip("\n") if isinstance(content, str) else ""
    served = ""
    try:
        for line in tmp(f"{pre}-headers.txt").read_text().splitlines():
            if line.lower().startswith("x-litellm-model-id:"):
                served = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    fam = family_of(served)
    err = b.get("error")
    rerr = (err.get("message") if isinstance(err, dict) else err) or ""
    rerr = str(rerr)[:200]
    if not fam or (want and fam != want):
        who = served or ("no row id" + (f", the router said: {rerr}" if rerr else ""))
        return None, None, None, f"answered by {who} ({fam or 'no known non-Claude family'}), not the {want or 'a'} family"
    if not want and fam in used:
        return None, None, None, f"answered by {served} ({fam}), a family that already reviewed this head"
    if choice.get("finish_reason") == "length" or not content.strip():
        return None, None, None, "the answer was cut at its token limit or empty"
    return content, served, fam, None


def seat_try(seat, pre, want, used):
    """One extra review, asked again after each REVIEW_BACKOFF delay while the failure is infrastructure.
    want is the family that must answer (empty: any not in used). Success leaves <pre>.txt, <pre>-row and
    <pre>-family and returns True; failure leaves <pre>-why and returns False."""
    for d in [0] + [int(x) for x in env("REVIEW_BACKOFF", "30 60 120 240 480").split()]:
        time.sleep(d)
        rc = ask_row(seat, pre)
        if rc != 0:
            why = f"the call failed or its answer was not JSON (curl exit {rc})"
        else:
            content, served, fam, why = judge_answer(pre, want, used)
            if why is None:
                tmp(f"{pre}.txt").write_text(content)
                tmp(f"{pre}-row").write_text(served)
                tmp(f"{pre}-family").write_text(fam)
                return True
        tmp(f"{pre}-why").write_text(why)
    return False


def gh(*args):
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=False)


def give_up(why):
    """After every retry and the fallback family: one loud issue (never a silent stall), a PR comment
    without a re-run request, and a red job."""
    repo, pr, sha = env("REPO"), env("PR"), env("SHA")
    ttl = f"review of PR #{pr} head {sha[:12]} could not finish after retries"
    found = gh("issue", "list", "-R", repo, "--label", "review-retry", "--state", "open", "--json", "number,title",
               "--jq", f"map(select(.title == {json.dumps(ttl)}))[0].number // empty")
    n = found.stdout.strip() if found.returncode == 0 else ""
    if not n:
        run = f"{env('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/actions/runs/{env('GITHUB_RUN_ID')}"
        body = (f"The risky-PR review of {repo}#{pr} at {sha} ran out of retries (backoff {env('REVIEW_BACKOFF')} s, "
                f"then another non-Claude family). Nothing was approved or blocked.\n\n{why}\n\nRun: {run}")
        made = gh("issue", "create", "-R", repo, "--label", "review-retry", "--title", ttl, "--body", body)
        n = made.stdout.strip().rsplit("/", 1)[-1] if made.returncode == 0 else ""
    filed = f"Issue #{n} is filed" if n else "The review-retry issue could not be filed"
    gh("pr", "comment", pr, "-R", repo, "--body",
       f"review of {sha} did not finish after retries: {why}. Nothing was approved or blocked. "
       f"{filed}; a new head also gets a fresh review.")
    sys.exit(1)


def main():
    seats = {"second": (env("SECOND_SEAT"), env("SECOND_FAMILY")), "third": (env("THIRD_SEAT"), env("THIRD_FAMILY"))}
    ok, crashed = dict.fromkeys(seats, False), {}

    def one(r):
        try:
            ok[r] = seat_try(seats[r][0], r, seats[r][1], [])
        except Exception as e:  # noqa: BLE001 - any crash is reported, never a silent stall
            crashed[r] = repr(e)

    threads = [threading.Thread(target=one, args=(r,)) for r in seats]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for r in seats:
        if r in crashed:
            give_up(f"reviewer process crashed: the {r} reviewer raised {crashed[r]}")
    used = [env("JUDGE_FAMILY")] + [tmp(f"{r}-family").read_text() for r in seats if ok[r]]
    for r in seats:
        if ok[r]:
            continue
        # The assistant seat is asked, because its only row is DeepSeek: the judge seat answers with Qwen
        # (order 1) while that row is healthy, and Qwen is already the third reviewer.
        if not seat_try("assistant", r, "", used):
            last = tmp(f"{r}-why").read_text() if tmp(f"{r}-why").exists() else "the review process died"
            give_up(f"the {r} reviewer and the fallback family both failed; the last reason: {last}")
        used.append(tmp(f"{r}-family").read_text())
    print(" ".join(used))


if __name__ == "__main__":
    main()
