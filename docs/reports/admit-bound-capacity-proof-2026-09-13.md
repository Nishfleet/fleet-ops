# Admit-bound capacity proof — the 0509 supply gate (fleet-ops#5806)

Unit: pi-issue-fleet-ops-5806. The 15:43Z issue-comment proof carried the
acceptance; this report is the repo-side record — the same criteria re-run
live at 2026-09-13T15:49–16:06Z, plus one correction to the release mechanics.
No mechanism changed: observe-to-close (fleet-ops#366), the detectors are the
existing `admit_ceiling` bound, the 2h journal grep, the FleetUndersaturated
rule, and gh merged-PR counts.

## 1. Workers vs the post-#4263 bound — PASS

After #4263 the concurrency bound is `admit_ceiling()` (`lib/litellm-seat.sh:448`):
`min(target_concurrent, Σ declared provider caps)` — the function reads the
provider-level `cap` fields (Σ 45; the model rows sum 48 separately and are
the per-model lanes, not this bound); RAM safety is
per-unit `MemoryMax` + systemd-oomd, not a charge. Live 2026-09-13T16:06Z:

```
$ jq -r '[.providers[]?.cap // 0] | add' config/seat-caps.json
45
$ jq -r '.target_concurrent' config/seat-caps.json
25
$ jq -r '.ram_gb_per_worker // "ABSENT"' config/seat-caps.json        # tracked
ABSENT
$ jq -r '.ram_gb_per_worker // "ABSENT"' ~/.local/state/pi-packet/seat-caps.json
ABSENT
$ # healthy prepaid roster: devin 4 + llmgateway-devpass 1 + synthetic 1
$ #   + opencode 3 + opencode-go 1 + paretoinference 4 + cursor 2 + ollama 0 = 16
$ systemctl --user list-units 'pi-issue@*' --state=active,activating --no-legend | wc -l
28        # 18x0509 + 10xfleet-ops
```

No RAM-charge term remains (deleted with `lib/seat-lib.sh` in #4263; tracked and
live `seat-caps.json` both lack the key — pinned by
`tests/fleet-work-slice-tasksmax.test.sh:100`). In the proof window the active
count was 24 at 15:28Z and 16 at 15:52Z — at/above the 16-seat prepaid-healthy
roster (the 15:43Z comment: 24 = "above the 16-seat prepaid roster; yesterday's
4-worker starvation is gone"). 28 at 16:06Z after the 15:48Z intake restart.
`target_concurrent = 25` is the light-workload ceiling, not a hard cap —
free-lane probes above declared are the designed overshoot
(`config/seat-caps.json` `_comment_aimd`); recorded as observed, not
adjudicated. Supply, not admission, moves the count (criteria 3–4).

## 2. 2h journal: 0 provider-error deaths — PASS

```
$ journalctl --user -u 'pi-issue@*' --since '2 hours ago' --no-pager \
    | grep -cE ' (401|402|403|429)([^0-9]|$)'
0
```

Measured 0 at 15:52Z and again at 16:06Z (the 15:43Z proof measured the same 0).
This unit's own two StartLimitBurst deaths (15:11Z/15:15Z) were
`subagent-extload`, not 4xx; the 15:43Z and 15:48Z incarnations posted the proof
and finished the run.

## 3. FleetUndersaturated inactive — PASS

```
$ curl -s http://127.0.0.1:9090/api/v1/alerts | jq -r '[.data.alerts[]
  | select(.labels.alertname=="FleetUndersaturated")] | if length==0
  then "NOT FIRING" else .[0].state end'
NOT FIRING
$ # inputs at 16:06Z: fleet_pi_workers_active{kind="sum"} = 37,
$ #                    fleet_ready_work = 75
```

The rule (`config/fleet_rules.yml:517`: workers < 2 with ready work, `for: 30m`)
stays false while ≥2 workers run. Not firing at 15:03Z, 15:44Z, 15:52Z and
16:06Z. It was not among the 10 firing canaries at 15:44Z (the 15:43Z comment's
standing-census note).

## 4. 0509 drain, before/after — measured and posted

- BEFORE (2026-09-11, the metric's own baseline): **156** merged/24h = **6.5/h**
  (re-derived independently from `gh pr list --state merged` — matches the
  15:43Z comment's 156 exactly).
- AFTER (2026-09-12T22:33Z — the 3-layer fix + the #6096 dead-credit bench —
  → 16:06Z, 17.6h): **22** = **1.25/h**. (Last-24h view: 27 = 1.13/h.)
- 2× target (13/h): **not yet**. It is the post-release expectation, not this
  gate's accept; the accept asked for the before/after measured and posted
  (the 15:43Z comment, and the release correction below).
- Not admission: criteria 1–3. It is supply — the claimable backlog sat behind
  this gate (the 15:43Z item 4), and the pipe stayed alive throughout (0509#3377
  landed 15:20:35Z).

## 5. Correction — the 16 slices' release mechanics

The issue's pinned first comment and the 15:43Z proof say all 16
`split-after-fix` slices (0509#3195–3210) carry `blocked-on:` this issue. Live
check 15:53Z: **only #3195–3197 do**. #3198–3210 point at 0509#3178 — CLOSED
2026-09-13T04:50:58Z — so they were already claimable since this morning (the
intake's stale-blocker rule: "all blocked-on targets closed/merged; letting
through", `lib/pi-intake-tick.sh:683`). All 16 are labelled
`agent-ready,split-after-fix`.

End state is unchanged from what the 15:43Z proof promised: when THIS issue
closes, zero of the 16 sit behind an OPEN blocker — #3195–3197 release, the
other 13 already have. Closing this issue remains the only release mechanism;
no label surgery, no early release (standing order held).

mechanism: none new — the detectors here are the intake's own
`admit_ceiling`/`seat_max_concurrent` bound, the 2h journal grep, the
FleetUndersaturated rule, and gh merged-PR counts. This report, the 15:43Z
issue comment, and the #5806 body's post-#4263 termination wording are the
observe-to-close evidence.
