# Design: reset-per-job (ephemeral) self-hosted runners

Status: proposal. This document is the only change in its PR. It changes
nothing on any host, and no runner behaves differently after it merges.

Issue: #10041.

## Why

GitHub recommends a clean environment for every job on a self-hosted runner.
Today a runner stays registered and takes job after job in the same directory
with the same user state. The stock way to get one job per runner is an
ephemeral runner, and this document describes how to use it with the systemd
units the fleet already has. It is stock features only: no new script, no
poller, no wrapper.

## Where we are today

- 26 self-hosted runners run on the one fleet host. Each is a system unit named
  `actions.runner.<scope>.<runner-name>.service`, created by the runner's own
  `svc.sh install`.
- The pools:

  | Pool | Units | Registered to | Labels (as listed by the API) |
  |---|---|---|---|
  | agent | `netcup-agent-1..22` | org runner group `agent` (id 3) | `self-hosted`, `agent`. Ten of the 22 also carry `linux`, `x64`. |
  | fleet-ci | `netcup-fleet-ci-1..3` | org, `fleet-ci-3` in the restricted group `drive-eval` | `self-hosted`, `linux`, `x64`, `fleet-ci` |
  | vault | `netcup-vault-1` | one repository outside the org | not covered here |

- Registration was done once by hand with `config.sh`. A runner stays
  registered until someone removes it. The unit's `ExecStart` is the runner's
  own `runsvc.sh`, and the runner directory holds its registration and its
  `_work` directory.
- The units are shaped by drop-ins under
  `rootfs/etc/systemd/system/actions.runner.<scope>.<name-prefix>-.service.d/`.
  `10-*.conf` sets the memory limits, `Restart=on-failure` and the slice.
  `20-lockdown.conf` hides paths from jobs. Some runners have a further
  numbered file (`25-no-eval.conf`, `30-eval.conf`, `40-egress.conf`).
- A job's `_work` directory, tool cache and any files it writes in the runner's
  home persist on disk until something deletes them.

## Target lifecycle

One cycle per runner unit, repeated forever:

1. The unit starts. A pre-start step registers the runner as ephemeral, with
   the same name, group and labels as today.
2. `runsvc.sh` starts and the runner listens for work.
3. GitHub assigns exactly one job to it. GitHub's docs say an ephemeral runner
   is de-registered after one job.
4. The job ends and the runner process exits. The runner record is gone from
   GitHub.
5. systemd stops the unit and discards the job's private file systems (see
   "Where the reset happens").
6. `Restart=always` starts the unit again, which is step 1. The replacement is
   a new registration, so it shares nothing with the previous job.

### Stock pieces

- `config.sh --ephemeral` is in the runner. GitHub documents it on the
  autoscaling page: "include the `--ephemeral` parameter when registering your
  runner".
  https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners
- Names, group and labels: `config.sh --unattended --name <name>
  --runnergroup <group> --labels <labels> --replace`. `--replace` takes over a
  stale record of the same name, so an orphan does not block the next start.
  Where today's runner has no default labels, add `--no-default-labels` so the
  label set stays identical.
- The registration token. `config.sh` accepts `--pat <token>` and then asks
  GitHub for a registration token itself, through the org endpoint
  `POST /orgs/{org}/actions/runners/registration-token`. That means the
  mint step is part of `config.sh`, so it needs no script. This is in the
  runner source (`ConfigurationManager.GetRunnerTokenAsync`), but the runner's
  `--help` text describes `--pat` only for `--check`. Step 0 of the rollout
  proves it on one runner before anything else depends on it. If it does not
  work, the fallback below applies.
- Restart: `Restart=always` in a drop-in. systemd documents that an exit with
  status 0 does not restart under `on-failure`, and an ephemeral runner exits
  cleanly after its job, so `always` is needed.
  https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- The pre-start commands are plain `ExecStartPre=` lines in a drop-in that call
  `config.sh` directly. A leading `-` on a line (`ExecStartPre=-... remove
  --local`) clears a leftover local registration after a crash, and the next
  line registers again.

The unit names stay the same, so every existing drop-in prefix keeps applying.
The change is one new drop-in per pool (for example `30-ephemeral.conf`) and
nothing else.

### Fallback: just-in-time (JIT) configuration

GitHub has a second stock route. `POST /orgs/{org}/actions/runners/generate-jitconfig`
returns `encoded_jit_config`, and the runner is started with
`run.sh --jitconfig <encoded_jit_config>`. The body takes `name`,
`runner_group_id` and `labels` (all required, 1 to 100 labels) and an optional
`work_folder` (default `_work`). The runner is ephemeral and registered by the
API call, so `config.sh` is not run at all. The caller needs admin access to
the org (classic token scope `admin:org`).
https://docs.github.com/en/rest/actions/self-hosted-runners

`--jitconfig` is an argument of the runner's `run` command (see
`Constants.Runner.CommandLine.Args.JitConfig` in
https://github.com/actions/runner). The API page itself says only that the
config "can be passed to the runner application at startup".

The cost: systemd cannot pass the output of one `ExecStartPre=` line to
`ExecStart=`. Joining the API call to `run.sh` needs a small wrapper or a shell
one-liner in the unit, and the fleet quality bar counts that as glue. So JIT is
the fallback only if `config.sh --pat` is not usable, and it then needs an
explicit decision before anything is built.

### Considered: Actions Runner Controller and scale sets

GitHub calls ARC "the recommended Kubernetes-based solution for autoscaling
self-hosted runners", and the same page points to a standalone scale set client
for use outside Kubernetes.
https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners

Against it here: the fleet runs on one host with no Kubernetes, ARC would add a
cluster to run and secure, and the standalone client is a program we would have
to write and maintain. For it: it is the maintained path if the runners ever
move to a cluster. Decision for now: not used. The systemd route reuses the
units that exist.

## Where the reset happens

The aim is that nothing a job writes is visible to the next job. Use systemd's
own isolation, so the reset is the unit stopping and not a clean-up command:

| State | How it resets |
|---|---|
| Work directory (`_work`, which holds checkouts) | A tmpfs over `_work` (`TemporaryFileSystem=`). It is discarded when the unit stops. It counts against the unit's `MemoryMax`, so it needs a size cap. If checkouts are too large for that, a disk directory the unit owns is the alternative, and it needs a decision on how it is emptied. |
| Tool cache (`RUNNER_TOOL_CACHE`, under `_work/_tool` by default) | Lives inside the work directory, so it resets with it. |
| `/tmp` and `/var/tmp` | `PrivateTmp=yes`. |
| The runner's home directory | A tmpfs over the home directory with explicit `BindPaths=` for what the pool needs. `fleet-ci-3` already works this way. |
| Credentials on disk | Not a separate case. A credential a job should not read is hidden by the lockdown drop-in as today. A credential that is written during the job lives in a path under the tmpfs mounts above, so it goes away at stop. |
| Runner registration files | `config.sh` writes them at each start and the runner removes them after the job. |

What is not reset, on purpose: package caches that are bound in read-write
(for example the npm and pip caches on `fleet-ci-3`). They save minutes per job
and they remain shared between jobs. If a pool does not need one, do not bind
it.

## Token handling

- Who mints: the runner itself, through `config.sh --pat`, at each start. No
  other process mints a token.
- Scope: the smallest that GitHub accepts for the org registration-token
  endpoint, which is org admin access (classic scope `admin:org`). A GitHub App
  with the "Self-hosted runners" organization permission set to write is
  preferred if the runner can take an App token, and that is part of Step 0.
- Lifetime: the registration token GitHub returns is valid for one hour and
  is used once. The long-lived credential that mints it is the one that
  matters. It must be a credential for this purpose only, held outside the
  repo, and stored where job code does not read it. Where exactly it lives is
  decided together with the work that moves runners onto separate users. This
  design does not widen what any job can read.
- It is never printed, never written to the repo and never put in a workflow.

## Trade-offs

- Start-up latency: each job waits for a registration round trip and a runner
  start before it is picked up, a few seconds in the normal case. The runner
  also checks for a newer version when it starts, which can add time on the
  first start after a release.
- Throughput during the gap: a runner is not available between one job ending
  and its replacement registering. With 22 agent runners the effect is small,
  and the Step 3 check measures it.
- Cache loss: checkouts, tool downloads and anything else in the work
  directory are fetched again every job. The expected cost is the clone time
  and the setup-action downloads. Bound package caches soften this.
- API rate limits: one registration call per job, which is far below the REST
  limit for an authenticated caller at the current job volume.
- Disk and memory: a tmpfs work directory is paid for in memory. A disk
  work directory is paid for in write volume. Pick per pool after measuring.
- Failure modes:
  - A runner registers and no job ever arrives. It sits idle and registered.
    GitHub removes an ephemeral runner that has not connected for more than
    one day.
    https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/removing-self-hosted-runners
  - The token call fails (the credential expired, GitHub is unreachable). The
    pre-start step fails, `Restart=always` retries after `RestartSec`, and the
    runner is absent until it succeeds. A failing unit is visible in
    `systemctl` and through the existing `fleet-unit-failed@` hook. Set
    `StartLimitIntervalSec=0` so a long outage does not leave the unit stuck.
  - The runner dies mid-job. The job fails, the record is removed by GitHub
    or replaced by `--replace`, and the unit restarts.
  - Orphan records of the same name. `--replace` covers the same-name case,
    and the Step 4 check lists any leftover.
  - GitHub's hardening guide notes there is no way to guarantee that a
    self-hosted runner runs only one job, so the design leans on the
    unit-level reset above and not on the runner alone.
    https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions

## Rollout

Each step has a check, and the next step starts only when the check passes.
Take a runner out of service by stopping its unit while the job it holds
finishes. Runner names below are examples.

0. **Prove the registration path on a scratch runner, not a pool runner.** On a
   spare runner directory, run `config.sh --unattended --ephemeral --replace
   --pat ...` against the org. Check: the runner appears in
   `gh api orgs/Nishfleet/actions/runners` with the expected labels, takes one
   test job, and then is gone from the list. If it does not, stop and take the JIT fallback to a
   decision.
1. **One runner, one job.** Add the drop-in for one agent runner (for example
   `netcup-agent-22`) in a PR. After deploy and a restart of that unit, check:
   - the runner shows `online` in `gh api orgs/Nishfleet/actions/runners` with
     the same labels as before (the list does not report an ephemeral flag, so
     the proof of one-job-only is the next two lines);
   - it takes exactly one job, and the job's `runs-on` matched through the
     labels (run URL recorded);
   - after the job it is gone from `gh api orgs/Nishfleet/actions/runners`;
   - within a minute a new record with the same name is `online`;
   - the work directory and home directory of the new run are empty of the
     previous job's files (`ls` of the runner's `_work` shows no checkout).
2. **Repeat on the same runner for a day.** Check: no job that missed its
   runner, `systemctl show -p NRestarts` equals the number of jobs, and the
   registration call count stays near the job count.
3. **Widen to a few agent runners.** Check: queue wait time for the agent label
   in the run list stays near the baseline, and memory use of `agent.slice` does
   not rise past the headroom (tmpfs work directories count).
4. **Widen to the rest of the agent pool, then fleet-ci.** Check: the API lists
   as many online agent runners as units, and no offline duplicate names.
   `fleet-ci-3` and the vault runner need their own look because of their
   restricted group and repository scope.

## How to switch it off

Revert the one PR that adds or widens the drop-ins. After the deploy, restart
the affected runner units. The old `ExecStart` and `Restart=on-failure` apply
again. Because a reverted unit starts without the pre-start step, run
`config.sh remove --local` (only if a leftover local registration exists) and
then `config.sh --unattended` without `--ephemeral`, once for each runner that
was already converted, to put back a standing registration. The Step 1 PR keeps
that to a single runner, and the later steps keep the same revert shape.

This design PR changes nothing live, so merging it needs no rollback.

## Open questions for the build PR

- Does `config.sh --pat` accept an App installation token, or only a PAT? (Step 0)
- Memory or disk for `_work`, per pool.
- Where the minting credential is stored, so that job code cannot read it.
- Whether the vault runner (registered outside the org) joins at all.
