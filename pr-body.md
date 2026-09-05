Trim `prompts/worker.md` from 271 lines / ~32 KB to 36 lines (well under the
<= 80-line ceiling, fleet-ops#3245, child of #3120).

Kept the essential contract:
- identity + token note (5 lines)
- hard rules (never close/merge/push main, no attribution, stay in scope, flag failed commands in one sentence)
- workspace steps
- Execution-IS-the-review inner loop
- PR body contract (Verification / run-proof / research / help-first, one line each)
- auto-merge arm
- final line = PR URL
- the two single-session-waste lines: (1) todo-list pacing via the loaded todo extension, one item per acceptance bullet, stop-at-10-min; (2) the bar is 'extremely well', never 'perfect'.

The D1/gate-integrity and GEO/AEO blocks are no longer inline; they ship as
conditional fragments via fleet-ops#3247's intake assembly.

Mechanism (fleet-ops#366): `tests/worker-prompt-size-ceiling.test.sh` now asserts
worker.md stays <= 80 lines (new assertion), so the trim cannot re-bloat past
the ceiling.

Verification: ran `bash tests/worker-prompt-size-ceiling.test.sh` -> all OK
(worker.md is 36 lines, under 80-line ceiling; 6107B packet under 12288B/32768B;
per-line cap ok). Ran `bash tests/worker-packet-size.test.sh` -> PASS (live
6107B non-0509 / 6095B 0509). Ran `bash tests/worker-prompt-systemd-run.test.sh`
and `bash tests/pstack-worker-prompt.test.sh` -> both PASS (worker.md still names
pi-systemd-run and pstack playbooks).

run-proof: transcript above (worker-prompt-size-ceiling: PASS, exit 0).

net-positive-because: 235 lines and ~26 KB of prompt context removed from every
worker packet; fewer tokens per packet, fewer context-pressure hangs, and a
mechanical re-bloat guard.

Closes #3245
