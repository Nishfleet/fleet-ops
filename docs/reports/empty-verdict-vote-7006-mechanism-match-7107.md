# Empty-verdict panel-vote mechanism match for #7107

Issue #7107 is the unit-death dispatch for
`pi-escalation-audit@fleet-ops--7006--free-glm.service` — one panelist
(role `free-glm`, routed by `pi-audit-run` to `litellm/worker-cheap`) of
the fleet-ops#234 senior escalation panel, voting on #7006, the
UNJUSTIFIED-WAIT quota_bench alarm on seat
`mergegateway__minimax_minimax-m3.spawn-bench`. The unit died on
2026-09-16 after three consecutive runs whose auditor output contained
no PASS/FAIL verdict; the third failure tripped StartLimitBurst and the
dispatch was filed at 2026-09-16T05:51:31Z.

The match is the 2026-09-18 sweep — the same match as #6357 — plus the
vote target's own detector-green close. No new code is needed.

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

## Audit target disposition (#7006)

The orchestrator sweep pinned this dispatch to the vote's target:
"require its detector-green evidence there and a substantive audit
verdict; empty output is not approval." That evidence exists in the
target's own record. #7006 closed at 2026-09-18T08:05:56Z via
observe-to-close:

> observe-to-close: detector no longer reports
> `loud/unjustified-wait/seat-mergegateway__minimax_minimax-m3.spawn-bench-health_class-quota_bench`
> at 2026-09-18T08:04:42Z — detector reports green on this heartbeat tick.

The alarm's seat-health condition cleared on the detector's own heartbeat
rail — the same rail the panel vote existed to audit. No panel verdict
was ever recorded for #7006, and none is now required: there is no open
target to vote on and no lane to run a vote in.

## Prior work on this issue

Four `pi-issue-fleet-ops-7107` worker claims on 2026-09-16 each died to
StartLimitBurst within ~6 s of claiming, tripping the fleet-ops#2772
claim-loop cap and routing the issue through the orchestrator decision
sweep. A 2026-09-20T19:28:54Z re-claim reset `claim/issue-7107` to
`origin/main`; no salvage exists — `git ls-remote origin` shows no `wip/`
ref for this issue.

## Verification

On 2026-09-21, against `origin/main` c00704f3b:

- `git merge-base --is-ancestor` confirms 9f0cba02c, d02760b53 and
  3c3d74443 are ancestors of `origin/main`.
- `git grep -l 'pi-audit\|pi-escalation-audit' origin/main -- bin/ lib/
  libexec/ systemd/ .github/ config/ prompts/ tests/` — no hits; nothing
  instantiates the lane outside docs, reports and bench fixtures.
- Live host: `~/.config/systemd/user/` holds no `pi-audit` or
  `pi-escalation-audit` unit files; no `pi-audit-run` on PATH;
  `systemctl --user list-units --state=failed` is empty.
- The dead unit's journal is already rotated (`journalctl --user -u
  pi-escalation-audit@fleet-ops--7006--free-glm.service` returns no
  entries); the issue body carries the captured excerpt showing
  `auditor output did not contain a PASS/FAIL verdict` on all three
  starts.
- `gh issue view 7006 -R Nishfleet/fleet-ops`: state CLOSED, closedAt
  2026-09-18T08:05:56Z, with the detector-green observe-to-close line
  quoted above as the closing comment.

## Disposition

Match #7107 to the sweep deletions 9f0cba02c / d02760b53 / 3c3d74443 and
to #7006's detector-green observe-to-close. The "take the unit's job
over" instruction is moot on both halves: the vote lane is retired and
the vote's subject already carries the detector-green disposition the
orchestrator required. This report supplies the resolution record, not a
repair — and is not itself a PASS/FAIL panel verdict; it records why
none can or need be produced. No new detector, unit, configuration, or
runtime code is required.
