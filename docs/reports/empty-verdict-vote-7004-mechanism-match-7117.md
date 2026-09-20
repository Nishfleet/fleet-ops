# Empty-verdict panel-vote mechanism match for #7117

Issue #7117 is the unit-death dispatch for
`pi-escalation-audit@fleet-ops--7004--devin.service` — one panelist
(role `devin`, routed by `pi-audit-run` to `litellm/worker-capable`) of
the fleet-ops#234 senior escalation panel, voting on #7004, the
UNJUSTIFIED-WAIT quota_bench alarm on seat
`mergegateway__anthropic_claude-sonnet-5.spawn-bench` (benched with no
`bench_until` reset clock). The unit died on 2026-09-16 after three
consecutive runs whose auditor output contained no PASS/FAIL verdict;
the third failure tripped StartLimitBurst and the dispatch was filed at
2026-09-16T07:52:13Z.

The match is the 2026-09-18 sweep — the same match as #6357 and #7107 —
plus the vote target's own detector-green close. No new code is needed.

## Mechanism

The failure mode lived in organs retired two days after the death:

- `bin/pi-escalation-audit` + `pi-escalation-audit@.service` (the #234
  panel that ran this unit) — deleted by 9f0cba02c `chore(glue-sweep):
  delete escalation-tower (16948 lines, Jev 0.87)`, merged 2026-09-18.
- `bin/pi-audit-run` + `bin/pi-audit-tally` + `pi-audit@.service` +
  `pi-audit.slice` (the panel holding `extract_verdict` and the vote
  writer) — removed by d02760b53 and finished by 3c3d74443
  `chore(second-cut-B): finish the pi-audit panel removal — registries,
  gates, CI`, merged 2026-09-18.

With no verdict extractor, no vote writer, and no launcher left, the
empty-verdict → exit-1 → StartLimitBurst chain cannot recur: there is
nothing to produce the empty verdict and no unit to burn StartLimit.

## Audit target disposition (#7004)

The orchestrator sweep pinned this dispatch to the vote's target:
"require its detector-green evidence there and a substantive audit
verdict; empty output is not approval." That evidence exists in the
target's own record. #7004 closed at 2026-09-18T08:05:52Z via
observe-to-close:

> observe-to-close: detector no longer reports
> `loud/unjustified-wait/seat-mergegateway__anthropic_claude-sonnet-.spawn-bench-health_class`
> at 2026-09-18T08:04:42Z — detector reports green on this heartbeat tick.

The preceding three heartbeat comments (2026-09-15, 2026-09-16,
2026-09-17) each reported the same signal key still alarmed; the
2026-09-18 tick reported green and closed the issue in the same minute.
The alarm's seat-health condition cleared on the detector's own
heartbeat rail — the same rail the panel vote existed to audit. No
panel verdict was ever recorded for #7004, and none is now required:
there is no open target to vote on and no lane to run a vote in.

## Prior work on this issue

Four `pi-issue-fleet-ops-7117` worker claims on 2026-09-16
(17:34:03Z, 17:54:01Z, 18:13:42Z, 18:32:14Z) each died to
StartLimitBurst within ~6 s of claiming, tripping the fleet-ops#2772
claim-loop cap (cap=4) and routing the issue through the orchestrator
decision sweep, which held it `blocked-on` #7004. A blocked-check at
2026-09-18T03:53:34Z recorded still-blocked; when #7004 closed the
blocker-cleared pass re-queued the issue agent-ready. A
2026-09-20T19:48:46Z re-claim reset `claim/issue-7117` to `origin/main`;
no salvage exists — `git ls-remote origin` shows no `wip/` ref for this
issue. Cluster-size possible-duplicate notices name #6733 and #6862
(score 0.96); neither was auto-closed.

## Verification

On 2026-09-21, against `origin/main` 53f882c5c:

- `git merge-base --is-ancestor` confirms 9f0cba02c, d02760b53 and
  3c3d74443 are ancestors of `origin/main`.
- `git grep -l 'pi-audit\|pi-escalation-audit' origin/main -- bin/ lib/
  libexec/ systemd/ .github/ config/ prompts/ tests/` — no hits; nothing
  instantiates the lane outside docs, reports and bench fixtures.
- Live host: `~/.config/systemd/user/` holds no `pi-audit` or
  `pi-escalation-audit` unit files; no `pi-audit-run` on PATH;
  `systemctl --user list-units --state=failed` is empty.
- The dead unit's journal is already rotated (`journalctl --user -u
  pi-escalation-audit@fleet-ops--7004--devin.service` returns no
  entries); the issue body carries the captured excerpt showing
  `auditor output did not contain a PASS/FAIL verdict` on all three
  starts.
- `gh issue view 7004 -R Nishfleet/fleet-ops`: state CLOSED, closedAt
  2026-09-18T08:05:52Z, with the detector-green observe-to-close line
  quoted above as the closing comment.

## Disposition

Match #7117 to the sweep deletions 9f0cba02c / d02760b53 / 3c3d74443 and
to #7004's detector-green observe-to-close. The "take the unit's job
over" instruction is moot on both halves: the vote lane is retired and
the vote's subject already carries the detector-green disposition the
orchestrator required. This report supplies the resolution record, not a
repair — and is not itself a PASS/FAIL panel verdict; it records why
none can or need be produced. No new detector, unit, configuration, or
runtime code is required.
