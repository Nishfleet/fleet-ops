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
`read` tool returning ENOENT / EACCES (fleet-ops#651, #664, #953, fleet-ops#958, #972, #967, #977, #1001, #1059) is a
real swallowed failure: it is not a probe like ls no-match or read
offset beyond end. #972 is the same session shape as #958 (the
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
that. The auto-filed issue closes via observe-to-close when the session
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
the intended change did NOT land) —
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
tests/fleet-failed-command-edit-unmatch.test.sh pins the single-edit,
multi-match, and no-op shapes; tests/fleet-failed-command-edit-array-
unmatch.test.sh pins the multi-edit array `edits[0]` shape
(fleet-ops#1173). #970 is the same session shape as #956 / #965 (the
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
A `gh issue view <N> -R ... --body` command is not valid: `gh issue view`
has no `--body` flag, so it exits 1 with `unknown flag: --body` and the
full usage help (fleet-ops#1055, session
2026-08-27T07-15-49-602Z_01a04213-32e2-7409-a4ba-bd86f12ad936). The
assistant's next turn was empty (model provider 503 errors) and later
toolCalls did not name the failure. It is not a GraphQL transient error
(fleet-ops#678) or a no-match probe; it is a real swallowed failure and
must be flagged. The dedicated regression test locks it under
tests/fleet-failed-command-gh-issue-view-body.test.sh.
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
prompt, or the test host list is caught. A `git checkout <branch>` (or a
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
A spawn-guard or harness block (SPAWN_BLOCKED
/ "Dangerous command blocked") is not a ran-and-failed command: the call
never executed.

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
# Unquoted assistant report. Tight on the standing-rule verbs.
FLAG_RE = re.compile(
    r"(failed|fails|failing|failure|\berror\b|non-zero|exited with|"
    r"timed out|timeout|blocker|not found|\b404\b|\b50[0-9]\b|"
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
# Do NOT add a similar exemption for `edit` "Could not find the exact
# text" (fleet-ops#956, #965, #970, #975, #980), "Found N occurrences"
# (fleet-ops#1053, same edit-unmatch class: oldText matched multiple
# locations, not zero), or "No changes made ... The replacement produced
# identical content" (fleet-ops#1139, same class: the edit matched but the
# intended change never landed). Those are real swallowed failures: the
# worker's oldText or newText was stale. A silent read/grep recovery, and
# cause-explaining prose ("The text is already the same"), do not
# discharge it.
READ_OFFSET_RE = re.compile(
    r"Offset \d+ is beyond end of file \(\d+ lines total\)", re.I
)
# Downstream of a harness block (fleet-ops#677): the spawn-guard refused the
# heredoc/redirect that would have created a script, so a later `bash <path>`
# fails with exit 127 "No such file or directory". The assistant recovers via
# the write tool. That ENOENT is a cascade of the block, not a swallowed
# command failure. Only exempt when a prior toolResult in the session was a
# harness block — a 127 ENOENT with no prior block is a real failure.
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
    # No sibling exemption belongs here for the `edit` tool. All three
    # edit-unmatch shapes are real swallowed failures, not negative
    # results: "Could not find the exact text" (0 matches, fleet-ops#956
    # / #965), "Found N occurrences" (many matches, fleet-ops#1053), and
    # "No changes made ... The replacement produced identical content"
    # (matched, but the intended change never landed, fleet-ops#1139).
    # The no-op shape is the tempting one — it reads as harmless — but the
    # worker believed the file changed and it did not.
    # tests/fleet-failed-command-edit-unmatch.test.sh goes red if an
    # exemption is added here.
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
