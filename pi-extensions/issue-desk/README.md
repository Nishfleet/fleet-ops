# issue-desk

The Pi extension behind `issue-desk`, the Agent Tincan teammate that turns a request from another agent into exactly one queued GitHub issue and answers the request with its URL.

It is the whole of what that agent can do. `systemd/tincan-listen-issue-desk.service` starts Pi with `--no-builtin-tools --no-extensions --no-mcp --no-skills --no-context-files --no-prompt-templates`, so the model has no shell, no file tools and no network of its own: only the three tools below. A fooled model can file a bad product issue, and nothing else.

Stock Pi extension point only: `pi.registerTool` in `index.ts`, no wrapper, no poller, no script. The wake is the vendor's own `tincan listen --exec`. Its command runs through `sh -c` (per `tincan listen --help`), so the unit's wake line is plain sh: it exits at once while `TINCAN_WAITING` is zero - a relay upgrade nudge can fire with nothing waiting, and waking the model then buys a paid call for nothing - and otherwise runs `timeout 600` around pi, so one stuck model call cannot run on. The only runtime import the extension needs beyond node builtins is `typebox`; it resolves without any install because Pi loads extensions through its jiti loader, which falls back to Pi's own install tree, and Pi depends on `typebox` directly. The devDependency here pins the version for type-checking and tests only.

## The three tools

| tool | what it does |
| --- | --- |
| `tincan_inbox` | runs `tincan inbox --json` and lists the requests waiting in this run: `request_id`, sender, chain and text. Requests already listed in this run are shown once, as ids only. |
| `file_issue` | files one `needs-triage` issue in one allowlisted repo and returns its URL. |
| `tincan_reply` | answers one request from this run with one text. |

## What stops a bad issue

- **Repo allowlist.** `file_issue` re-reads `config/intake-repos.json` on every call and accepts only `product: true` repos, by bare name. `fleet-ops` is refused by name even if that file ever lists it: control-plane work enters as a scoped packet, never as a stranger's request.
- **The request must exist.** `request_id` must be one `tincan_inbox` returned in this process, and its sender must be in `ISSUE_DESK_SENDERS`. A made-up id or an unknown sender files nothing. The request id, the sender and every `chain` entry are read from relay JSON, so each must be a plain name of letters, digits, dot, dash or underscore, 64 characters at most: anything else (a newline, a space, a `:`-prefixed line) files nothing, because it could forge the footer lines a later sweep trusts.
- **Admission stays in charge.** `file_issue` adds `needs-triage` and nothing else. The `admit` job in `.github/workflows/agent-dispatch.yml` reads that label, bands money, privacy, security, legal and customer-data work to `needs-orchestrator`, and asks Jev about the rest. A stranger's request can therefore never start a worker on its own, and the desk never writes `agent-ready`.
- **Command lines in a request are quoted, never passed on.** The model writes the body, so the extension rewrites every line that starts (after spaces, markdown such as `>`, `*`, `` ` ``, `+` or `|`, or a numbered-list marker such as `1.` or `2)`) with a colon prefix the fleet's own tooling parses - `due:`, `blocked-on:`, `decision-resolved:`, `park:`, `opus-vet:`, `attempt-cap reset:`, `agent run started:`, `agent run infra-failed:`, `agent run failed:`, `stuck-pr:`, `red-main:`, `red-main-run:` - into `[quoted] <line>`, and quotes its own footer prefixes (`tincan-request:`, `requested-by:`, `relayed-by:`, `chain:`) the same way. The title is quoted the same way. A request that carries `due: 2026-10-23 09:00 IST` files an issue whose body says `[quoted] due: ...`, which nothing in the fleet parses as a command.
- **`needs-triage` holds a request still.** `systemd/later-sweep.service` promotes an overdue `due:` line to `agent-ready` only when the issue holds none of the parked labels, and `needs-triage` is in that list: a relayed request waits for the admit job's Jev verdict even if its text carries a past `due:` line. The footer also names the relay (`relayed-by: issue-desk (not written by Nish)`) so no reader mistakes the text for Nish's writing.
- **One issue per request.** A filed request is recorded in `filed.jsonl` in the state directory, and every issue body ends in the code-written footer `tincan-request: <id>` / `requested-by: <sender>` / `relayed-by: ...` / `chain: <trail>`; a body counts as this desk's only when those four lines are its last lines. A second call returns the same URL instead of filing again, and a fresh process finds the issue by searching the repo for that exact marker line. The record is written before `gh` runs, so a process that dies mid-create leaves a claim with no url. A retry inside ten minutes refuses rather than risk a second issue. After ten minutes the retry searches the repo named in the claim for the marker: a hit records that URL and returns it, and a miss allows exactly one new create. The read-search-append-create sequence runs under an exclusive lockfile (`filed.lock`, created `O_EXCL`, released by token check) in the same state directory, so two wake processes cannot interleave. A lock older than five minutes is displaced through a rename to a unique name and then re-read: the steal stands only when the renamed file still holds the token the waiter saw as stale, and otherwise the lock is linked back and the waiter waits, so a lock that another process created between the look and the rename is never taken. If a third process takes the lock path in the moment the stale lock is being linked back, the filing refuses with a retry message instead of running beside the missing holder. A claim with an empty url counts toward the cap: `gh` may have created the issue even when the create call failed.
- **A daily cap.** `ISSUE_DESK_MAX_PER_DAY` distinct requests per rolling 24 hours, counted from `filed.jsonl` claims and successes alike.
- **Size limits.** The title is one line of at most 120 characters, the body is at most 8000 including the footer that names the request, and a reply is at most 1000 characters after command lines are quoted. Each limit refuses the call rather than truncating, so nothing is filed or sent half-written. A skipped test fails `tests/test_issue_desk.py`, which reads vitest's summary line and requires every test to pass.
- **No shell, no paths.** Every child process is `execFile` with an argument array and `shell: false`. No tool takes a command, a path or a flag.

The request text is data. The prompt tells the model so, and the tools give it no way to act on an instruction inside a request beyond filing an issue about it.

## Configuration

The unit sets these. Every one has a default in `src/config.ts`.

| variable | default |
| --- | --- |
| `ISSUE_DESK_SENDERS` | `muse,instinct,tether,hermes` |
| `ISSUE_DESK_MAX_PER_DAY` | `10` |
| `ISSUE_DESK_REPO_ROOT` | the deploy clone, which holds `config/intake-repos.json` |
| `ISSUE_DESK_STATE_DIR` | `STATE_DIRECTORY` from the unit, else the working directory |
| `ISSUE_DESK_TINCAN` | `tincan` |
| `ISSUE_DESK_GH` | `gh` |

`tincan` finds its identity through `TINCAN_CONFIG`, which the unit sets. `gh` is the host's own login, so the unit is not jailed: the model cannot run `gh` itself, only the fixed argument arrays above.

## Tests

```
npm ci
npm test
```

91 tests, no network: a scripted runner stands in for `gh` and `tincan`, and a fake Pi records the registered tools. They cover the allowlist, `fleet-ops`, unknown request ids, senders outside the list, both idempotency paths, the ten-minute stale-claim recovery (marker found, marker absent, and a claim naming a repo the desk may not search), relay ids that carry a newline, the rolling cap (claims included), the size limits for title, body and reply, a failed `gh`, command-line quoting in the body and the title (including a long run of decoration before the marker), the footer marker, the cross-process lockfile (two child processes, stale recovery, a stale lock that a second process already replaced, token-guarded release), and that exactly three tools are registered and no tool takes a command or a path.

`tests/test_issue_desk.py` in the repo root runs them in CI and checks the unit's flags, so a later edit that adds a tool-loading flag or drops `--no-builtin-tools` fails `ci`.

## Switch off, delete

```
systemctl --user disable --now tincan-listen-issue-desk.service
```

Requests to `issue-desk` then queue on the relay until someone checks its inbox. To delete it: switch it off, `systemctl --user unlink tincan-listen-issue-desk.service`, then remove this directory, `systemd/tincan-listen-issue-desk.service`, `prompts/issue-desk.md` and `tests/test_issue_desk.py` in a PR. Nothing else reads them, and the agent's identity file under `~/.config/tincan/` is a hand-placed host file, not a repo file.

