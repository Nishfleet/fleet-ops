# TakePact decision layers: plan slice

Plan only, per Nishfleet/fleet-ops#7440 (parent epic #7370, product sibling 0509#3546).
Paper, no machinery. TakePact is the India-native AI-services offer: a small
monthly service where an agent fleet watches an SMB owner's inbox and messages
and makes the small calls for them. Pricing is Nish's call; this doc only
presents options. Nothing here deploys, contacts a customer, or spends beyond
the packet's Jev cap.

## What a decision layer is, for an SMB owner

An SMB owner (clinic, salon, coaching centre, small trader) drowns in small
judgements, not big ones. A decision layer is an always-on assistant that
makes those small calls the same way every time, shows its work, and hands
up only what matters. Four jobs:

- **Triage.** Read every inbound message and sort it: new lead, existing
  customer, payment chase, spam, urgent. The owner sees a short list with a
  one-line reason for each call, not a pile of chats.
- **Routing.** Send each item to the right place: a booking goes to the
  calendar, a price question gets a drafted reply, an angry message pings the
  owner's phone. Nothing is answered silently by a robot; drafts wait for a
  tap.
- **QA.** Check the outgoing side too: is the reply in the customer's
  language, does it quote the right price, does it promise something the
  business does not do? Flag before send, keep a log of what was changed.
- **Alerts.** A daily digest in plain words ("3 new leads, 1 unanswered for
  6 hours, 2 bad reviews") plus immediate alerts only for the few things
  that lose money fast: a bad review, a cancelled booking, a payment bounce.

Jev (typesafe-ai/jev) is the decision step inside this: each message becomes
one typed question (triage bucket, route choice, urgency score) answered in
under a second at roughly $0.00002 per call. The calling agent owns the
verdict; Jev's probability is logged with the message id so the owner can
audit any call. Advisory-first: drafts and digests, never silent actions,
until the owner flips the per-site autonomy flag on. Rollback per site is a
single flag, as in the sibling packets.

## Three pilot offers

Cost notes apply to all three. Jev spend is nearly free at pilot scale: 50
decisions a day is about 950k tokens a month, roughly $0.04. Agent hours are
our own fleet's time on existing organs (intake, queue, digest), so the real
cost to Nish is setup attention, not cash. Bands are candidates only; Nish
sets every price.

### Offer A: lead triage and routing inbox

- What the client gets: every WhatsApp and email lead sorted, routed, and
  answered with a draft within minutes; a morning list of who to call.
- What we run: one intake organ per client, Jev triage and route questions,
  a human-tap send step. No client engineering; they forward a number.
- Delivery cost: about 2 agent-days to stand up the first client, under a
  day for each next one from the same template. Jev under $0.10 a month.
- Price band candidates for Nish: ₹4,000 / ₹7,500 / ₹12,000 per month.

### Offer B: review and complaint QA copilot

- What the client gets: Google Maps and Justdial reviews and complaints
  classified and answered with drafted replies in the owner's voice; crisis
  items alert instantly.
- What we run: review-source ingestion (the fragile part; platforms change),
  Jev severity and risk-class questions, reply drafts held for approval.
- Delivery cost: about 3 agent-days for the first client, and ongoing
  babysitting of the scraping surface. Jev under $0.15 a month.
- Price band candidates for Nish: ₹6,000 / ₹10,000 / ₹15,000 per month.

### Offer C: daily ops digest and alerts

- What the client gets: one plain-words message each morning summarising
  bookings, payments, and stock notes from their existing sheet or WhatsApp
  export, with same-hour alerts for money-losing events.
- What we run: a digest packet on the existing heartbeat, Jev urgency
  scoring, one alert path. Simplest of the three; no send-into-inbox step.
- Delivery cost: about 1.5 agent-days for the first client. Jev under
  $0.05 a month.
- Price band candidates for Nish: ₹2,500 / ₹4,000 / ₹6,000 per month.

## First pilot: Jev call

Recorded 2026-09-17 by pi-issue-fleet-ops-7440 using the #7371 helper
(`bin/jev-eval`, curl protocol, model hard-locked to typesafe-ai/jev).
State carried: TakePact pilot-first context, the three offers with setup
effort and bands, and the choice criteria (days to first demo, India SMB
willingness to pay, delivery risk, fit with existing fleet organs,
reversibility). Raw output: `/tmp/jev-7440-first-pilot.json`.

- Question `first_pilot` (choice: A / B / C): **C** at p=PLACEHOLDER
- Question `confidence` (boolean, "recommend this pilot now"): PLACEHOLDER

Verdict (owned by this worker, not Jev): PLACEHOLDER

Pricing of the chosen pilot stays open: the bands above are candidates only.
Nish picks price, and Nish approves any real customer contact before a pilot
runs.

## Rollback

Delete this file. No code, config, timer, or organ is touched by this slice.
