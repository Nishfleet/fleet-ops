#!/usr/bin/env python3
"""Session-close lint for 'a failed command is ALWAYS flagged'
(fleet-ops#535).

The standing rule's failure mode is a swallowed non-zero: a Pi toolResult
with isError / 'Command exited with code N' / timeout, and no later
assistant text that names the failure. Burying it in the tool result the
user may not read does not count.

The auto-file path lives in bin/fleet-failed-command-flagged. The bin
dedupes against the open issue list (live #951 / #1021) AND, since
fleet-ops#1071, against a local ledger at
$FLEET_FAILED_COMMAND_LEDGER (default
/var/tmp/fleet-failed-command-flagged.filed). The ledger is consulted
as a last-resort dedup after the open-list and closed-search dedups
have run: when `gh issue list` returns [] because of a 401 / 5xx /
network blip, the open-list dedup falls through and would otherwise
file 5-7 duplicates per slug across consecutive heartbeat ticks (live
#1071: 5-7 duplicates per slug on 2026-08-27T05:10-05:14Z). The ledger
survives gh outages and is pruned when the slug stops being a finding.
The ledger dedup is locked under
tests/fleet-failed-command-ledger-dedup.test.sh; cross-check that the
test stays in tests/seat-lib.test.sh so it runs on CI.

grep/rg/diff exit 1 (POSIX no-match) is not a failure. `xargs grep/rg/diff`
exit 123 is the same no-match class: xargs exits 123 when an invoked
command exits 1-125, and for grep/rg/diff exit 1 is no-match (live #942).
ls no-match
(exit 2, the canonical "ls: cannot access '<path>': No such file or
directory" line) and which no-match (exit 1) are also treated as probes.
ls exit 2 with any other error (Permission denied, I/O error, Is a
directory, etc.) is a real failure. `git log|rev-parse|show|diff|cat-file
<bad-ref>` exit 128 (the canonical "fatal: ambiguous argument '<ref>'"
or "fatal: bad revision '<ref>'" line) is a deliberate existence probe
and is also treated as a probe. Other `fatal:` lines (not a git
repository, unable to access, repository not found, bad object, etc.)
remain real failures. Exit >= 2 (other than the canonical ls / git
probes), timeouts, and non-probe exit 1 (the 404 origin case) are. A
`read` tool returning ENOENT / EACCES / EISDIR (fleet-ops#651, #664, #953,
fleet-ops#958, #972, #967, #977, #1001, #1059, #1100, #1170, #1243, #1255) is a
real swallowed failure: it is not a probe like ls no-match or read
offset beyond end. The EISDIR class (#1170 / #1243) is the `read` tool pointed at
a directory path instead of a file — Pi returns `EISDIR: illegal operation
on a directory, read` with isError=True and no exit-code line, and the
assistant walked it past with thinking-only recovery turns; it is a
real failure, never a negative result like the #651 offset-beyond-end
exemption. The dedicated regression test
tests/fleet-failed-command-read-eisdir.test.sh pins the live
fleet-ops#1170 shape (01a04334 reading the sessions dir) and the
fleet-ops#1243 sibling on a DIFFERENT session slug (01a043ee reading
the 0509 e2e/fixtures dir, walked past with "Now let me also look at
the printStackTrace threshold setting you mentioned:") so a future
refactor that adds a "directory read is benign" exemption is caught. #972 is the same session shape as #958 (the
01a03e61 read-ENOENT session); it is a leftover open duplicate filed by
the same GitHub-search-index-delay that produced #951 / #965 / #966, so
the citation chain must carry it. #967 is the same session shape as
#958 / #972 (the 01a03e61 read-ENOENT session); it is a leftover open
duplicate filed by the same GitHub-search-index-delay that produced
#951 / #965 / #966, so the citation chain must carry it. #977 is the
same session shape as #958 / #972 / #967 (the 01a03e61 read-ENOENT
session); it is a leftover open duplicate filed by the same
GitHub-search-index-delay that produced #951 / #965 / #966, so the
citation chain must carry it. #1001 is the same read-ENOENT shape as
#958 / #972 / #967 / #977 but on a DIFFERENT session slug (the
01a041a4 completion-canary build session, where the worker read
`/home/nish/workspaces/fleet-ops-sync/bin/fleet-escalation-canary` —
a stale, non-canonical checkout that does not carry the file —
instead of the canonical
`/home/nish/workspaces/tooling/fleet-ops-deploy-clone/bin/fleet-escalation-canary`,
got the live `ENOENT: no such file or directory, access '<path>'`
shape, and walked past it with thinking-only `ls ~/.local/bin/...`
recovery plus later unrelated prose); it is a singleton read-ENOENT
filed by the same detector as the 01a03e61 pile, so the citation
chain must carry it. The leftover-duplicate observe-to-close
drain for the 01a03e61 pile (#662, #953, #958, #972, #967, #977, #982)
is locked under
tests/fleet-failed-command-observe-duplicate-enoent.test.sh. #1059 is
the same read-ENOENT shape as #953 / #1001 but on a DIFFERENT session
slug (the 01a04220 archived-packet session, where the worker `read`
`/home/nish/.local/state/pi-issues/fleet-ops-938.in` — a Pi issue packet
the reap ladder had archived to `ARCHIVED-fleet-ops-938.in-<ts>` before
the session started — got the live `ENOENT: no such file or directory,
access '<path>'` shape, and walked past it with cause-explaining prose
"The file was archived. Let me read it." that names the CAUSE (the file
was archived) but NOT the FAILURE (the read returned ENOENT), followed
by a `cat` of the archived copy). Cause-explaining prose that names why
the file is missing is the same swallowed-failure class as the #953
thinking-only recovery and the #1001 "clear picture" prose: the user is
told a story about why the file is absent, never that the command
failed. A future detector refactor must not treat "The file was
archived" as naming the failure, and must not treat a successful `cat`
of the archived copy as discharging the read-ENOENT of the original
path. The dedicated regression test
tests/fleet-failed-command-read-enoent-archived-packet.test.sh pins
that. #1255 (fleet-ops#1255) is the same read-ENOENT shape as #953 / #1001 / #1059 but
on a DIFFERENT session slug (the 01a04402 salvage-scan session, where
the worker `read`
`/home/nish/workspaces/fleet-ops-rg/bin/salvage-secret-scan` — a stale,
non-canonical checkout that does not carry the file — got the live
`ENOENT: no such file or directory, access '<path>'` shape, and walked
past it with thinking-only cause-prose "The salvage-secret-scan is in
fleet-ops-sync (the sync copy), not in fleet-ops-rg" that names the
OTHER checkout (the cause) but NOT the FAILURE (the read returned
ENOENT), followed by successful `read`s of unrelated files in the same
stale checkout). Thinking-only cause that names the wrong checkout is
the same swallowed-failure class as the #953 thinking-only recovery,
the #1001 "clear picture" prose, and the #1059 "The file was archived"
prose: the user is never told the command failed. A future detector
refactor must not treat "it's in fleet-ops-sync, not in fleet-ops-rg"
as naming the failure, and must not treat later successful reads of
unrelated files as discharging the read-ENOENT of salvage-secret-scan.
The dedicated regression test
tests/fleet-failed-command-read-enoent-stale-rg.test.sh pins that. #1100 (fleet-ops#1100) is the same read-ENOENT shape as #953 / #1001 / #1059 / #1255 but
on a DIFFERENT session slug (the 01a042d4 failed-command-flagged session, where the worker `read`
`/home/nish/workspaces/tooling/fleet-ops/bin/fleet-failed-command-flagged` — a stale,
non-canonical checkout that does not carry the file — instead of the canonical
`/home/nish/workspaces/tooling/fleet-ops-deploy-clone/bin/fleet-failed-command-flagged`,
got the live `ENOENT: no such file or directory, access '<path>'` shape, and walked
past it with thinking-only recovery plus later unrelated prose that never named the
failure). Thinking-only cause that names the wrong checkout is the same swallowed-failure
class as the #953 thinking-only recovery, the #1001 "clear picture" prose, the #1059
"The file was archived" prose, and the #1255 "it's in fleet-ops-sync, not in fleet-ops-rg"
prose: the user is never told the command failed. A future detector refactor must not
treat thinking-only recovery as naming the failure, and must not treat later unrelated
prose as discharging the read-ENOENT of the stale-checkout path.
A bare `cat` of a stale, non-canonical checkout path like
`/home/nish/workspaces/tooling/fleet-ops/bin/fleet-failed-command-flagged`
(the canonical path is `tooling/fleet-ops-deploy-clone/bin/...`) that
returns `cat: <path>: No such file or directory` with
`Command exited with code 1` (isError=true) is a real swallowed
failure (fleet-ops#1097, #1099): the live next turn was thinking-only
("Let me find the correct path") plus a silent `find ...` recovery
toolCall with no user-facing text. `cat` is NOT an ls/grep no-match
probe (there is no canonical-probe exemption for `cat`), and a later
successful `find` / `cat` of the deploy-clone copy does NOT discharge
the original failure. Thinking-only path-hunt is the same
swallowed-failure class as the #953 thinking-only recovery and the
#1001 "clear picture" prose. Distinct from #945 (chained
`ls|wc; echo ---; cat <missing-drop-in>` walked past with "PASS"
prose, locked in tests/fleet-failed-command-flagged.test.sh) and
from #1001 / #1255 (`read` tool ENOENT of a stale checkout — same
stale-checkout family, different tool and path). #1099 is the same
class on a DIFFERENT session slug (01a042cc). The dedicated
regression test
tests/fleet-failed-command-cat-stale-fleet-ops.test.sh pins that.
The auto-filed issue closes via observe-to-close when the session
mtime ages out of the 24h window. An `edit`
tool returning "Could not find the exact text in <path>. The old text
must match exactly including all whitespace and newlines."
(fleet-ops#956, #965) — or the variant
"Found N occurrences of the text in <path>. The text must be unique."
(fleet-ops#1053, same class: oldText matched multiple locations, not zero)
— or the multi-edit array variant
"Could not find edits[0] in <path>. The oldText must match exactly
including all whitespace and newlines." (fleet-ops#1173, same class:
the first edit in a multi-edit array had stale oldText) — or the no-op
variant
"No changes made to <path>. The replacement produced identical content.
This might indicate an issue with special characters or the text not
existing as expected." (fleet-ops#1139, same class: the edit matched but
the intended change did NOT land) — or the schema-validation variant
"Validation failed for tool \"edit\": - path: must have required properties path"
(fleet-ops#1286, same class: the harness rejected
the call BEFORE dispatch because the `edit` arguments omitted a
required top-level field, isError=true, details={}, no
"Command exited with code" line; live session 01a043c8 working
/tmp/fleet-ops/bin/{pi-issue-run,pi-packet-run,pi-scout-run,agent-cron-run}
where the worker omitted the top-level `path` field four times in a row)
—
is also a real swallowed
failure: a silent `read` recovery, a later thinking-only note that the
file was different, or unrelated prose that moves on, is not a
user-facing flag. For the #1139 no-op shape the live recovery was
cause-explaining prose — "The text is already the same. Let me check
what's actually there:" — followed by two `grep` probes and four empty
assistant turns. That names the CAUSE (the file already held that text),
not the FAILURE (the edit returned isError), exactly like the #1059
"The file was archived" prose, so it does not discharge the pending
failure. Do NOT add a READ_OFFSET_RE-style exemption for the no-op
wording on the theory that "nothing broke": the worker believed it had
edited the file and it had not, which is the whole point of the rule.
For the #1140 sibling (same 0-match wording as #956, live path
/home/nish/workspaces/agent-state/READY-WORK.md, session
2026-08-27T12-07-48-699Z_01a0431e-84db-7863-9473-719a7cf6064e) the
live recovery was a successful `bash cat >>` append of the SAME path
after a thinking note, a grep, and a re-read; later user-facing prose
("The ready-work system re-dispatched issue #1001 from READY-WORK.md")
moved on without naming the failure. A successful write/append of the
same file is recovery, not a user-facing flag — do NOT add a
"successful write of the same path" exemption. observe-to-close ages
out at 2026-08-28T12:07:48Z.
tests/fleet-failed-command-edit-unmatch.test.sh pins the single-edit,
multi-match, and no-op shapes; tests/fleet-failed-command-edit-array-
unmatch.test.sh pins the multi-edit array `edits[0]` shape
(fleet-ops#1173); tests/fleet-failed-command-edit-schema-validation
.test.sh pins the schema-validation shape (fleet-ops#1286, live
session 01a043c8). The #1286 schema-validation class is the FOURTH
sibling of the edit-failure family: the harness rejects the `edit`
call before dispatch because the arguments omitted a required
top-level field (`path` in the live case; `edits` is the other
required field). The live recovery was thinking-only cause prose
("The edit tool requires the path field", "Keep missing the path.
Odd. Let me check if the old text actually matches exactly.") — that
names the CAUSE (the worker omitted the field) but NOT the FAILURE
(the call returned isError=true with the schema-validation message),
exactly like the #1059 "The file was archived" prose and the #1139
"The text is already the same" prose, so it does not discharge the
pending failure. Do NOT add a READ_OFFSET_RE-style exemption for the
schema-validation wording on the theory that "the call never ran": the
worker believed the edit ran and it did not, which is the same
swallowed-failure class as the #1139 no-op and the #956 stale-oldText
siblings. The #1286 live session's retries DID eventually land the
change, but only because the worker silently re-issued the edit with
the missing `path` field added — that successful retry is content,
not a user-facing flag, and the four schema-validation toolResults
that preceded it must still be named. #970 is the same session shape as #956 / #965 (the
01a03dee edit-unmatch session); it is a leftover open duplicate filed
by the same GitHub-search-index-delay that produced #951 / #965, so
the citation chain must carry it. #975 is the same session shape as
#956 / #965 / #970 (the 01a03dee edit-unmatch session); it is a
leftover open duplicate filed by the same GitHub-search-index-delay
that produced #951 / #965, so the citation chain must carry it. #980 is
the same session shape as #956 / #965 / #970 / #975 (the 01a03dee
edit-unmatch session); it is a leftover open duplicate filed by the
same GitHub-search-index-delay that produced #951 / #965, so the
citation chain must carry it. The leftover-duplicate observe-to-close
drain for the 01a03dee pile (#956, #965, #970, #975, #980) is locked
under tests/fleet-failed-command-observe-duplicate-open.test.sh.
A `python3 -c` / `python3 << 'EOF'` probe that crashes
with a Python traceback (KeyError, NameError, etc.) and
'Command exited with code 1' (fleet-ops#957, #966, #1003) is also a real
swallowed failure: the command is not grep/rg/diff/ls/which so it is
not a no-match probe, and a silent re-probe, a thinking block, or
later prose that moves on is not a user-facing flag. The live #1003
shape is the same class as #957 (python3 -c walked past) but the
wording and the `gh | python3 -c` pipe are distinct: a
`gh issue view <N> --comments --json <fields> | python3 -c "...d['comments']..."`
probe whose --json filter omitted the field the probe tried to read
hits `KeyError: 'comments'` with isError=true and
`Command exited with code 1`; the next turn is a toolCall-only re-probe
that hits the same KeyError. #966 is the same session shape as
#957 (the 01a03e38 python-traceback session); it is a leftover open
duplicate filed by the same GitHub-search-index-delay that produced
#951 / #965, so the citation chain must carry it. The leftover-duplicate
observe-to-close drain for the 01a03e38 pile (#952, #957, #966, #971,
#976, #981) is locked under
tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh.
#1019 is the same session shape as #1003 (the 01a041a5
gh--json+python3 KeyError session); it is a leftover open duplicate
filed by the same GitHub-search-index-delay that produced
#951 / #965 / #966, so the citation chain must carry it. The
leftover-duplicate observe-to-close drain for the 01a041a5 pile
(#1003, #1019) is locked under
tests/fleet-failed-command-observe-duplicate-1003.test.sh.
fleet-ops#1142 is the same `gh issue view --comments --json
author,body,createdAt | python3 -c "...d['comments']..."` KeyError as
#1003, on a DIFFERENT session (01a04326, the worker claiming #1003).
The next turn was a thinking block ("the same bug") plus a successful
`gh api graphql` comments query — not a user-facing flag. A future
detector refactor must not treat GraphQL success as discharging the
KeyError, and must not treat thinking "the same bug" as naming the
failure. The dedicated regression test locks the live fleet-ops#1142
shape under tests/fleet-failed-command-gh-json-graphql-recovery.test.sh.
A `gh issue view <N> -R ... --body` command is not valid: `gh issue view`
has no `--body` flag, so it exits 1 with `unknown flag: --body` and the
full usage help (fleet-ops#1055, session
2026-08-27T07-15-49-602Z_01a04213-32e2-7409-a4ba-bd86f12ad936). The
assistant's next turn was empty (model provider 503 errors) and later
toolCalls did not name the failure. It is not a GraphQL transient error
(fleet-ops#678) or a no-match probe; it is a real swallowed failure and
must be flagged. The dedicated regression test locks it under
tests/fleet-failed-command-gh-issue-view-body.test.sh.
A compound `echo "=== MERGED RECENT ==="` +
`gh pr list -R ... --state merged --sort -mergedAt ... 2>/dev/null`
chain is a real swallowed failure (fleet-ops#1107, session
2026-08-27T11-16-51-853Z_01a042ef-e00d-7ace-b43a-7e40a2623f48):
`--sort -mergedAt` is not a valid `gh pr list` sort value, stderr is
silenced, and the toolResult is only the echo marker plus
`Command exited with code 1` (isError=true). The assistant walked
past it with thinking-only recovery and later
"Now I have the full picture. Let me fix and re-dispatch." prose,
which does not name the failure. Distinct from #1055 (`gh issue view
--body` with visible `unknown flag: --body`), #698 (`gh api` HTTP 404
with visible `Not Found`), #1219 (`Unknown JSON field: "label"`), and
grep POSIX no-match (BENIGN_STAGE_RE; a `; grep` sibling that prints
the same `=== MERGED RECENT ===` marker must stay a probe). `gh pr list`
is not a no-match probe, and silencing stderr does not make an invalid
sort benign. The dedicated regression test locks it under
tests/fleet-failed-command-gh-pr-list-invalid-sort.test.sh.
A `gh issue view <N> -R ... --json <fields>` command whose filter names
an unknown field (e.g. `label` instead of `labels`) is not valid: `gh`
rejects it with `Unknown JSON field: "label"` and the list of available
fields, then exits 1 (fleet-ops#1219, session
2026-08-27T15-14-27-082Z_01a043c9-648a-75d9-add1-a7f78fe03f68). The
assistant issued the invalid `--json` filter alongside a valid
`gh issue view --json body` sibling in the same turn; the next turn was
a thinking block plus follow-up toolCalls with no user-facing text
naming the failure. Distinct from #1055 (`unknown flag: --body`, an
invalid flag) and #1003 (`KeyError: 'comments'` from python parsing
`--json` output that omitted a field the probe then read — gh itself
succeeded). It is not a GraphQL transient error (fleet-ops#678) or a
no-match probe; it is a real swallowed failure and must be flagged. The
dedicated regression test locks it under
tests/fleet-failed-command-gh-issue-view-unknown-field.test.sh.
A `gh pr view <N> -R ... --json <fields>` command whose filter names
an unknown field (e.g. `merged` instead of `mergedAt`) is the same
invalid-field class, but a trailing pipe (`2>&1 | head`) masks gh's
non-zero exit: bash's exit code is `head`'s (0), so the toolResult
carries `isError: false` and no `Command exited with code 1` trailer
(fleet-ops#1193, session
2026-08-27T08-16-44-255Z_01a0424a-f6df-7cc2-b1c3-f5db8df57d11, e.g.
`gh pr view 1026 -R Nishfleet/fleet-ops --json
number,title,state,body,url,headRefName,merged 2>&1 | head -40`).
The a5022b8 / #1048 / #1122 isError=false guard returns early in
`result_failed` BEFORE any regex is consulted, so the detector cannot
catch this real failure without re-introducing the false-positive
class (successful `gh pr view` / `git show` output that quotes
`Unknown JSON field` is content). Do not add `Unknown JSON field` to
`REAL_ERR_RE`. The un-piped version of the same command (no pipe, no
redirect) returns the same body AND `isError=true` AND `Command
exited with code 1`, which the generic isError path already flags.
The mechanism is worker-side (`prompts/worker.md` cites fleet-ops#1193
and requires the worker to name `Unknown JSON field: "<field>"` in
user-facing text in the same turn even when `isError` is false). The
dedicated regression test
tests/fleet-worker-prompt-gh-pr-view-unknown-field.test.sh asserts 0
findings for the masked shape and 1 finding for the unpiped contrast.
The UNPIPED form of the same `gh pr view <N> --json mergedAt,merged`
(no pipe, no redirect) returns the same body AND `isError=true` AND
`Command exited with code 1` (fleet-ops#1244, session
2026-08-27T15-58-21-599Z_01a043f1-979f-75e8-93f5-9b72f5c84db9). The
assistant's next turn was a thinking-only note ("doesn't have the
mergedAt field") plus a silent retry (`gh pr view --json title,state`).
The detector already flags this class via the generic isError path.
Do NOT add `Unknown JSON field` to REAL_ERR_RE and check it when
isError is false: that is the pipe-masked sibling (#1193) and would
break the #1048 / #1122 / #1074 contract that successful output
quoting error strings is content. The dedicated regression test
tests/fleet-failed-command-gh-pr-view-merged.test.sh pins the unpiped
shape (1 finding), the piped contrast (0 findings), the valid
`--json mergedAt` success (0 findings), and the class lock
(`--json closedReason` also flags). Live command:
`gh pr view 392 -R Nishfleet/fleet-ops --json mergedAt,merged 2>&1`,
which prints `Unknown JSON field: "merged"` and the Available fields
listing `mergedAt`/`mergedBy` but not `merged`.
A `python3 -c "from <hyphenated_name>
import ..."` / `python3 << 'PYEOF'` probe against a sibling file whose
actual filename has hyphens (e.g. `failed-command-flagged.py` while
importing `failed_command_flagged`) fails with `ModuleNotFoundError:
No module named '<hyphenated_name>'` and `Command exited with code 1`
(fleet-ops#937): the same hyphenated re-probe fails identically, and
two failed probes are walked past with no user-facing flag before the
worker notices the hyphens. The class is the same as #957 (python3
traceback walked past); the dedicated regression test pins it so a
future refactor that drops the #937 citation from the docstring, the
prompt, or the test host list is caught.
A `python3 - <<'PY'` stdin script that calls
`serialization.load_pem_private_key` on the raw quoted
`NISHFLEET_WORKER_PRIVATE_KEY` value from the worker env file
(fleet-ops#1174, session
2026-08-27T13-43-46-261Z_01a04376-5f55-7726-9184-4e31bb7e54f2)
crashes with `File "<stdin>", line 28, in <module>` then
`load_pem_private_key` then `ValueError: Could not
deserialize key data` and `Command exited with code 1`.
The env value is an env-via-heredoc, not the PEM itself.
Cause-explaining prose ("The PEM in the env may be
malformed", "stored inside a `cat <<'NISHFLEET_PEM_EOF'`
heredoc") names the CAUSE, not the FAILURE; a later
successful extract-and-mint is not a user-facing flag.
The class is the same as #957 (python traceback walked
past); the wording (`load_pem_private_key`,
`Could not deserialize key data`, File `"<stdin>"`) is
the live #1174 fingerprint. A future refactor that treats
cryptography / PEM / JWT mint as a benign probe, treats
File `"<stdin>"` as distinct from File `"<string>"` and
therefore suppressible, or lets cause-prose discharge
FLAG_RE would silently suppress this real signal. The
dedicated regression test
tests/fleet-failed-command-pem-deserialize.test.sh pins it.
A `git checkout <branch>` (or a
compound `&&` chain whose tail is `git checkout <branch>`) inside a
worktree whose target branch is checked out in another worktree is a
real swallowed failure (fleet-ops#954, #962, #968): git refuses with
`fatal: '<branch>' is already used by worktree at '<path>'` and exits
128. The fatal line is not a canonical no-ref probe (GIT_CANONICAL_NO_REF_RE
matches only `ambiguous argument` / `bad revision`), and `git checkout`
is not in the git-ref probe family, so the failure must be flagged. A
successful `git fetch origin` prefix in the same `&&` chain must not
mask the failing `git checkout` tail. The same session can carry BOTH
shapes (a &&-chain with a `git fetch origin` prefix AND a follow-up
bare `cd <worktree> && git checkout main` recovery attempt); each is
its own finding and must be emitted with the worktree-conflict
fingerprint, not mixed with the other toolResult's snippet. A `git
branch -f <branch> <ref>` (or `git push --force` / `git push --force-
with-lease`) run inside the worktree that has `<branch>` checked out is
the same worktree-ownership class (fleet-ops#849, #985): git refuses
with `fatal: cannot force update the branch '<branch>' used by worktree
at '<path>'` and exits 128, the next turn is a recovery toolCall
(`git checkout -b tmp-clean origin/main ...`) with only a thinking-block
reason and no user-facing text naming the failure, and `git branch -f`
is NOT in the git-ref probe family (GIT_BENIGN_RE covers only
log|rev-parse|show|diff|cat-file|shortlog), so the failure must be
flagged. #985 is the leftover open duplicate of #849 for the 01a04105
git-branch-force session (same signal slug); the leftover-duplicate
observe-to-close drain for that pile is locked under
tests/fleet-failed-command-observe-duplicate-git-branch-force.test.sh.
A `git cherry-pick <sha>` that exits 1 with `isError=true` because the
cherry-pick resulted in an empty commit (the change is already on the
target) is a real swallowed failure (fleet-ops#1065): git prints
`Auto-merging <path>` + `The previous cherry-pick is now empty,
possibly due to conflict resolution.` + `Command exited with code 1`,
and the worker walks past it with a thinking-only next turn plus a
recovery toolCall (no user-facing text naming the failure). The class
is distinct from the #954 / #962 / #968 git-checkout worktree-conflict
shape and the #849 / #985 git-branch-force shape (both exit 128 with a
`fatal:` line): the cherry-pick empty shape is exit 1 with NO `fatal:`
line. `git cherry-pick` is NOT in the git-ref probe family
(GIT_BENIGN_RE covers only log|rev-parse|show|diff|cat-file|shortlog)
and not in BENIGN_STAGE_RE, so the exit-1 path flags it directly. A
future refactor that adds `cherry-pick` to GIT_BENIGN_RE (or to
BENIGN_STAGE_RE) would silently suppress this real signal; the
dedicated regression test
tests/fleet-failed-command-git-cherry-pick-empty.test.sh pins that it
does not. The auto-filed issue closes via observe-to-close when the
session mtime ages out of the 24h window. A compound bash chain
(`;`-separated) where earlier commands succeed and a downstream
`ls <path>` fails with `ls: cannot access '<path>': Permission denied`
AND the chain's last command is silenced (`2>/dev/null`) is a real
swallowed failure (fleet-ops#1061): bash exits 1 (the silenced last
command's exit), the visible `Permission denied` line is in
`REAL_ERR_RE` so no `LS_BENIGN_RE` (requires code==2) /
`BENIGN_STAGE_RE` short-circuit applies, and a thinking-only next
turn plus a recovery toolCall (no user-facing text naming the
failure) is not a flag. The class is distinct from the live #794
single-command `ls -l /etc/shadow` exit 2 (no compound chain, no
silenced tail) and the live #794 ls no-match exemption (canonical
`No such file or directory` line, NOT `Permission denied`): the
compound-chain shape has a `Permission denied` line visible AND a
silenced tail, so bash exits 1 (not 2) and `Permission denied`
keeps the toolResult as a real failure. A future refactor that
broadens the ls exemption to `Permission denied`, drops
`Permission denied` from REAL_ERR_RE, or stops walking past
compound-chain failures would silently suppress this real signal;
the dedicated regression test
tests/fleet-failed-command-compound-ls-permission-denied.test.sh
pins that it does not. The auto-filed issue closes via
observe-to-close when the session mtime ages out of the 24h window.
A same-turn sibling of a `git clone` into `/tmp/<fresh-clone>` that
races with `cd /tmp/<fresh-clone> 2>/dev/null && ls ...` and returns
`(no output)  Command exited with code 1` is a real swallowed failure
(fleet-ops#1217): the clone is still in flight, `cd` fails, stderr is
silenced so the snippet is empty, and the next assistant turn is a
silent `cd && ls` recovery with no user-facing text naming the failure.
The detector already flags this class via the generic
`isError or code != 0` path. `cd` is not in BENIGN_STAGE_RE.
`LS_BENIGN_RE` matches the command text because it contains `ls`, but
that short-circuit only applies on exit 2; the live shape is exit 1.
A future refactor that treats `cd ... 2>/dev/null` as a probe, treats
`(no output)` + exit 1 as benign whenever stderr is silenced, broadens
`LS_BENIGN_RE` to code==1, or lets a same-turn sibling success mask a
sibling failure would silently suppress this real signal. The class is
distinct from #793 (`bash /tmp/<fresh-script>` exit 1 with the same
empty snippet, different command), #765 (`cd ... 2>/dev/null && git
status` exit 128 with `fatal: not a git repository`), and grep/rg
POSIX no-match (BENIGN_STAGE_RE; the live session also carried a later
`grep -nF` with the same empty snippet, which must stay a probe). The
dedicated regression test
tests/fleet-failed-command-clone-race-cd.test.sh pins that. The
auto-filed issue closes via observe-to-close when the session mtime
ages out of the 24h window. Live session
2026-08-27T15-13-39-420Z_01a043c8-aa5c-72cb-9f02-d452218d767f.jsonl:
`cd /tmp/fleet-ops-fresh-1165 2>/dev/null && ls bin/ 2>/dev/null |
head -20 && echo "---PROMPTS---" && ls prompts/ 2>/dev/null`.
A `git clone git@github.com:...` that returns
`Permission denied (publickey)` +
`fatal: Could not read from remote repository` +
`Command exited with code 128` (isError=true) is a real swallowed
failure (fleet-ops#1185). This host has no GitHub deploy SSH key.
The live worker walked past it with a thinking-only
"The SSH key doesn't have access. Let me try HTTPS" plus a silent
HTTPS retry (harness-blocked) and then a successful `gh repo clone`.
Thinking is not a user-facing flag. A later successful clone does
not discharge the SSH failure. `git clone` is NOT in GIT_BENIGN_RE
(log|rev-parse|show|diff|cat-file|shortlog only). REAL_ERR_RE
matches `Permission denied`, so adding `git clone` to GIT_BENIGN_RE
alone would not hide this — a future refactor would also have to
drop `Permission denied` from REAL_ERR_RE, or start collecting
`thinking` in `_text_chunks`. The class is distinct from #1217
(HTTPS clone racing a silenced cd, empty snippet, exit 1), #765
(`fatal: not a git repository`), #822 (git-ref probe), and #1061
(compound-chain ls Permission denied). The dedicated regression
test tests/fleet-failed-command-clone-ssh-publickey.test.sh pins
that. The auto-filed issue closes via observe-to-close when the
session mtime ages out of the 24h window. Live session
2026-08-27T14-20-10-780Z_01a04397-b49c-7f5e-8b60-46b28e3bed5d.jsonl:
`git clone git@github.com:Nishfleet/fleet-ops.git .`.
A `gh api /user` (or `gh api user`) call under a GitHub App
installation token that returns `Resource not accessible by
integration` + `gh: Resource not accessible by integration (HTTP 403)`
+ `Command exited with code 1` (isError=true) is a real swallowed
failure (fleet-ops#1253). App installation tokens cannot call the
Users API. The live session probed identity with a compound
`gh api /user` + `whoami` + `gh api /user --jq '.login'` chain and
walked past both 403s. A successful `whoami` in the same compound
command is not a user-facing flag. Naming `403` or `not accessible by
integration` in later assistant text is. The dedicated regression test
tests/fleet-failed-command-gh-api-403-integration.test.sh pins that.
Live session
2026-08-27T16-15-45-417Z_01a04401-8509-7e94-8611-0fc81a5d1b85.jsonl.
A compound `;`-separated `systemctl --user stop <unit> 2>&1;
systemctl --user reset-failed <unit> 2>&1` (or the bare
`systemctl --user stop <unit> 2>&1`) on a unit that is not currently
loaded is a real swallowed failure (fleet-ops#1221): systemd prints
`Failed to stop <unit>: Unit <unit> not loaded.` and
`Failed to reset failed state of unit <unit>: Unit <unit> not loaded.`
on stderr, exits 1, the harness sets isError=true, and
`Command exited with code 1` lands in the toolResult. The next
assistant turn is a thinking-only note ("The unit X doesn't exist
anymore") plus a `gh issue view` recovery toolCall with no
user-facing text naming the failure. The class is distinct from
#784 (`systemctl --user status` of an Active: failed unit, exit 3,
`× unit`, `Active: failed (Result: exit-code)`): the #1221 shape is
exit 1 with the canonical `Unit <name> not loaded.` lines and a
non-silenced compound `;`-separated chain (no `2>/dev/null` on the
chain tail). `systemctl` is not in BENIGN_STAGE_RE / LS_BENIGN_RE /
XARGS_BENIGN_RE so the failure must be flagged. A future refactor
that adds `systemctl` to BENIGN_STAGE_RE, treats `Unit ... not loaded.`
as a probe line, or lets a same-turn sibling `systemctl --user status`
success mask the failing `systemctl --user stop` tail would silently
suppress this real signal. The dedicated regression test
tests/fleet-failed-command-systemctl-stop-not-loaded.test.sh pins
that. The auto-filed issue closes via observe-to-close when the
session mtime ages out of the 24h window. Live session
2026-08-27T15-29-03-179Z_01a043d6-c2cb-76cd-90c3-e9d8499c113d.jsonl:
the compound `;`-separated `systemctl --user stop 0509-devserver.service
2>&1; systemctl --user reset-failed 0509-devserver.service 2>&1` call
returned 1 because the unit was not loaded, and the assistant
continued in thinking plus a `gh issue view` recovery without
naming the failure in user-facing text.
A malformed Pi toolCall with an empty name (id "", name "",
arguments the non-JSON string "command") that returns `Tool  not
found` (two spaces because the name is empty; isError=true,
details={}, no `Command exited with code` line) is a real swallowed
failure (fleet-ops#1242): the live next turn was an empty assistant
message with stopReason=error and an HTTP 400 `Tool name must be
nonempty` errorMessage. errorMessage is harness metadata, not
user-facing text (`_text_chunks` only reads type=="text"), so it
does not discharge the pending failure. The detector already flags
this class via the generic isError path. Empty toolName / empty
toolCallId is not a harness block: the call was issued and Pi
answered. `Tool  not found` is not a grep/rg/which no-match probe.
A future refactor that treats empty toolName as "the command never
ran", treats `Tool  not found` as a probe because the snippet
contains "not found", treats errorMessage as a user-facing flag, or
collapses internal double-spaces in snippets would silently
suppress this real signal. Distinct from #937 (python3
ModuleNotFoundError + exit 1 on a named bash probe) and #698
(`gh: Not Found (HTTP 404)` on a named bash call). The dedicated
regression test tests/fleet-failed-command-empty-tool-name.test.sh
pins that. The auto-filed issue closes via observe-to-close when
the session mtime ages out of the 24h window. Live session
2026-08-27T15-50-45-409Z_01a043ea-a1a1-79d2-b579-ef094ed1e3aa.jsonl:
empty-name toolCall on fleet-ops#1009, snippet `Tool  not found`.
A `bin/fleet-no-agent-names-check` REJECT (exit 1 with
`REJECT: agent attribution found`) is a real swallowed failure. The live
#1052 session (01a041ea) ran the gate against `tests/fleet-no-agent-names.test.sh`
while debugging fleet-ops#926; the test file contains example attribution
strings, so the tool correctly REJECTED, but the next turn said "Good - this is
testing the tool's behavior..." and moved on. That prose does NOT name the
failure. The prompt-side lock in `prompts/worker.md` forbids explaining a
no-agent-names REJECT as test data; the dedicated regression test
`tests/fleet-failed-command-no-agent-names-reject.test.sh` pins the shape
(fleet-ops#1052). A `bin/fleet-failed-command-flagged` invocation
(`FLEET_FAILED_COMMAND_SESSIONS=/tmp`, `FLEET_FAILED_COMMAND_FILE_ISSUES=0`)
that returns `findings=N` + `LOUD [FAILED-COMMAND-SWALLOWED]` lines +
`Command exited with code 1` (isError=true) is a real swallowed failure
(fleet-ops#1220): the detector's contract is to exit 1 when it finds
things, which does not make the non-zero a probe; the
FAILED-COMMAND-SWALLOWED lines in the toolResult are about OTHER
sessions, not a user-facing flag of THIS command; and a thinking-only
note that the detector is working plus a later grep is not a flag. The
detector already flags this class via the generic `isError or code != 0`
path. A future refactor that treats the detector bin's own exit 1 as
expected, treats FAILED-COMMAND-SWALLOWED in the toolResult as
already-flagged, or lets thinking that says "the detector is working"
discharge the pending failure would silently suppress this real signal.
Distinct from #727 (`npm run canary` exit 1, a different command) and
grep/rg POSIX no-match (BENIGN_STAGE_RE; the live session also carried
an earlier `grep "fleet-heartbeat.service.d"` with `(no output)`, which
must stay a probe). The dedicated regression test
tests/fleet-failed-command-detector-bin-exit.test.sh pins that. The
auto-filed issue closes via observe-to-close when the session mtime
ages out of the 24h window. Live session
2026-08-27T15-16-17-039Z_01a043cb-120f-7fe1-952d-b01474cd5852.jsonl:
`cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1054 &&
FLEET_FAILED_COMMAND_SESSIONS=/tmp ... FLEET_FAILED_COMMAND_FILE_ISSUES=0
bin/fleet-failed-command-flagged 2>&1`. A spawn-guard or harness block
(SPAWN_BLOCKED / "Dangerous command blocked") is not a ran-and-failed
command: the call never executed.

Usage:
  python3 lib/failed-command-flagged.py scan --root DIR [--now ISO]
      [--window-hours 24] [--grace-minutes 20]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from typing import Any

EXIT_RE = re.compile(r"Command exited with code (\d+)")
TIMEOUT_RE = re.compile(r"Command timed out", re.I)
# Pipeline stage that is a search/diff whose exit 1 means "no match".
BENIGN_STAGE_RE = re.compile(
    r"(?:^|[;&|\n]|&&|\|\|)\s*(?:sudo\s+)?"
    r"(?:grep|egrep|fgrep|rg|ripgrep|diff|git\s+grep|git\s+diff|which)\b",
    re.I,
)
# xargs wrapping a benign search command (live #942). xargs exits 123 when an
# invoked command exits 1-125; for grep/rg/diff exit 1 is POSIX no-match, so
# `find ... | xargs grep -l "X" 2>/dev/null` exits 123 with "(no output)" when
# nothing matched. The detector treated that 123 as a real swallowed failure
# when it is the same no-match class as direct grep exit 1. The inner search
# command must be one of the BENIGN_STAGE_RE commands; `xargs rm` / `xargs
# chmod` exiting 123 is a real error and must NOT match. Flags between xargs
# and the search command (e.g. `xargs -0 grep`, `xargs -I {} grep`) are
# allowed; the gap may not cross a pipeline/logic separator.
XARGS_BENIGN_RE = re.compile(
    r"(?:^|[;&|\n]|&&|\|\|)\s*(?:sudo\s+)?"
    r"xargs\b[^|;&\n]*?"
    r"(?:grep|egrep|fgrep|rg|ripgrep|diff|git\s+grep|git\s+diff)\b",
    re.I,
)
# Real errors that must not hide behind a grep in the same script.
REAL_ERR_RE = re.compile(
    r"(Not Found|Permission denied|HTTP\s*[45]\d\d|"
    r"error TS\d+|API rate limit)",
    re.I,
)
# ls(1) exits 2 when a path or glob does not match. Agents use this as a probe,
# so treat it like grep no-match: the canonical output is a single line
#   ls: cannot access '<path>': No such file or directory
# (GNU ls also adds this with --color; busybox ls uses the same shape; macOS
# ls prints `ls: <path>: No such file or directory` without the quotes). When
# the toolResult text contains only that probe shape — and no other ls error
# (permission denied, I/O, not-a-directory, etc.) — it is a probe, not a
# swallowed failure (live #794).
LS_BENIGN_RE = re.compile(
    r"(?:^|[;&|\n]|&&|\|\|)\s*(?:sudo\s+)?(?:ls|ll)\b",
    re.I,
)
# Canonical "this path does not exist" probe line. Matches GNU coreutils ls
# (single quotes), busybox ls (single quotes), and BSD/macOS ls (no quotes —
# the path is bare). The path is intentionally permissive; we only need to
# match the shape, not validate the path itself.
LS_CANONICAL_NO_MATCH_RE = re.compile(
    r"^ls(?:\(\d+\))?:\s+"
    r"(?:cannot access '([^']+)'|([^\s:][^:]*?)):\s+No such file or directory\s*$",
    re.M,
)
# Real ls(1) errors that must NOT be treated as no-match probes even when the
# command is "ls". Permission denied / I/O error / not-a-directory / etc. are
# genuine swallowed failures; only the canonical "No such file or directory"
# line is benign for ls exit 2.
LS_REAL_ERR_RE = re.compile(
    r"(Permission denied|I/O error|Input/output error|"
    r"Is a directory|Not a directory|cannot open directory|"
    r"cannot read directory|operation not permitted|Operation not permitted|"
    r"Read-only file system|Stale file handle|"
    r"Too many levels of symbolic links|Structure needs cleaning|"
    r"No space left on device|File name too long|"
    r"Invalid argument|Text file busy)",
    re.I,
)
# git ref-existence probe (live #822): the agent runs
#   `git log|rev-parse|show|diff|cat-file <ref> 2>/dev/null`
# to test whether a branch/tag/remote ref exists. When the ref is unknown
# git exits 128 with `fatal: ambiguous argument '<ref>': ...` on stderr
# (or `fatal: bad revision '<ref>'` on older git). The agent has silenced
# stderr on purpose, so the toolResult shows the successful stdout of any
# preceding command in the same chain and a bare "Command exited with
# code 128" trailer. Treat that as a deliberate probe, not a swallowed
# failure. Other `fatal:` lines (not a git repository, unable to access,
# repository not found, bad object, etc.) are real failures and must NOT
# be exempted.
GIT_BENIGN_RE = re.compile(
    r"(?:^|[;&|\n]|&&|\|\|)\s*(?:sudo\s+)?"
    r"git\s+(?:log(?:\s+-?\d+)?|rev-parse|show|diff|cat-file|shortlog)\b",
    re.I,
)
# Canonical "this ref does not exist" probe line emitted by git on stderr.
# Modern git prints "fatal: ambiguous argument '<ref>': unknown revision
# or path not in the working tree."; older git prints "fatal: bad
# revision '<ref>'". Both are exit 128 and both are deliberate-probe
# signals. The ref itself is intentionally permissive.
GIT_CANONICAL_NO_REF_RE = re.compile(
    r"^fatal:\s+(?:ambiguous argument '([^']+)':"
    r"|bad revision '([^']+)')",
    re.M,
)
# Real git fatal/permission lines that must NOT be treated as a no-ref
# probe even when the command is in the git-ref family. A `git log` on a
# corrupt index, a repo that is not a git repository, a missing remote,
# a bad config, a bad object, or a denied access is a genuine swallowed
# failure; only the canonical "ambiguous argument / bad revision" shape
# is benign.
GIT_REAL_ERR_RE = re.compile(
    r"(fatal:\s+not a git repository"
    r"|fatal:\s+unable to access"
    r"|fatal:\s+repository\b"
    r"|fatal:\s+remote\b"
    r"|fatal:\s+(?:bad config|invalid config|missing config)"
    r"|fatal:\s+(?:index file|object|loose object|packed)"
    r"|fatal:\s+(?:ref|reference)\b.*does not exist"
    r"|fatal:\s+bad object"
    r"|fatal:\s+(?:cannot|could not)"
    r"|Permission denied"
    r"|fatal:\s+protocol error"
    r"|fatal:\s+(?:early EOF|the remote end hung up)"
    r"|error: pathspec)",
    re.I,
)
# `systemctl status <unit>` piped through `head`/`tail`/`grep` loses the
# exit code: bash has no `pipefail`, so the pipeline exit is the last
# command's (head, 0) and Pi sets isError=false. systemd still prints
# `× unit` and `Active: failed (Result: exit-code)` for a failed unit.
# Detect this from the command and the output, not the exit status
# (fleet-ops#879). This does NOT flag `systemctl --user --failed` (no
# `status` in the command) or `systemctl status` of an active/running unit.
SYSTEMCTL_STATUS_RE = re.compile(
    r"(?:^|[;&|\n]|&&|\|\|)\s*(?:sudo\s+)?"
    r"systemctl\b[^|;&\n]*?\bstatus\b",
    re.I,
)
# systemd uses `×` (multiplication sign) for a failed/inactive unit and
# `●`/`○` for a healthy one. The `Active: failed` line is the signal.
SYSTEMCTL_FAILED_RE = re.compile(
    r"^\s*×\s+\S+(?:.*\n)*?\s*Active:\s+failed\b",
    re.M | re.I,
)
# Unquoted assistant report. Tight on the standing-rule verbs.
# \b403\b and "not accessible by integration" are the live #1253
# `gh api /user` App-token 403 class (parallel to \b404\b for #698).
FLAG_RE = re.compile(
    r"(failed|fails|failing|failure|\berror\b|non-zero|exited with|"
    r"timed out|timeout|blocker|not found|\b404\b|\b403\b|\b50[0-9]\b|"
    r"not accessible by integration|"
    r"unexpected failing command|it is now the blocker)",
    re.I,
)
# Command never ran: Pi confirmation prompt, or fleet spawn-guard block.
# SPAWN_BLOCKED is the live #648 class (git_stash_forbidden on `git stash list`).
HARNESS_BLOCK_RE = re.compile(
    r"Dangerous command blocked \(no UI for confirmation\)"
    r"|SPAWN_BLOCKED reason=",
    re.I,
)
# Read tool with an offset past the end of the file: a negative result,
# like grep/rg/diff no-match, not a swallowed command failure.
# Do NOT add a similar exemption for `read` "EISDIR: illegal operation
# on a directory, read" (fleet-ops#1170 / #1243: the path is a
# directory, not a missing file and not an overshot offset).
# Do NOT add a similar exemption for `edit` "Could not find the exact
# text" (fleet-ops#956, #965, #970, #975, #980), "Found N occurrences"
# (fleet-ops#1053, same edit-unmatch class: oldText matched multiple
# locations, not zero), "No changes made ... The replacement produced
# identical content" (fleet-ops#1139, same class: the edit matched but the
# intended change never landed), or the schema-validation shape
# "Validation failed for tool \"edit\": - path: must have required properties path"
# (fleet-ops#1286, same class: the harness rejected the
# call before dispatch because the `edit` arguments omitted a required
# top-level field). Those are real swallowed failures: the worker's
# oldText or newText was stale, or the worker's `edit` arguments were
# malformed. A silent read/grep recovery, and cause-explaining prose
# ("The text is already the same", "The edit tool requires the path
# field"), do not discharge it. A successful bash `cat >>` append of the
# same path (fleet-ops#1140, live READY-WORK.md), and cause-explaining
# prose ("The text is already the same"), do not discharge it.
READ_OFFSET_RE = re.compile(
    r"Offset \d+ is beyond end of file \(\d+ lines total\)", re.I
)
# Downstream of a harness block (fleet-ops#677): the spawn-guard refused the
# heredoc/redirect that would have created a script, so a later `bash <path>`
# fails with exit 127 "No such file or directory". The assistant recovers via
# the write tool. That ENOENT is a cascade of the block, not a swallowed
# command failure. Only exempt when a prior toolResult in the session was a
# harness block — a 127 ENOENT with no prior block is a real failure
# (fleet-ops#1254): there is no prior harness block, so the #677 cascade
# exemption does not apply, and the next assistant turn is a thinking-only
# "The path is wrong" plus a silent retry with the correct `.test.sh`. The
# detector already flags this class via the generic `isError or code != 0`
# path. A future refactor that drops the `had_prior_block` gate on the #677
# 127-ENOENT cascade, treats a truncated `.est.sh` as an existence probe,
# treats thinking-only "The path is wrong" as a flag, or lets a later
# successful `.test.sh` sibling discharge the 127 would silently suppress
# this real signal. The class is distinct from #677 (127 ENOENT
# *downstream of a harness block*), #793 (`bash /tmp/<fresh-script>`
# exit 1 with empty snippet, file existed), and the read-ENOENT family
# (#651 / #953 / #1001 / #1059; `read` tool, no exit-code line). The
# dedicated regression test tests/fleet-failed-command-typo-est-sh.test.sh
# pins that. Live session
# 2026-08-27T16-16-10-880Z_01a04401-e880-7f21-b990-b20a28e67e9d.jsonl:
# `bash tests/fleet-failed-command-edit-unmatch.est.sh`.
ENOENT_RE = re.compile(r"No such file or directory", re.I)
SLUG_RE = re.compile(r"[^a-z0-9]+")


def parse_now(value: str | None) -> float:
    if not value:
        return datetime.now(timezone.utc).timestamp()
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    return datetime.fromisoformat(text).timestamp()


def _text_chunks(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for chunk in content:
        if not isinstance(chunk, dict):
            continue
        if chunk.get("type") == "text":
            parts.append(str(chunk.get("text") or ""))
    return "\n".join(parts)


def _command_from_args(args: Any) -> str:
    if isinstance(args, dict):
        return str(args.get("command") or args.get("cmd") or "")
    if isinstance(args, str):
        try:
            parsed = json.loads(args)
        except json.JSONDecodeError:
            return args
        if isinstance(parsed, dict):
            return str(parsed.get("command") or parsed.get("cmd") or "")
        return args
    return ""


def _exit_code(text: str) -> int | None:
    match = EXIT_RE.search(text)
    if match is None:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def _ls_canonical_probe(text: str) -> bool:
    """True iff an `ls` exit-2 toolResult text is a deliberate probe and
    not a swallowed failure (live #794).

    Two shapes count as a probe:

    1. The canonical no-match line is present and the text shows no other
       ls error. The canonical line is
           ls: cannot access '<path>': No such file or directory
       (GNU coreutils and busybox) or the BSD/macOS form without quotes
       (ls: <path>: No such file or directory). Real ls errors
       (Permission denied, I/O error, not-a-directory, etc.) keep the
       toolResult as a finding.

    2. The text shows no `ls:` error line at all. This is the
       `ls X 2>/dev/null` shape — the agent explicitly silenced stderr
       and is checking the exit code. It is also a deliberate probe.
    """
    if LS_REAL_ERR_RE.search(text):
        return False
    if LS_CANONICAL_NO_MATCH_RE.search(text):
        return True
    # No canonical probe line and no real ls error: was stderr silenced?
    # If the text contains any `ls:` error line (other than the canonical
    # one), it is a real error we did not pattern-match. Be conservative
    # and keep the toolResult as a finding.
    if re.search(r"\bls(?:\(\d+\))?:\s", text):
        return False
    return True


def _git_canonical_probe(text: str) -> bool:
    """True iff a `git log|rev-parse|show|diff|cat-file` exit-128
    toolResult text is a deliberate ref-existence probe and not a
    swallowed failure (live #822).

    Two shapes count as a probe:

    1. The canonical no-ref line is present and the text shows no other
       git fatal / permission error. The canonical line is
           fatal: ambiguous argument '<ref>': ...
       (modern git) or
           fatal: bad revision '<ref>'
       (older git). Real git errors (not a git repository, unable to
       access, repository not found, bad config, Permission denied,
       etc.) keep the toolResult as a finding.

    2. The text shows no `fatal:` line at all. This is the
       `git log <ref> 2>/dev/null` shape — the agent explicitly silenced
       stderr and is checking the exit code. The non-zero exit on
       `git log` with stderr silenced means the ref does not exist; that
       is a deliberate probe.
    """
    if GIT_REAL_ERR_RE.search(text):
        return False
    if GIT_CANONICAL_NO_REF_RE.search(text):
        return True
    # No canonical probe line and no real git error: was stderr silenced?
    # If the text contains any `fatal:` line we did not pattern-match,
    # treat it as a real error and keep the toolResult as a finding.
    if re.search(r"\bfatal:\s", text):
        return False
    return True


def _systemctl_status_failed(command: str, text: str) -> bool:
    """True if the command is `systemctl status <unit>` and the output
    shows a failed unit (`× unit ... Active: failed`).

    This catches the piped-through-head case where isError is false
    because `head` exits 0, but the unit is actually failed
    (fleet-ops#879). It does not flag a successful
    `systemctl --user --failed` listing (no `status` in the command) or
    `systemctl status` of an active/running unit.
    """
    if not SYSTEMCTL_STATUS_RE.search(command):
        return False
    return bool(SYSTEMCTL_FAILED_RE.search(text))


def is_benign_no_match(command: str, text: str, code: int | None) -> bool:
    if code is None:
        return False
    if TIMEOUT_RE.search(text):
        return False
    if REAL_ERR_RE.search(text):
        return False
    # ls(1) exit 2 with the canonical "no such file or directory" probe
    # line — or no ls error at all (e.g. `ls X 2>/dev/null`) — is a
    # deliberate probe, not a swallowed failure (live #794). Real ls
    # errors (permission, I/O, etc.) are still flagged.
    if LS_BENIGN_RE.search(command) and code == 2:
        return _ls_canonical_probe(text)
    # git ref-existence probe (live #822): `git log|rev-parse|show|diff|
    # cat-file <bad-ref>` exits 128 with `fatal: ambiguous argument` (or
    # `fatal: bad revision` on older git) on stderr. Agents routinely
    # run this with `2>/dev/null` to test whether a branch/tag/remote
    # ref exists without spamming the user. Treat that exit-128 with
    # the canonical probe line — or no `fatal:` line at all (silenced
    # stderr) — as a deliberate probe. Other `fatal:` lines (not a git
    # repository, unable to access, repository not found, etc.) remain
    # real failures.
    if GIT_BENIGN_RE.search(command) and code == 128:
        return _git_canonical_probe(text)
    # xargs wrapping a benign search command (live #942): `xargs grep/rg/diff`
    # exits 123 when the inner command exits 1-125. For grep/rg/diff exit 1 is
    # POSIX no-match, so xargs 123 is the no-match signal propagated through
    # the wrapper. REAL_ERR_RE (checked above) still guards against real
    # errors in the text; `xargs rm`/`xargs chmod` exiting 123 does not match
    # XARGS_BENIGN_RE and stays a real failure.
    if code == 123 and XARGS_BENIGN_RE.search(command):
        return True
    if code != 1:
        return False
    return BENIGN_STAGE_RE.search(command) is not None


def result_failed(
    msg: dict[str, Any], command: str, had_prior_block: bool = False
) -> tuple[bool, str]:
    text = _text_chunks(msg.get("content"))
    if HARNESS_BLOCK_RE.search(text):
        return False, text
    if msg.get("toolName") == "read" and READ_OFFSET_RE.search(text):
        return False, text
    # No sibling exemption belongs here for `read` EISDIR
    # (fleet-ops#1170 / #1243, "EISDIR: illegal operation on a
    # directory, read"). That is a real swallowed failure: the path
    # was a directory. tests/fleet-failed-command-read-eisdir.test.sh
    # goes red if an exemption is added here.
    # No sibling exemption belongs here for the `edit` tool. All FOUR
    # edit-failure shapes are real swallowed failures, not negative
    # results: "Could not find the exact text" (0 matches, fleet-ops#956
    # / #965), "Found N occurrences" (many matches, fleet-ops#1053),
    # "Could not find edits[0] in <path>" (multi-edit array, stale
    # oldText on the first element, fleet-ops#1173),
    # "No changes made ... The replacement produced identical content"
    # (matched, but the intended change never landed, fleet-ops#1139),
    # and the schema-validation class
    # "Validation failed for tool \"edit\": - path: must have required properties path"
    # (harness rejected the call before dispatch
    # because the arguments omitted a required top-level field,
    # fleet-ops#1286, live 01a043c8). The no-op shape is the tempting
    # one — it reads as harmless — but the worker believed the file
    # changed and it did not. The schema-validation shape is tempting
    # on the same theory ("the call never ran, the file is fine") —
    # but the worker believed the edit ran and it did not, exactly
    # the same class as the #1139 no-op and the #956 stale-oldText
    # siblings. tests/fleet-failed-command-edit-unmatch.test.sh goes red
    # if an exemption is added for any of these shapes; the
    # tests/fleet-failed-command-edit-array-unmatch.test.sh and
    # tests/fleet-failed-command-edit-schema-validation.test.sh tests
    # pin the multi-edit and schema-validation siblings.
    # exemption is added here.
    # `systemctl status` of a failed unit can show `× unit` and
    # `Active: failed` even when the command is piped through `head`
    # and isError=false (fleet-ops#879).
    if _systemctl_status_failed(command, text):
        return True, text
    is_error = bool(msg.get("isError"))
    timed_out = TIMEOUT_RE.search(text) is not None
    code = _exit_code(text)
    # Genuine Pi failure always has isError=True: the harness sets it on a
    # non-zero exit or a timeout. Bare TIMEOUT_RE / EXIT_RE matches in
    # successful content are content, not swallowed failures.
    # Live #821 / #848: timeout literal alone (read of source, grep of
    # worker.md, git log of a detector commit).
    # Live #943: exit-code literal alone (git log / git show of a
    # detector commit).
    # Live #987: BOTH literals in one successful
    # `git log --no-merges --format=%B origin/main...HEAD` of detector
    # commits (#929 quotes 'Command timed out', #931 quotes 'Command
    # exited with code 128', subject is the #831 provenance note).
    # The previous guards were mutually exclusive (timeout-only when
    # code is None; exit-code-only when not timed_out), so a body that
    # quoted both strings fell through to timed_out=True and was
    # flagged. Unify: no isError means content.
    # Live #1074: a successful `git show HEAD` (isError=false) whose
    # FULL DIFF output quotes 'Command exited with code', 'Command
    # timed out', and 'fatal:' in the diff content (the worker.md +/-
    # lines embed them). A stale detector version filed #1074 from
    # this session; the isError=false guard already prevents the class.
    # Locked by 6h6/6h7 alongside 6h2/6h4.
    if not is_error:
        return False, text
    # Downstream of a harness block (fleet-ops#677): the spawn-guard refused
    # the heredoc/redirect that would have created the script, so invoking it
    # fails with exit 127 "No such file or directory". The assistant recovers
    # via the write tool. Only exempt when a prior toolResult was a block.
    if had_prior_block and code == 127 and ENOENT_RE.search(text):
        return False, text
    if is_benign_no_match(command, text, code if code is not None else (1 if is_error else None)):
        return False, text
    if is_error or timed_out or (code is not None and code != 0):
        return True, text
    return False, text


def snippet_for(text: str, width: int = 200) -> str:
    chunk = text.replace("\n", " ").strip()
    return chunk[:width]


def session_slug(path: str) -> str:
    stem = os.path.splitext(os.path.basename(path))[0].lower()
    slug = SLUG_RE.sub("-", stem).strip("-")
    return (slug or "session")[:80]


def scan_session(path: str) -> dict[str, str] | None:
    calls: dict[str, str] = {}
    pending: list[str] = []
    had_harness_block = False
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msg = obj.get("message")
                if not isinstance(msg, dict):
                    continue
                role = msg.get("role")
                content = msg.get("content")
                if role == "assistant":
                    if isinstance(content, list):
                        for chunk in content:
                            if not isinstance(chunk, dict):
                                continue
                            if chunk.get("type") == "toolCall":
                                cid = str(chunk.get("id") or "")
                                if cid:
                                    calls[cid] = _command_from_args(chunk.get("arguments"))
                    text = _text_chunks(content)
                    if pending and FLAG_RE.search(text):
                        pending.clear()
                elif role == "toolResult":
                    tid = str(msg.get("toolCallId") or "")
                    command = calls.get(tid, "")
                    result_text = _text_chunks(msg.get("content"))
                    if HARNESS_BLOCK_RE.search(result_text):
                        had_harness_block = True
                    failed, text = result_failed(
                        msg, command, had_prior_block=had_harness_block
                    )
                    if failed:
                        pending.append(snippet_for(text or command or msg.get("toolName") or "tool"))
    except OSError:
        return None
    if not pending:
        return None
    return {
        "slug": session_slug(path),
        "path": path,
        "snippet": pending[0],
    }


def iter_session_files(root: str) -> list[str]:
    out: list[str] = []
    if not os.path.isdir(root):
        return out
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".jsonl"):
                out.append(os.path.join(dirpath, name))
    out.sort()
    return out


def scan(
    root: str,
    now: float,
    window_hours: float,
    grace_minutes: float,
) -> dict[str, Any]:
    window_s = max(0.0, float(window_hours)) * 3600.0
    grace_s = max(0.0, float(grace_minutes)) * 60.0
    findings: list[dict[str, str]] = []
    scanned = 0
    skipped_old = 0
    skipped_grace = 0
    skipped_unreadable = 0
    skipped_grace_slugs: list[str] = []
    skipped_old_slugs: list[str] = []

    for path in iter_session_files(root):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            skipped_unreadable += 1
            continue
        age = now - mtime
        slug = session_slug(path)
        if age > window_s:
            skipped_old += 1
            skipped_old_slugs.append(slug)
            continue
        if age < grace_s:
            skipped_grace += 1
            skipped_grace_slugs.append(slug)
            continue
        scanned += 1
        finding = scan_session(path)
        if finding is not None:
            findings.append(finding)

    return {
        "findings": findings,
        "scanned": scanned,
        "skipped_old": skipped_old,
        "skipped_grace": skipped_grace,
        "skipped_unreadable": skipped_unreadable,
        "skipped_grace_slugs": skipped_grace_slugs,
        "skipped_old_slugs": skipped_old_slugs,
        "root": root,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    scan_p = sub.add_parser("scan", help="scan Pi session JSONL for swallowed failures")
    scan_p.add_argument("--root", required=True)
    scan_p.add_argument("--now", default="")
    scan_p.add_argument("--window-hours", type=float, default=24.0)
    scan_p.add_argument("--grace-minutes", type=float, default=20.0)
    args = parser.parse_args(argv)

    if args.cmd == "scan":
        report = scan(
            root=args.root,
            now=parse_now(args.now or None),
            window_hours=args.window_hours,
            grace_minutes=args.grace_minutes,
        )
        json.dump(report, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
