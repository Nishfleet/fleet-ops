fix(prompts): trim bloated 22KB failed-command line in worker.md (fleet-ops#1902)

pi-issue-run empty runs (stdout=0B, exit 0, tools=0) were benching healthy
seats 18x/2h. Root cause: the worker prompt had bloated to ~45KB with a
single 22KB line — the failed-command shape enumeration redundant with the
20+ `tests/fleet-failed-command-*.test.sh` files and the
`bin/fleet-failed-command-flagged` session-close lint. Free-tier seats with
limited context windows returned empty completions on the oversized packet,
so `pi-issue-run` benched healthy seats for an apparent transient provider
hiccup.

Trim the enumeration to the core rule (1.8KB): flag failed commands in
user-facing text, every `toolResult` shape family, the no-match-probe
exception, and a pointer to the authoritative test files + lint. The
assembled packet drops from 44.8KB to 24.5KB (45% reduction) and the
longest line from 22KB to 1.8KB.

Mechanism (fleet-ops#366): `tests/worker-prompt-size-ceiling.test.sh`
asserts the assembled worker packet stays under 32KB and no single line
exceeds 4KB, preventing re-bloat. Registered in `ci.yml`.

## Verification

```
bash tests/worker-prompt-size-ceiling.test.sh  # PASS
```

run-proof: `bash tests/worker-prompt-size-ceiling.test.sh` passes with
packet size 24650B under 32768B ceiling, longest line 1841B under 4096B
cap, and core failed-command rule + no-match-probe + lint pointer all
present.

Closes #1902
