# Orchestrate Sonnet vs Opus — the 10-task A/B, measured on the surviving batch

Superseded on model choice by fleet-ops#10750: the worker and orchestrate paths
run Sonnet only, and Opus, Fable and Qwen are reviewer and judge models. The
measurement below stands as measured; only its operational decision is over.

For fleet-ops#9376. Every number below was read off the transcripts of the
20-run dry-run batch that ran on 2026-10-07, with the commands printed under
each table. No new sub-runs were made for this measurement: issue #9376's own
rule 3a (from #9440) bans a fresh two-model batch, so the batch that already
ran is the data set.

## 1. What was measured

The 2026-10-07 batch ran 10 real hand-off tasks (fleet-ops issues 9214, 9219,
9253, 9268, 9269, 9274, 9315, 9317, 9325, 9340) twice: once on
`claude-sonnet-5-5`, once on `claude-opus-5-5`. Each run got the same starting
commit (the parent of that issue's delivery-PR merge commit), the same packet
(`prompts/orchestrator-handoff.md` plus the issue and its trusted comments),
the same flags (`--output-format json`, `--permission-mode bypassPermissions`,
`--max-turns 80`, 2700 s wall), and no GitHub access: read, build, run the
offline checks, commit locally, print the PR body it would post.

The worktrees under `/tmp/ab9376` are gone, but all 20 session transcripts
survive under `~/.claude/projects/-tmp-ab9376-runs-<issue>-<arm>-repo/`.

## 2. How the numbers were taken

Each transcript's `cost-state` entries carry the exact `--output-format json`
accounting: `totalCostUSD`, `totalAPIDuration`, and `modelUsage` per model.
`modelUsage` matters here: in the Opus arm, the Opus session delegated the
build to `helper` subagents, and those subagent runs show up as Sonnet tokens
inside the Opus session's own usage block, exactly as they do in production.
Turns are unique assistant message ids. The per-run commands:

```
python3 - <<'EOF'
import json, glob, os, re, datetime
for d in sorted(glob.glob(os.path.expanduser('~/.claude/projects/-tmp-ab9376-runs-*-repo'))):
    cost = None; ids = set(); first = last = None
    for f in glob.glob(os.path.join(d, '*.jsonl')):
        for line in open(f):
            e = json.loads(line)
            if e.get('type') == 'cost-state': cost = e
            if e.get('type') == 'assistant':
                m = e.get('message') or {}
                if m.get('id'): ids.add(m['id'])
                ts = e.get('timestamp')
                first = ts if first is None or ts < first else first
                last = ts if last is None or ts > last else last
    p = '%Y-%m-%dT%H:%M:%S.%fZ'
    dur = (datetime.datetime.strptime(last, p) - datetime.datetime.strptime(first, p)).total_seconds()
    print(os.path.basename(d), len(ids), cost['totalCostUSD'], round(dur))
EOF
```

## 3. The table

`better` is the blind grader's winner for that pair (section 4). Costs are
US dollars from each run's own `cost-state`.

| issue | arm | turns | cost | minutes | outcome | graded (A/V/C) | better |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 9214 | sonnet | 14 | 0.439 | 6.4 | committed fix, pushed nothing (dry run) | 8/7/8 | opus |
| 9214 | opus | 5 | 0.830 | 7.9 | committed fix via one helper subagent | 9/9/9 | opus |
| 9219 | sonnet | 6 | 0.261 | 0.4 | no change needed, verified the seat works | 8/8/8 | opus |
| 9219 | opus | 3 | 0.480 | 1.0 | no change needed, verified via helper | 9/9/9 | opus |
| 9253 | sonnet | 9 | 0.340 | 0.7 | committed fix | 7/6/7 | opus |
| 9253 | opus | 4 | 0.850 | 4.6 | committed fix with CI gate via helper | 9/9/9 | opus |
| 9268 | sonnet | 7 | 0.308 | 0.7 | committed fix | 8/7/9 | tie |
| 9268 | opus | 5 | 0.652 | 1.3 | committed fix via helper | 8/8/9 | tie |
| 9269 | sonnet | 11 | 0.379 | 7.1 | committed fix | 8/7/8 | opus |
| 9269 | opus | 14 | 0.815 | 11.1 | committed fix with stub test | 8/9/7 | opus |
| 9274 | sonnet | 21 | 0.683 | 7.9 | committed fix, CI gate, negative test | 9/8/9 | sonnet |
| 9274 | opus | 6 | 1.008 | 5.9 | helper built it, session never posted a PR body | 6/7/7 | sonnet |
| 9315 | sonnet | 9 | 0.355 | 4.5 | committed fix | 7/7/8 | sonnet |
| 9315 | opus | 16 | 1.532 | 45.0 | ended at the 2700 s wall mid-investigation | 2/4/5 | sonnet |
| 9317 | sonnet | 12 | 0.401 | 1.1 | docs-only change, missing live-session proof | 5/6/7 | opus |
| 9317 | opus | 8 | 0.909 | 3.0 | committed monitoring check with negative tests | 7/8/8 | opus |
| 9325 | sonnet | 14 | 0.424 | 4.1 | committed fix | 9/8/9 | opus |
| 9325 | opus | 4 | 0.733 | 11.0 | committed fix via helper, noted PR 9333 | 9/8/9 | opus |
| 9340 | sonnet | 24 | 0.707 | 4.9 | committed fix, test, CI step | 9/8/9 | opus |
| 9340 | opus | 4 | 0.954 | 15.7 | committed fix via helper, bare-read fixes too | 9/9/9 | opus |

Totals over the 10 tasks:

| arm | turns | cost | minutes | wins |
| --- | --- | --- | --- | --- |
| sonnet | 127 | 4.297 | 37.7 | 2 (9274, 9315) |
| opus | 69 | 8.764 | 106.6 | 7 (9214, 9219, 9253, 9269, 9317, 9325, 9340) |

One tie (9268). Sonnet is the cheaper arm on every single pair: it spends more
turns (127 vs 69) but about half the money, because the Opus arm pays Opus
prices for the orchestrating session on top of the Sonnet-priced helper work.

## 4. The grading

Each pair was graded blind by the non-Claude judge row issue #9374 made
primary: the LiteLLM judge group's Alibaba `qwen3.8-max` row, called through
`pi --print --provider xkiro --model qwen/qwen3.8-max:free --no-tools`. The
grader saw the issue's text (body plus trusted comments) and both runs'
artifacts: the final report each run printed, plus, for the Opus arm, the
`[Subagent hand-back]` reports the harness injected for its helpers, and, for
the Sonnet arm, the scripts it used to edit the repo. Model names were hidden
and the arm shown as "Run A" alternated across pairs. Scores are
acceptance / verification / correctness, 0-10 each.

Two extraction bugs were found and corrected before these grades were kept,
because both would have biased the result toward Sonnet:

1. The first pass read only the parent session's own tool calls. The Opus
   arm's builds live inside its helper subagents, whose reports are injected
   into the transcript as `tool_result` payloads, so seven Opus runs first
   looked like they had produced nothing at all.
2. The Sonnet arm often edited files through `python3 - <<'EOF'` heredocs,
   which a file-write scan over `Edit`/`Write`/`sed` does not see.

Both fixes were applied to every pair before the table above was built. 20
grader calls were spent in total (10 discarded, 10 kept). Re-read rule: no pair
was graded twice for confidence; each pair has exactly one kept grade.

## 5. The decision

Issue #9376's rule: switch only if Sonnet wins or ties on at least 9 of 10
pairs and has no failure the Opus run does not.

**Keep Opus on `needs-opus` only. Do not move the remaining Opus orchestrate
work to Sonnet.**

- Sonnet wins or ties 3 of 10 pairs (9274, 9315, 9268). The bar is 9.
- Opus has two real failures in this batch: 9274 and 9315 delegated the build
  and never signed off, and 9315 burned the full 2700 s wall. That is 2 of 10
  incomplete Opus runs against a Sonnet arm that delivered on all 10. Even so,
  Sonnet loses 7 pairs outright, so the "equal quality" condition fails before
  the failure comparison is even needed.
- The saving is real but smaller than the audit's estimate: $4.47 over these
  10 tasks, on sessions that cost $8.76. The `needs-opus` lane only catches
  workflow-path issues and twice-failed packets, so in production the exposed
  spend is a fraction of the batch's.

Operationally nothing changes: workflow-path hand-offs stay on Opus with 80
turns (agent.yml labels them `needs-opus`; agent-dispatch.yml leaves the
session model empty for that label), Sonnet stays the default for every other
hand-off, and `ORCHESTRATE_MODEL` stays unset so the Sonnet default holds.

## 6. Re-reading this

The transcripts and the exact per-run extraction commands are in section 2.
The blind grading packets are reproducible from the transcripts with the two
evidence rules in section 4: a run's artifact is its final report plus its
helper hand-backs plus its file-mutating commands, never just the tool calls
its own session made.
