# TakePact decision layers: plan slice

Recommend Offer C, a daily operations digest, for the first pilot after Nish
approves customer contact and price. This is a plan, not a running service.
No customer contact, deployment, new service, timer or connector is authorised.

Scope and sources: [issue #7440](https://github.com/Nishfleet/fleet-ops/issues/7440)
asks for an India-native, pilot-first service plan. The
[parent epic #7370](https://github.com/Nishfleet/fleet-ops/issues/7370) supplies
the Jev model, SDK-only call shape, advisory-first rule and input-token price.
The price bands and hours below are planning estimates, not market research,
customer quotes or measured delivery results. Nish alone sets prices.

## What a decision layer does for a small business

It helps the owner sort work and see what needs attention:

- Triage sorts messages into new leads, existing customers, complaints and
  payment questions.
- Routing suggests the person who should handle each item.
- QA checks a proposed reply against the business's approved prices and
  promises before anyone sends it.
- Alerts flag possible urgent items for the owner's review.

Jev is the decision step, not the whole assistant. It answers typed choice,
boolean and score questions with probabilities. Other tools must collect the
data and write drafts or summaries. A probability is not proof of accuracy.
Language support and accuracy need checking on the client's real records.

Use the existing `bin/jev-eval.mjs` helper and SDK. Supply full context,
including the business rules and record being judged. Log the probability,
record reference and owned verdict as JSONL. Start advisory-only: staff review
suggestions, and no reply, booking, payment or stock change happens silently.
A future pilot must keep customer data separate from fleet operations logs.
Access, consent and retention need approval before processing customer records.
Do not put customer data in this repo or its public issues.

## Cost assumptions for all three offers

One pilot means one business, one data source, up to 50 records per day for
30 days. Allow two decisions per record and 2,000 input tokens per decision,
including rules and context: 50 × 30 × 2 × 2,000 = 6 million input tokens.
At the epic's quoted $0.042 per million input tokens and $0 output, that is
**$0.252 of Jev usage per month**, or about $0.51 with twice the call volume.
This is a budget estimate, not a live billing quote. Check rates before sale.
The issue's evaluation spend cap is $1, not authority for a customer subscription.

Agent-hours mean cumulative task time, not calendar time or free labour.
Estimates include setup, checks and a handoff; recurring hours cover review
and corrections. Human hours are separate. Draft-writing model costs, hosting,
platform fees, taxes and support beyond these hours are not priced here.
Existing prepaid capacity is not evidence that delivery has zero cost.
Before quoting, add those costs and the chosen hourly rates to the Jev budget.
The candidate bands below must cover that total; no margin is yet proven.

## Three pilot offers

### Offer A: lead triage and routing

- Client: a salon or coaching centre with an existing lead sheet or inbox.
- Deliverable: a daily list of new leads, suggested staff owner and next step,
  with draft replies held for approval. Measure missed leads and time to review.
- Boundary: one owner-provided export or approved source. No WhatsApp API,
  calendar write or automatic send is included. An export cannot support a
  promise of replies within minutes.
- Estimated cost: 16 agent-hours setup, 4 agent-hours per month thereafter;
  2 human hours onboarding and 2 per month reviewing samples, plus staff's
  normal approval time. Jev budget $0.252 per month at the shared volume.
- Monthly price candidates for Nish: ₹4,000 to ₹12,000. Lower end assumes clean
  exports; upper end allows more review. Setup recovery remains an open choice.

### Offer B: complaint and reply QA

- Client: a local service business with complaint messages and review exports.
- Deliverable: a complaint queue, suggested severity and draft replies checked
  against approved facts. Measure missed serious complaints and draft corrections.
- Boundary: owner-supplied records only. No scraping Google Maps or Justdial,
  posting public replies or promise of instant crisis detection. Medical or
  legal judgements stay with qualified staff.
- Estimated cost: 24 agent-hours setup, 8 agent-hours per month thereafter;
  3 human hours onboarding and 4 per month reviewing samples, plus staff's
  approval time. Jev budget $0.252 per month at the shared volume.
- Monthly price candidates for Nish: ₹6,000 to ₹15,000. The higher review effort
  explains the higher range; willingness to pay is untested.

### Offer C: daily operations digest and exception list

- Client: a small trader already tracking bookings, payment status or stock
  in one sheet. Start with one of these, not all three integrations.
- Deliverable: one daily draft digest linked to source rows, plus an exception
  list for the owner. Measure corrections, missed exceptions and review time.
- Boundary: read-only owner-provided export. Missing or stale data must be shown,
  not called a healthy day. No same-hour alerts from a daily export, payment
  handling or stock changes.
- Estimated cost: 12 agent-hours setup, 2 agent-hours per month thereafter;
  2 human hours onboarding and 1 per month reviewing samples, plus the owner's
  daily review. Jev budget $0.252 per month at the shared volume.
- Monthly price candidates for Nish: ₹2,500 to ₹6,000. This is the narrowest
  offer, but its full delivery cost and demand still need measurement.

## First pilot and decision evidence

Recommend C because a read-only daily export needs fewer connections and less
review than A or B. Reject a live multi-channel inbox as the first scope:
access and delivery promises would dominate the learning. This is a product
proposal for Nish, not authority to build or contact anyone.

A real SDK call on the proposal record for #7440 at 2026-09-17T17:38:20.206Z
returned C with probability 0.93, A 0.07 and B 0.00. The separate question
about running now returned probability 0.56. It did not return an explanation,
and neither answer proves demand or authorises launch.

Evidence: site `jev-7440-first-pilot`, corresponding JSONL row in the local Jev
log, state SHA-256
`e53af7a385fa7b630ad2d951118a918bf0a8f6bc9086ca8f8e222654dc3a52e8`.
The call took 346 ms, used 914 input and 57 output tokens, and has an estimated
input cost of $0.000038388 at the epic's rate.

The input contained the earlier draft's three offers, 2/3/1.5 agent-day setup
estimates, bands and selection criteria. It also assumed existing delivery
connections and lower Jev spend. This revised plan removes those unverified
claims and states hours and costs explicitly. That call is historical evidence
of evaluating the proposal, not a benchmark of these services on SMB traffic.
After the revision, a second real call read the full document text as state
with the acceptance criteria. It returned C at p=1.0 and a meets-acceptance
check of 0.96 at 2026-09-17T17:49:45.063Z, 389 ms, 2,387 input tokens, state
SHA-256 `9af4cdaab4eb2bea3b137d1fc31e98377040cb8feefdc1de81d8ec55dc9ddd49`.
A model agreement is not proof of acceptance. The recommendation remains
advisory and owned by the author.

After approval, propose a two-week read-only pilot with one consenting business.
First collect a staff-reviewed baseline from real, permitted records. Compare
missed exceptions, corrections and owner review time on the same records.
Use record IDs and timestamps in restricted evidence; never invented samples
as proof. Agree success limits before running, then decide whether to continue.
No demo, paid pilot or accuracy result is claimed by this document.

## Reuse and rollback

Future implementation must extend approved existing intake and digest paths,
not add a service, timer or orchestration layer. Customer connectors are not
verified by this plan. Require a per-site off flag that returns work to the
manual process, and stop on missing access or stale input. Neither an autonomy
flag nor a model score can grant authority to send messages or spend money.

For this PR, rollback is deleting this document. It changes no running system.
