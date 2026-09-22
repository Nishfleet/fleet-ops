# ~/.pi/agent/extensions

**Rule: if pi ships it, symlink it.** Everything here that has a shipped
original is a symlink into
`~/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/`,
so a `pi` upgrade updates it for free. Pi's loader follows symlinks — proved
install method.

Do not replace a symlink with a copy. If a stock file must change, fork it with
a header naming the upstream version and the reason, and list it below.

## 2026-09-18 glue sweep

Deleted, with what replaced each (verified live, not assumed):

| deleted | lines | replaced by |
|---|---:|---|
| `seat-health.ts` | 1,472 | LiteLLM's own `/health/readiness` + `litellm_deployment_state`, already scraped by Prometheus |
| `stop-judge.ts` | 404 | nothing — a stop policy the fleet no longer wants |
| `jev-decide.ts` | 77 | nothing here — Jev is being moved to a LiteLLM pass-through endpoint |
| `packet-verdict.ts` | 89 | `pi-issue@.service` `ExecStopPost`: requires `claim/issue-<n>` on origin, else `Result=failed` (the rail unit's cut, landed d4a42ced6) |

**2,752 lines removed.** The process ceiling is no longer userspace: it is
`systemd.resource-control` `TasksMax=8000` on `fleet-work.slice`, from the
linked drop-in `systemd/fleet-work.slice.d/10-tasksmax.conf`. Proved live:
`systemctl --user show fleet-work.slice -p TasksMax -p DropInPaths`, and locked
by `tests/fleet-work-slice-tasksmax.test.sh`.

`bash-spawn-hook.ts` was NOT symlinked to the stock example. The stock file is
a demo that re-registers the built-in `bash` tool and prepends
`source ~/.profile` to every command — a behaviour change with no fleet purpose,
and the documented cause of `Tool "bash" conflicts with …` startup failures.
Deleting it is strictly less machinery than symlinking it.

## Local files (no shipped original, or a declared fork)

| file | lines | what it does that stock does not |
|---|---:|---|

## Symlinked to stock (upstream pi 0.85.1)

`confirm-destructive.ts`, `dirty-repo-guard.ts`, `handoff.ts`, `notify.ts`,

**`confirm-destructive.ts` cannot gate commands.** It hooks
`session_before_switch` / `session_before_fork` only — session lifecycle, not
bash — and returns early when `!ctx.hasUI`. Command rules belong in
`pi --print` fleet seat.

## What the guards actually guarantee (probed 2026-09-18, litellm/worker-cheap)

* `git stash push -m probe` — **BLOCKED**, `Dangerous command blocked (no UI for
  confirmation)`; stash list stayed empty, working tree untouched.
* `git stash list` — allowed, as intended (read-only).
* `rm -rf /tmp/probe-scratch/doomed` — **BLOCKED**… and then the model achieved
  the same deletion with plain `rm` + `rmdir`, which match no pattern.

**Read that last line before trusting this layer.** Pattern-based command
gating stops the literal command, not the intent, against a model that can
rephrase. It is a guard against accident, not against a determined agent. This
was equally true of the 620-line `spawn-guard-core.ts` it replaces — the rules
there were regexes too. The real controls are the credential paths not being
reachable and the seats being non-interactive.

Also unguarded, unchanged from before: the `devin` and `cursor` shims run the
vendor CLI with its own tools, so pi never sees a bash call and no rule here
fires for those seats.
