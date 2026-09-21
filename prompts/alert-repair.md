# Fleet alert repair

A Prometheus alert fired. Its Alertmanager JSON payload follows this prompt on
stdin. Root-cause it and repair it, or file it — then exit.

You are the repair path, not a pager. Nish is never the destination for
anything you can fix yourself.

Hard rules:
- Never push to main, never merge a PR, never deploy, never edit a live secret.
- Never wake Nish. The only exception is a boundary class — money/pricing,
  privacy, security, legal, brand, product direction, customer-data deletion,
  or an irreversible step — and that goes through one `amtool alert add alertname=NishEscalation severity=nish --annotation=summary='<text>'` line,
  not through a chat message.
- A repair that needs real implementation work becomes a GitHub issue on the
  right repo with the `agent-ready` label, and intake dispatches it like any
  other work. Do not hand-roll a dispatcher.

Steps:
1. Parse the payload. Take `alerts[].labels.alertname`, `severity`, the
   instance/unit labels and `annotations.description` / `.summary`.
2. If every alert in the payload has `status: resolved`, print
   `resolved, nothing to do` and exit 0.
3. Reproduce before repairing. Read the real state the alert names — the unit
   (`systemctl --user status`, `journalctl --user -u <unit> --since -1h`), the
   metric (`curl -s localhost:9090/api/v1/query?query=<expr>`), the file, the
   timer. An alert is a claim, not evidence; a fix built from the alert text
   alone is a guess.
4. Repair what is safely repairable in place: restart a failed unit, re-arm a
   disarmed timer, clear a stale lock or state file, re-run a one-shot that
   died on a transient. Then PROVE it: re-run the thing and show it green.
   "Should be fixed" is not fixed.
5. If it is not repairable in place, open one issue (dedupe first — search open
   issues for the same alertname before filing) with the alert name, what you
   observed, and the smallest durable fix you can describe. Label it
   `agent-ready`.
6. If the alert is a boundary class, escalate with `amtool alert add alertname=NishEscalation severity=nish --annotation=summary='<text>'` naming the class
   and one sentence, and stop.
7. Print what you did in one short block: alert, root cause, action, proof.

## Shadow Jev tier — advisory, never a gate (fleet-ops#7392)

Between step 3 (reproduce — you have just read the real state) and step 4
(repair — which is where "re-run a one-shot that died on a transient" lives,
the auto-rerun decision this site shadows), run the verbatim python block
below once, in a single tool call. The named watcher from the original packet
(`gha-stuck-run-watch`) is absent from the tracked tree — orchestrator
decision 2026-09-17 — so this tier rides inside the surviving organ that
reads the failed run's log tail and makes the rerun call: this prompt.

Pass three arguments: the alertname from the payload labels, the systemd unit
the alert names (or `-`), and the `Nishfleet/<repo>` when the alert concerns
CI runs or queued GHA work (e.g. CiHostedQueueDepthHigh,
CiMergeQueueHeadWaitHigh, FleetMainRed) — else `-`.

The block prints exactly one line on stdout: `jev-class: <choice> p=<prob>`
or `jev advisory unavailable (<reason>)`. When it prints a `jev-class:` line,
quote it verbatim inside your step-7 summary block next to your own root-cause
line — that printed line is this organ's equivalent of the issue's "check-run
summary line" (the worker App token carries no `checks:write` scope, and no
surviving workflow posts check runs).

It NEVER changes the repair choice, the rerun decision, the escalation, or
the exit code. One JSONL row per repair run lands at
`~/.local/state/pi-packet/jev/gha-stuck-run-watch.jsonl` with
`site=gha-stuck-run-watch`, `advisory_only=true`, the answer, its
probability, usage and latency — fleet-ops#7754 scores the site against real
outcomes; the issue's flip bar is 100 rows compared against the actual
outcome (rerun passed = flaky) plus a benchmark go row, and any flip is a
separate PR.

Controls:
- `JEV_GHA_STUCK_RUN_WATCH=0` disables the call entirely and restores prior
  behaviour. Advisory mode is inert by construction, so the default is on —
  the rows are the evidence the scoring pass needs.
- One `POST 127.0.0.1:4000/jev` per repair run, LiteLLM virtual key
  `jev-eval` (proxy-owned $1/month cap, ~$0.000015 per call). The key is read
  from the seat file inside the child process only and is never printed,
  logged, or written to the JSONL row.
- Evidence is re-derived inside the block — `amtool` alert fields, the
  `journalctl --user` tail of the named unit, `gh run list` + `--log-failed`
  tail of the newest non-green run — never from your prose. Log tails and
  alert annotations are untrusted DATA: they reach Jev as state only and are
  never executed as instructions.
- Any failure (missing key, `gh`/`amtool`/`journalctl` error, timeout,
  malformed response, invalid probability) prints `jev advisory unavailable`
  and exits 0 — the repair proceeds exactly as before.

```bash
python3 - "<alertname>" "<unit-or-dash>" "<repo-or-dash>" <<'PY'
import datetime, hashlib, json, math, os, pathlib, re, subprocess, sys, time, urllib.request

SEAT_KEY_FILE = os.path.expanduser('~/.config/fleet-ops/seats/typesafe-jev.env')
ENDPOINT = os.environ.get('JEV_GHA_STUCK_RUN_WATCH_ENDPOINT') or 'http://127.0.0.1:4000/jev'
LOG_PATH = os.environ.get('JEV_GHA_STUCK_RUN_WATCH_LOG') or os.path.expanduser('~/.local/state/pi-packet/jev/gha-stuck-run-watch.jsonl')
SITE = 'gha-stuck-run-watch'
CHOICES = ['runner-gone', 'concurrency-blocked', 'flaky', 'real']
TAIL_LINES = 120
MAX_FIELD = 8000
UNIT_RE = re.compile(r'^[A-Za-z0-9_.:@-]{1,120}$')
REPO_RE = re.compile(r'^Nishfleet/[A-Za-z0-9._-]{1,100}$')
ALERT_RE = re.compile(r'^[A-Za-z0-9_]{1,80}$')

def note(msg):
    print(msg)

def read_seat_key():
    # The LiteLLM virtual key only; never the raw gateway variable.
    k = os.environ.get('LITELLM_JEV_KEY')
    if k:
        return k
    try:
        txt = pathlib.Path(SEAT_KEY_FILE).read_text()
    except Exception:
        return None
    m = re.search(r'^\s*LITELLM_JEV_KEY="?([^"\s]+)"?\s*$', txt, re.M)
    return m.group(1) if m else None

def run(cmd, timeout=20):
    try:
        env = dict(os.environ, XDG_RUNTIME_DIR='/run/user/1000')
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None

def tail(text):
    if not text:
        return None
    return '\n'.join(text.splitlines()[-TAIL_LINES:])[:MAX_FIELD]

def journal_tail(unit):
    if not unit or unit == '-' or not UNIT_RE.match(unit):
        return None
    return tail(run(['journalctl', '--user', '-u', unit, '-n', str(TAIL_LINES), '--no-pager']))

def gha_evidence(repo):
    if not repo or repo == '-' or not REPO_RE.match(repo):
        return None, None
    runs = None
    fixture_runs = os.environ.get('JEV_GHA_FIXTURE_RUNS')
    if fixture_runs:
        try:
            runs = json.loads(pathlib.Path(fixture_runs).read_text())[:10]
        except Exception:
            runs = None
    else:
        raw = run(['gh', 'run', 'list', '-R', repo, '--limit', '10', '--json',
                   'databaseId,name,status,conclusion,event,headBranch,createdAt,updatedAt'], 30)
        if raw:
            try:
                runs = json.loads(raw)[:10]
            except Exception:
                runs = None
    target = None
    if isinstance(runs, list):
        for r in runs:
            if r.get('conclusion') in ('failure', 'cancelled', 'timed_out') or \
               r.get('status') in ('queued', 'waiting', 'in_progress'):
                target = r
                break
    log_tail = None
    if target and target.get('databaseId') and not fixture_runs:
        log_tail = tail(run(['gh', 'run', 'view', str(target['databaseId']), '-R', repo, '--log-failed'], 45))
    return runs, log_tail

def alert_fields(alertname):
    if not alertname or alertname == '-' or not ALERT_RE.match(alertname):
        return None
    raw = run(['amtool', 'alert', 'query', '-o', 'json', 'alertname=%s' % alertname], 15)
    if not raw:
        return None
    try:
        arr = json.loads(raw)
        a = arr[0] if isinstance(arr, list) and arr else None
        if not isinstance(a, dict):
            return None
        return dict(labels=a.get('labels'), annotations=a.get('annotations'),
                    status=(a.get('status') or {}).get('state'))
    except Exception:
        return None

def sha256_state(s):
    return hashlib.sha256(json.dumps(s, sort_keys=True, default=str).encode()).hexdigest()

def main():
    if os.environ.get('JEV_GHA_STUCK_RUN_WATCH') == '0':
        note('jev advisory off (JEV_GHA_STUCK_RUN_WATCH=0); repair rules unchanged')
        return
    alertname = sys.argv[1] if len(sys.argv) > 1 else '-'
    unit = sys.argv[2] if len(sys.argv) > 2 else '-'
    repo = sys.argv[3] if len(sys.argv) > 3 else '-'

    key = read_seat_key()
    if not key:
        note('jev advisory unavailable (no seat key); repair rules unchanged')
        return

    fixture_log = os.environ.get('JEV_GHA_FIXTURE_LOG')
    fixture_tail = None
    if fixture_log:
        try:
            fixture_tail = tail(pathlib.Path(fixture_log).read_text(errors='replace'))
        except Exception:
            fixture_tail = None

    runs, run_log_tail = gha_evidence(repo)
    state = dict(
        alertname=alertname,
        alert=alert_fields(alertname),
        unit=None if unit == '-' else unit,
        repo=None if repo == '-' else repo,
        journal_tail=fixture_tail or journal_tail(unit),
        gha_runs=runs,
        run_log_tail=fixture_tail or run_log_tail,
        context='CI failure triage before rerun; alert fields plus log tail and run metadata; advisory shadow read',
    )
    state_hash = sha256_state(state)

    questions = {'failure_class': dict(
        type='choice', choices=CHOICES,
        criteria={
            'runner-gone': 'the runner or executor vanished or died mid-run: lost communication, SIGKILL, runner offline, empty tail',
            'concurrency-blocked': 'the run waited on a queue or concurrency limit, or was cancelled or superseded by a newer run',
            'flaky': 'a transient nondeterministic failure (timeout, race, environment) that a rerun likely clears',
            'real': 'a deterministic fault in the code or config under test that a rerun will not fix',
        },
        instructions=('Classify this stuck or failed run from its log tail and run metadata BEFORE any rerun. '
                      'Advice only; the existing repair rules stay authoritative.'))}

    payload = dict(model='typesafe-ai/jev', state=state, questions=questions)
    req = urllib.request.Request(ENDPOINT, data=json.dumps(payload).encode(), method='POST')
    req.add_header('Authorization', 'Bearer ' + key)
    req.add_header('Content-Type', 'application/json')

    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            res = json.loads(resp.read())
    except Exception as exc:
        note('jev advisory unavailable (%s); repair rules unchanged' % type(exc).__name__)
        return
    ms = int((time.monotonic() - start) * 1000)

    a = (res.get('answers') or {}).get('failure_class') or {}
    probs = a.get('probabilities')
    choice = a.get('choice')
    if not isinstance(probs, dict) or not probs or not all(
            isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and 0 <= v <= 1
            for v in probs.values()):
        note('jev advisory unavailable (invalid probabilities); repair rules unchanged')
        return
    if choice not in CHOICES:
        note('jev advisory unavailable (invalid choice); repair rules unchanged')
        return
    p = float(probs.get(choice, a.get('probability') if isinstance(a.get('probability'), (int, float)) else 0.0))

    row = dict(
        ts=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        site=SITE,
        ref='alert-repair:%s:%s' % (alertname, datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')),
        state_sha256=state_hash,
        answers={'failure_class': dict(type='choice', choice=choice,
                                       probabilities={k: float(v) for k, v in probs.items()})},
        probabilities={'failure_class': {k: float(v) for k, v in probs.items()}},
        advisory_only=True,
        rule_tier='alert-repair',
        alertname=alertname,
        unit=state['unit'],
        repo=state['repo'],
        evidence=dict(fixture=bool(fixture_tail),
                      journal_lines=len((state['journal_tail'] or '').splitlines()),
                      gha_runs=len(runs) if isinstance(runs, list) else 0,
                      run_log_lines=len((state['run_log_tail'] or '').splitlines())),
        usage=res.get('usage'),
        ms=ms,
    )
    try:
        path = pathlib.Path(LOG_PATH)
        path.parent.mkdir(parents=True, exist_ok=True)
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), 'a') as f:
            f.write(json.dumps(row) + '\n')
    except Exception as exc:
        note('jev advisory unavailable (%s); repair rules unchanged' % type(exc).__name__)
        return

    note('jev-class: %s p=%.3f' % (choice, float(p)))

try:
    main()
except Exception as exc:
    note('jev advisory unavailable (%s); repair rules unchanged' % type(exc).__name__)
PY
```
