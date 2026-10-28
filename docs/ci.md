## CI

`.github/workflows/ci.yml` calls one workflow file per area (`ci-lint.yml`, `ci-systemd.yml`, `ci-unit.yml`, `ci-simulations.yml`, `ci-grafana.yml`, `ci-tofu.yml`), each one job with its own timeout, on every PR and every merge-queue entry. The one required check `ci` runs no tests and needs every other job. pytest finds every `tests/test_*.py` itself (`pytest.ini`); a test that needs another job's setup carries a marker named there, so a new test never edits a workflow. Its
checks are stock: the secret-expansion grep,
`jq` config sanity, actionlint, zizmor, shellcheck, and systemd-analyze verify
over `systemd/`. The stock linters are joined by repo-specific gates: a no-glue
semgrep rule at `.semgrep/no-glue.yml`, a no long-lived personal-access-token
(PAT) grep, `nft -c` over `rootfs/etc/nftables.conf`, `ansible-playbook --syntax-check` over `ansible/host.yml` and `ansible/update.yml`, a no shell `${...}` or bare
`%s/%u/%h` check inside systemd Exec lines (fleet-ops#8382), pi seat ids
resolving to `config/litellm-proxy.yaml` `model_name` (fleet-ops#8332), and
Ollama rungs serving only the permitted slug on the native provider
(fleet-ops#8332, fleet-ops#9253), the Claude Code managed-settings drop-ins
(each file under `rootfs/etc/claude-code/managed-settings.d/` is a JSON object
and every `autoMode` array keeps `"$defaults"`, and
`tests/test_claude_managed_settings.py` adds that every enabled plugin id names a
marketplace the box knows), the litellm-proxy
schema gate: `config/litellm-proxy.yaml` must validate against
`config/litellm-proxy.schema.json`, and every
`config/litellm-proxy.schema.rejects/*.yaml` must fail the same check
(fleet-ops#8653), so a loosened schema goes red.

### Ratchet: workflow and script code only shrinks

The `ratchet` job in `ci.yml` calls `.github/workflows/ratchet.yml`, the one definition of the rule. It fails a PR whose net added lines (additions minus
deletions, `git diff --numstat` against the merge base) under `.github/workflows/`,
`.github/actions/`, `scripts/` and `bin/` are greater than 0. A PR that adds lines must delete at least
as many, so removing glue earns room. There are no exceptions in this repo: a new
mechanism is a component in its own repo, behind an official extension point. The job
self-tests on throwaway repos every run (growing fails; shrinking and an in-place edit pass).

When a value must rise rather than the code grow — a spend ceiling, a budget, a timeout — make
it a repository variable read through `vars` with the reviewed default still in the file:
`EVAL_MAX_NEURONS: ${{ vars.EVAL_MAX_NEURONS || '2000' }}`. Setting it is then a settings change
(Settings → Secrets and variables → Actions → Variables), not a diff, and the reviewed default in
the file is the record, because a variable is not versioned: the same commit can run under a
different ceiling on two days, so the default and the daily ceiling behind it are what a reviewer
reads. A `workflow_dispatch` input cannot do this job, because the `inputs:` block is workflow
lines the ratchet counts. An `inputs:` exemption was proposed on fleet-ops#10054 and refused for
two reasons: it is hand-rolled YAML parsing in the one program the fleet wants airtight, and it
would make every added input default free, a money ceiling included. 0509's eval ceiling is the
first user (fleet-ops#10054).

A web or product repo adds a workflow with one job named `ratchet` that calls
`uses: Nishfleet/fleet-ops/.github/workflows/ratchet.yml@main` on `pull_request` and `merge_group`,
and requires the check `ratchet / ratchet` in its ruleset. Run from `@main`, the rule is
the base branch's, not the PR's; and a PR that edits the caller's `ratchet` job fails the check.
Not covered, because the Free plan has no org required workflows or org rulesets (the API answers
403, and a repository ruleset `workflows` rule is rejected): a PR can still repoint the caller's
`uses:` at another repository (fleet-ops#9627). Pin `@main`, never a SHA: the `agent` runner group allows
only `@main`, and a SHA pin queues forever. The check is in `ci`'s `needs` and in the `main-merge-queue`
ruleset's required status checks as `ratchet / ratchet`. To switch it off, remove that
context from the ruleset (Settings, Rules, `main-merge-queue`) and from `ci`'s `needs`. Deleting
the job alone does not switch it off: a required check that never reports blocks the PR.

`.github/workflows/secret-scan.yml` is the gitleaks scan (pinned binary +
sha256, `--redact`). fleet-ops has no deploy target. All actions are pinned to exact commit
SHAs. `agent.yml`, `ci.yml`, `deploy-box.yml`, `lighthouse.yml` and
`secret-scan.yml` set `timeout-minutes` on their jobs. `agent-dispatch.yml`
sets none. Its `new`, `rework`, `ejected` and `unblocked` jobs
call `agent.yml` through `uses:` and inherit its limits, while its `list` and `close-claim`
jobs run their own steps on `ubuntu-latest` with no `timeout-minutes`.

A job that calls `agent.yml` must grant every scope its jobs ask for, at or above the level asked. A
caller that grants less kills the whole run at startup with no job and no log, which is how 23 Oct
took the fleet down: `agent.yml`'s `review` job began asking `contents: read`, and all 13 callers in
`agent-dispatch.yml` died until #10194 landed the grant (fleet-ops#10192).
`tests/test_workflow_caps.py` reads every workflow under `.github/workflows/`, collects what
`agent.yml` asks scope by scope, and fails the PR when any caller grants less. It follows direct
`uses:` callers, which is every caller today. actionlint 1.7.12 and zizmor 1.30.1 both pass on the
broken commit, so this test is the gate.

So a repair PR for a broken dispatcher cannot get the dispatcher's review. `agent.yml` is reachable
only through `workflow_call`, and `agent-dispatch.yml` is its only caller, so while that caller fails
at startup the `review` job never runs. What works is an approver's unedited
`coordinator-approval: <head sha>` comment, the line the `coordinator-approval` check and
`hold-risky` read, which is how #10194 landed. `agent.yml`'s `workflow_dispatch` now takes
`review_pr` and `review_sha`, so the reviewer runs by hand from `main` (fleet-ops#10199;
docs/ARCHITECTURE.md has the command), and the deadlock is gone.

`.github/workflows/lighthouse.yml` is the fleet's one Lighthouse speed budget, stock LHCI
assertions in `config/lighthouserc.json` (LCP 1500 ms, interactive 3000 ms, CLS
0.05, script 150 KB, total 500 KB, no console errors; sizes are bytes there,
153600 and 512000). A web repo calls it with
`uses: Nishfleet/fleet-ops/.github/workflows/lighthouse.yml@main` and
`with: urls:` (one page URL per line); callers cannot change the assertions. It no longer prints the LCP breakdown to the step summary (removed to offset the `ratchet` job, fleet-ops#9622); the assertions are unchanged.

