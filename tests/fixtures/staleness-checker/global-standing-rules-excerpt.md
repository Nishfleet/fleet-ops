## An OOM manager is reactive, not preventive (Nish, 2026-08-26)

Installed 2026-08-26. Before that there was no reactive manager at all — the
kernel OOM killer was the fallback, and it picks arbitrarily.

Rules that come with it:

- **Scope the kill policy to the work slice.** sshd, tailscaled, the fleet
  heartbeat and the intake timers stay `auto`. An OOM manager that can take
  the box's lifelines, or the supervisor that would repair a reaped worker, is
  worse than none.
- **Set thresholds from measured baseline, then check against practice.**
  systemd defaults to 60%/30s; Fedora ships 50%/20s for latency-sensitive
  desktops. A batch fleet should sit well above both — a throttled worker
  finishing slowly beats a killed worker losing its work.
- **Do not kill on swap.** Swapped-out pages of workers idling on API calls are
  healthy. `ManagedOOMSwap` stays off.
- **An OOM policy is unproven until a drill shows it firing** on the intended
  cgroup while the lifelines survive. systemd/systemd#33486 documents pressure
  limits silently not firing.

## Everything is mechanical — failures included (Nish, 2026-08-26 — NON-NEGOTIABLE)

One rule, one grep target. It restates what the 08-22 "Every finding gets
queued" line, "Fix it, don't report it", and the plumbing ban already implied —
the delta is ENFORCEMENT, because prose alone is how tonight's seven dropped
balls happened.

- Enforcement itself is mechanical (Nish, same day: "no stone unturned"):
  every rule in this file and every non-negotiable ledger line must name its
  live enforcer in the machine-readable rule-enforcement matrix; the heartbeat
  canary diffs this file against the matrix every cycle and goes LOUD on any
  rule without one (fleet-ops #383). A rule that exists only as prose is a
  defect of this file.
- The hunt is itself mechanical: the blind audit + gap-closure loop carry a
  standing manual-seam lens every cycle (fleet-ops #377) — never dependent on
  Nish asking. Enforcement lives at the senior conference (#366: failure-fix
  diffs without a mechanism auto-reject) and in the recurring audit.
- Nish-reserved actions (money, legal, product direction, customer-data
  deletion) are the only accepted-manual tier, and even those get enumerated,
  not assumed.

Origin: 2026-08-26 night — seven dropped balls (closed-but-undelivered #221/
#76/#124/#223, SKIP spam post-fix, stale blockers parking #180, swallowed
journals, an audit armed but never run) all traced to rules without mechanisms.

## Legit work only — no spinning wheels, fleet-wide (Nish, 2026-08-28)

- Applies to ALL repos and ALL work, every lane, every agent: only legitimate,
  gated work may occupy a lane. An item qualifies only by passing the existing
  spec/quality gates and tracing to a live observed defect, a standing quality
  bar, or Nish-decided direction. Self-generated polish loops, churn-class
  make-work, and machinery-on-machinery busywork are forbidden everywhere —
  not just in band-surge lanes. Idle is better than illegitimate work.
- Corollary: "let the fleet go to max" (band inversion, same day) is
  conditional on this rule — expansion admits only qualifying items.
- Enforcer: the legit-work gate implemented by fleet-ops#1516 (band inversion)
  MUST register this rule in config/rule-enforcement.json as part of landing;
  until then the heartbeat canary correctly flags this rule as
  mechanism-pending. Churn measurement: the standing quality metrics
  (upgrade/repair/churn baseline).

Origin: Nish, 2026-08-28 — "no spinning wheels / endless polishing work
allowed on my vps... this law should be fleet side btw (applies to all
repo's and all work)".

## Quality is a constraint, never a trade-off (Nish, 2026-08-28)

- No layer of the fleet may trade quality for throughput, ever. Quality gates
  are hard constraints: throughput is maximized SUBJECT TO them, and any
  design, dispatch, review verdict, or dial change that relaxes a quality gate
  to gain speed is invalid on its face — not weighed, REJECTED. "Both dials
  up" means throughput rises only through capacity, latency, and waste
  removal, never through gate relaxation.
- Mechanical enforcement, layer by layer: (1) merge layer — required CI
  checks + auto-revert on red main; (2) closure layer — user-facing work
  cannot close without live proof (0509#1365 detector rules) and null-diff
  merges never count; (3) dial layer — the WFR ratchet is tighten-only; any
  loosening requires Nish's explicit, logged waiver; (4) proposal layer — the
  senior conference treats quality-gate relaxation as out-of-scope input, the
  same class as an unauthorized machinery build; (5) metric layer — the
  success number is VERIFIED throughput only (#1136), so gamed speed cannot
  even be scored.
- Enforcer registration: fleet-ops#1516 and #1136 must register this rule in
  config/rule-enforcement.json as they land; until then the heartbeat canary
  correctly flags it mechanism-pending.

Origin: Nish, 2026-08-28 — "No quality trade-offs accepted - mechanically
banned by every layer", refining same-day "max *quality* throughput because
*quality* above all else".
