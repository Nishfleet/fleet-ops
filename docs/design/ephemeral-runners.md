# Design: reset-per-job (ephemeral) self-hosted runners

Status: pilot. Runner 22 (`netcup-agent-22`) registers as a just-in-time (JIT) runner
at every start (fleet-ops#11960, "Pilot: runner 22" below). The other 29 agent runners
and the review, Claude and deploy runners do not change.

Issue: #10041, #11960 (re-filed from #10153).

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
  | agent | `netcup-agent-1..10` | org runner group `agent` (id 3) | `self-hosted`, `agent` |
  | fleet-ci | `netcup-fleet-ci-1..3` | org, `fleet-ci-3` in the restricted group `drive-eval` | `self-hosted`, `linux`, `x64`, `fleet-ci` |
  | vault (retired 2026-11; its workflows run on GitHub-hosted runners) | `netcup-vault-1` | one repository outside the org | not covered here |

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
5. The unit goes inactive and systemd discards the job's private file systems (see
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
- The registration token (the `--pat` route, not taken: see "Chosen for the pilot"). `config.sh` accepts `--pat <token>` and then asks
  GitHub for a registration token itself, through the org endpoint
  `POST /orgs/{org}/actions/runners/registration-token`. That means the
  mint step is part of `config.sh`, so it needs no script. This is in the
  runner source (`ConfigurationManager.GetRunnerTokenAsync`), but the runner's
  `--help` text describes `--pat` only for `--check`. Step 0 of the rollout
  proved the JIT route instead, which is the one the pilot uses.
- Restart: `Restart=always` in a drop-in. systemd documents that an exit with
  status 0 does not restart under `on-failure`, and an ephemeral runner exits
  cleanly after its job, so `always` is needed.
  https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- Not used for the pilot (see the next section): the pre-start commands as plain
  `ExecStartPre=` lines in a drop-in that call `config.sh` directly. A leading `-` on a line (`ExecStartPre=-... remove
  --local`) clears a leftover local registration after a crash, and the next
  line registers again.

The unit names stay the same, so every existing drop-in prefix keeps applying.
The change is one new drop-in per runner or pool and nothing else.

### Chosen for the pilot: just-in-time (JIT) configuration

Step 0 settled the first open question the other way round from the plan above:
`config.sh --pat` is not used. GitHub's "Secure use reference", section "Using just-in-time
runners", names JIT as the way "to improve runner registration security". With JIT the token
that can register runners never enters a process of the job user; only a one-job config
does. `config.sh --pat` would hand that token to a process every job can read.
https://docs.github.com/en/actions/reference/security/secure-use

`POST /orgs/{org}/actions/runners/generate-jitconfig` returns `encoded_jit_config`. The body
takes `name`, `runner_group_id` and `labels` (all required, 1 to 100 labels; the runner gets
the labels exactly as given) and an optional `work_folder`. The runner is ephemeral and the
API call registers it, so `config.sh` is not run. The runner takes the config from the
environment variable `ACTIONS_RUNNER_INPUT_JITCONFIG`, so the unchanged `runsvc.sh` starts
it and nothing secret is on a command line.
https://docs.github.com/en/rest/actions/self-hosted-runners

Proven on the box on 2026-11-13, on a scratch runner that is now removed:

- A token minted with only the organization "Self-hosted runners" write permission got 201
  from `generate-jitconfig`, and 404 on a private repo's issue and 403 on a repo's secrets
  list. The worker App already holds that permission, so no new credential exists. The
  repo's mint (`config/github-app-token`) takes it from `TOKEN_PERMISSIONS`.
- Started with the config in `ACTIONS_RUNNER_INPUT_JITCONFIG` through `runsvc.sh`, as the
  job user, the runner was online in 5 seconds with the labels asked for.
- A runner stopped before it takes a job leaves its record, and a second request for the
  same name returns 409 "Already exists".

The earlier objection (systemd cannot pass the output of one `ExecStartPre=` line to
`ExecStart=`) is met without a wrapper: the pre-start line writes the config to a root-only
environment file and the unit reads it with `EnvironmentFile=`, which systemd does before
it drops to the job user. `config/github-app-token` and the unit are the only pieces.

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
| Work directory (`_work`, which holds checkouts) | A tmpfs over `_work` (`TemporaryFileSystem=<path>:size=<limit>`, which takes mount options after the colon). It is discarded when the unit stops. It counts against the unit's `MemoryMax`, so it needs the size limit. If checkouts are too large for that, a disk directory the unit owns is the alternative, and it needs a decision on how it is emptied. |
| Tool cache (`RUNNER_TOOL_CACHE`, under `_work/_tool` by default) | Lives inside the work directory, so it resets with it. |
| `/tmp` and `/var/tmp` | `PrivateTmp=yes`. |
| The runner's home directory | A tmpfs over the home directory with explicit `BindPaths=` for what the pool needs. `fleet-ci-3` already works this way. |
| Credentials on disk | Not a separate case. A credential a job should not read is hidden by the lockdown drop-in as today. A credential that is written during the job lives in a path under the tmpfs mounts above, so it goes away at stop. |
| Runner registration files | The runner writes them into its own folder at start. The pilot's pre-start step deletes any left over (`.runner`, `.credentials`, `.credentials_rsaparams`) and the whole `_work` folder first, so the work folder is empty at each start. |

What is not reset, on purpose: package caches that are bound in read-write
(for example the npm and pip caches on `fleet-ci-3`). They save minutes per job
and they remain shared between jobs. If a pool does not need one, do not bind
it.

## Token handling

- Who mints: the pre-start step of the runner's unit, before the runner starts, as nish (who
  already holds the worker App's key, mode 0600) through the repo's mint, asking for exactly
  `{"organization_self_hosted_runners":"write"}`. The job user cannot read the key, and the
  token never enters a process of the job user.
- Where it goes: into a shell variable, to curl on stdin (`-H @-`), never a command line
  (every user on the box reads command lines) and never the journal. The JIT config is
  written to a root-only file in `/run`, read by systemd as root, and removed when the unit
  stops.
- Lifetime: the installation token lasts one hour and is used for three calls. The JIT
  config is for one runner and one job. The long-lived credential is the App key, which
  stays where it was.
- Stale records: the step deletes every record of the runner's name before it asks for one.
  A stable name keeps one record per runner; a unique name per start would leave one
  offline record per stop and need the same deleting.

## Trade-offs

- Start-up latency: each job waits for a registration round trip and a runner
  start before it is picked up, a few seconds in the normal case. The runner
  also checks for a newer version when it starts, which can add time on the
  first start after a release.
- Throughput during the gap: a runner is not available between one job ending
  and its replacement registering. With 10 agent runners the effect is small,
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
    pre-start step fails, `Restart=always` retries after the unit's
    `RestartSec=30s`, and the runner is absent until it succeeds. A clean exit after
    each job is a start too, so the pilot drop-in sets `StartLimitIntervalSec=45min` and
    `StartLimitBurst=20`: a dead start loop reaches 20 starts and leaves the unit `failed`, and so can
    20 back-to-back jobs each under about 105s, which would bench runner 22 (the drop-in comment has the
    arithmetic). `failed` is what `systemctl --failed` and the
    `node_systemd_unit_state` gauge report. `StartLimitIntervalSec=0` was the
    earlier choice and it hid the failure (fleet-ops#10253): with no start
    limit a restart loop never reaches `failed`, so nothing alerted while the
    runner was absent. Recovery after a benched unit is `systemctl reset-failed`
    and a start.
  - The runner dies mid-job. The job fails, the record is removed by GitHub
    or deleted by the next start's pre-step, and the unit restarts.
  - Orphan records of the same name. The pre-step deletes them before it
    registers, and the Step 4 check lists any leftover.
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
   test job, and then is gone from the list. Run on 2026-11-13 with the JIT route instead
   (a scratch runner started from `ACTIONS_RUNNER_INPUT_JITCONFIG`, online in 5 seconds with the
   labels asked for); the end-of-job check moved to Step 1.
1. **One runner, one job: the pilot (fleet-ops#11960).** Runner 22 only, through
   `rootfs/etc/systemd/system/fleet-runner@22.service.d/10-jit.conf`. The deploy restarts
   that one unit when the drop-in changes. Checks, pasted from the box:
   - the runner shows `online` in `gh api orgs/Nishfleet/actions/runners` with the same
     labels as before (the list does not report an ephemeral flag, so the proof of
     one-job-only is the next two lines);
   - it takes exactly one job (run URL recorded) and the unit then starts again: this
     proves the service exits after its one job, which Step 0 did not;
   - after the job its record is gone from `gh api orgs/Nishfleet/actions/runners`;
   - within a minute a new record with the same name is `online`;
   - the new run's `_work` shows nothing from the previous job;
   - after a restart of the idle pilot there is exactly one record of the name.
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

For the pilot (runner 22), in order:

1. A PR that deletes `10-jit.conf` and adds
   `/etc/systemd/system/fleet-runner@22.service.d/10-jit.conf` to `retired` in
   `ansible/host.yml` (a revert alone leaves the file on the box, because the play's copy
   never deletes). Merge and let the deploy run. Removing a drop-in through `retired` does not
   restart its unit, so the next steps do that.
2. `systemctl stop fleet-runner@22.service`. The old `ExecStart` and `Restart=on-failure`
   apply after the next reload; the deploy already reloaded.
3. As `fleet-runner`, in `/var/lib/fleet-runner/22`, remove any JIT record of the name
   (`gh api -X DELETE orgs/Nishfleet/actions/runners/<id>`), then register again with an
   org registration token from the worker App, group `agent`, labels `self-hosted,agent`:
   `./config.sh --unattended --url https://github.com/Nishfleet --token <token> --name
   netcup-agent-22 --runnergroup agent --labels agent --replace`. The token is typed once
   by the lead and not stored.
4. `systemctl start fleet-runner@22.service`. Check the runner is `online` with its labels.

A reverted unit that starts without the pre-start step and without a registration would
loop on failure until the start limit, so do not start it before step 3.

The wider rollout (Steps 2 to 4) is not part of the pilot and is reverted the same way,
one drop-in at a time.

## Open questions for the build PR

Settled by the pilot (fleet-ops#11960):

- `config.sh --pat` is not used; JIT is (see "Chosen for the pilot"), so the question of an
  App token for `config.sh` is moot.
- The minting credential is the worker App's key where it already is, readable by nish and
  not by the job user.

Still open:

- Memory or disk for `_work`, per pool.
- Whether the vault runner (registered outside the org) joins at all.
- The private home and the root-owned tools folder (fleet-ops#11998), which need the unit
  stop this pilot adds.
