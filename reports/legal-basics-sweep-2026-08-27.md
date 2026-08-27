# Legal-basics sweep (2026-08-27)

Live HTTP check of every public Nishfleet product named in fleet-ops#1233, plus the other live hosts in Site Rep's owned-domain list.

Checked 2026-08-27T18:24Z from netcup-rs2000 with `curl -L`. Legal wording is Nish-reserved. Missing pages are drafted as PLACEHOLDER PRs, not published as final.

## Per product

| Product | Privacy | Terms | Contact | Stores user data | Policy matches stored data |
|---|---|---|---|---|---|
| 0509.io | 200 `/privacy`, linked in footer | 200 `/terms`, linked in footer | reachable: footer mailto support@0509.io and `/help` (no `/contact` page) | yes: accounts, watchlists, collections, notes, reports, share links, delivery, Meta access, logs | yes: privacy page names watchlists, accounts, searches, collections, notes, reports, share links |
| siterep.net | 200 `/privacy`, linked in footer | 200 `/terms`, linked in footer | reachable: footer mailto hello@siterep.net (no `/contact` page) | yes: bot config, chats, billing | yes: privacy page names what Site Rep collects |
| tinystudio.in | 200 `/privacy/` | 200 `/terms/` | 200 `/contact/` | public app info only | yes |
| aiconverter.app | 200 `/privacy/` | 200 `/terms/` | reachable: `/support/` form ( `/contact` is 404) | yes: uploads, exports, payment email, job metadata | yes: privacy page names uploads, exports, payment, abuse metadata |
| seofixkit.com | 200 `/privacy` | 200 `/terms` | reachable: mailto support@seofixkit.com on those pages ( `/contact` is 404) | yes: access, audits, checkout | yes: privacy page names that data |
| tinystudio.io | **missing** `/privacy` 404 | **missing** `/terms` 404. `/pricing` exists and is commercial terms, not a privacy policy | **missing** `/contact` 404. hello@tinystudio.io exists on `/agent-desk` only, not the homepage footer | yes: appraisal form writes email + website to D1 `tinystudio_email_signups` | **no policy page at all** |
| inish.in | **missing** `/privacy` 404 | **missing** `/terms` 404 | **missing** `/contact` 404. About page exists. No mailto in the footer | no accounts or forms on the daily page | n/a until a page exists |

## Gaps that need pages

1. **tinystudio.io** (Nishfleet/TinyStudio.io-public) — collects work emails today with no privacy page and no footer legal links. Highest gap.
2. **inish.in** (Nishfleet/inish-site) — public site with no privacy, terms, or contact page.

aiconverter `/contact` 404 is not a gap: `/support/` is the contact path and is linked from the legal footer.

0509 and siterep have no `/contact` URL. Contact is still reachable by mailto in the public footer, which this sweep treats as enough.

## Follow-up

PLACEHOLDER page PRs for the two gaps, marked for Nish to rewrite before they count as final legal text. Flagged LEGAL-BOUNDARY via NISH-ESCALATIONS.md.
