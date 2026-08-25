# Dirty worktree audit

Generated: 2026-08-25T21:50:37.858068+00:00Z
Input: `/home/nish/.local/state/vps-maintenance/dirty-worktrees.txt`
Dry run: False

## Summary

- Worktrees inspected: 357
- Genuinely unlanded branches: 140
- UU (unresolved merge conflict) worktrees: 5
- Proved fully landed / safe to reclaim: 187
- Errors / skipped: 25

## 1. Genuinely unlanded branches

| Repo | Branch | Commits ahead | Last commit | Pushed | Worktree |
|------|--------|--------------|-------------|--------|----------|
| Nishfleet/0509 | 0509-lane4-ads-showcase-scheduled-refresh | 2 | 2026-08-21T10:53:27+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/0509-lane4-20260821-102039` |
| Nishfleet/0509 | 0509/funnel-measurement-default-off-events | 819 | 2026-08-07T10:55:27+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-funnel-measurement-candidate-1` |
| Nishfleet/0509 | 0509/funnel-measurement-default-off-events | 819 | 2026-08-07T10:55:27+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/0509-funnel-measurement-candidate-2` |
| Nishfleet/0509 | 0509/funnel-measurement-default-off-events | 819 | 2026-08-07T10:55:27+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-funnel-measurement-candidate-3` |
| Nishfleet/0509 | 0509/funnel-measurement-default-off-events | 819 | 2026-08-07T10:55:27+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-funnel-measurement-candidate-5` |
| Nishfleet/0509 | build/bl034 | 736 | 2026-07-30T09:48:32+05:30 | pushed | `/home/nish/workspaces/products/0509-bl034` |
| Nishfleet/0509 | claim/issue-1057 | 1 | 2026-08-26T00:12:09+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/issue-0509-1057` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | pushed | `/home/nish/workspaces/_claude-worktrees/0509-backup-evidence` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-lane9` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-magicbrief-promise-candidate-1` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-magicbrief-promise-candidate-2` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-magicbrief-promise-candidate-4` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-magicbrief-promise-candidate-5` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-sample-brief-candidate-3` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-sample-brief-candidate-4` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-sample-brief-candidate-5` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-selected-search-identity-1` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-selected-search-identity-2` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-selected-search-identity-3` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-selected-search-identity-4` |
| Nishfleet/0509 | fix/d1-backup-evidence-race | 814 | 2026-08-06T14:56:49Z | already on origin | `/home/nish/workspaces/agent-worktrees/0509-selected-search-identity-5` |
| Nishfleet/0509 | fix/email-honesty | 735 | 2026-07-29T16:57:56Z | pushed | `/home/nish/workspaces/products/0509-bl022` |
| Nishfleet/0509 | fix/kill-demo-data-fix-capture-reliability | 1 | 2026-08-22T01:00:52+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/0509-lane1-20260821-234032` |
| Nishfleet/0509 | fix/lane1-llms-current-product-story | 1 | 2026-08-11T16:46:23+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/0509-lane1-20260811-161032` |
| Nishfleet/0509 | fix/legacy-public-route-301-redirects | 1 | 2026-08-14T08:57:46+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/0509-legacy-route-301-20260814` |
| Nishfleet/0509 | nightly/cross-browser-startup-1-20260805 | 801 | 2026-08-05T06:19:57Z | pushed | `/home/nish/workspaces/agent-worktrees/0509-cross-browser-startup-1-20260805` |
| Nishfleet/0509 | nightly/cross-browser-startup-2-20260805 | 801 | 2026-08-05T06:19:57Z | pushed | `/home/nish/workspaces/agent-worktrees/0509-cross-browser-startup-2-20260805` |
| Nishfleet/0509 | nightly/cross-browser-startup-3-20260805 | 801 | 2026-08-05T06:19:57Z | pushed | `/home/nish/workspaces/agent-worktrees/0509-cross-browser-startup-3-20260805` |
| Nishfleet/0509 | nightly/cross-browser-startup-4-20260805 | 801 | 2026-08-05T06:19:57Z | pushed | `/home/nish/workspaces/agent-worktrees/0509-cross-browser-startup-4-20260805` |
| Nishfleet/0509 | ops/ci-blindspot-detector | 817 |  | pushed | `/home/nish/workspaces/_claude-worktrees/0509-blindspot` |
| Nishfleet/0509 | ops/liveness-off-actions-cron | 2 | 2026-08-11T22:42:20+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/0509-lane3-20260811-221807` |
| Nishfleet/0509 | packet/magicbrief-migration-guide-20260806 | 807 | 2026-08-06T09:50:15+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-lane4` |
| Nishfleet/0509 | packet/magicbrief-migration-guide-20260806 | 807 | 2026-08-06T09:50:15+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-magicbrief-4` |
| Nishfleet/0509 | packet/magicbrief-migration-guide-20260806 | 807 | 2026-08-06T09:50:15+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-magicbrief-5` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-candidate-structured-data-1` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-candidate-structured-data-2` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-candidate-structured-data-3` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-candidate-structured-data-4` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-candidate-structured-data-5` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-search-submit-candidate-1` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-search-submit-candidate-2` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-search-submit-candidate-3` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-search-submit-candidate-4` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/0509-search-submit-candidate-5` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/magicbrief-cta-1` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/magicbrief-cta-2` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/magicbrief-cta-4` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/magicbrief-cta-5` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/named-owner-materiality-1` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/named-owner-materiality-3` |
| Nishfleet/0509 | rebuild/evidence-desk | 835 | 2026-08-08T13:37:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/named-owner-materiality-4` |
| Nishfleet/0509 | rescue/homepage-nav-signup-1-25392ca2 | 843 | 2026-08-09T11:50:48+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/homepage-nav-signup-1` |
| Nishfleet/0509 | rescue/homepage-nav-signup-1-25392ca2 | 843 | 2026-08-09T11:50:48+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/homepage-nav-signup-3` |
| Nishfleet/0509 | rescue/homepage-nav-signup-1-25392ca2 | 843 | 2026-08-09T11:50:48+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/homepage-nav-signup-4` |
| Nishfleet/0509 | rescue/homepage-nav-signup-1-25392ca2 | 843 | 2026-08-09T11:50:48+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/homepage-nav-signup-5` |
| Nishfleet/0509 | test/cta-aria-busy-coverage | 713 | 2026-07-27T20:51:40+05:30 | already on origin | `/home/nish/workspaces/products/0509-audit` |
| Nishfleet/0509 | test/cta-aria-busy-coverage | 713 | 2026-07-27T20:51:40+05:30 | pushed | `/home/nish/workspaces/products/0509-flash-trial` |
| Nishfleet/TinyStudio.io | docs/evidence/duplicate-open-pr-clusters-2026-08-11 | 1 | 2026-08-11T06:40:29+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-io-lane1-20260811-055032` |
| Nishfleet/TinyStudio.io | docs/upcity-venue-shutdown-2026-08-21 | 1 | 2026-08-21T14:46:16+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-io-lane5` |
| Nishfleet/TinyStudio.io | fix/agent-desk-title-canonical-lane1 | 3 | 2026-08-12T11:20:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-io-lane1` |
| Nishfleet/TinyStudio.io | fix/audit-intake-candidate-4 | 20 | 2026-08-06T17:35:59+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-ux-2` |
| Nishfleet/TinyStudio.io | fix/audit-intake-candidate-4 | 20 | 2026-08-06T17:35:59+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-ux-3` |
| Nishfleet/TinyStudio.io | fix/audit-intake-candidate-4 | 20 | 2026-08-06T17:35:59+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-ux-4` |
| Nishfleet/TinyStudio.io | fix/audit-intake-candidate-4 | 20 | 2026-08-06T17:35:59+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-ux-5` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-audit-1` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-audit-2` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-audit-3` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-audit-5` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-audit-refine-1` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-audit-refine-2` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-search-1` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-search-2` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-search-3` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-search-4` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-search-5` |
| Nishfleet/TinyStudio.io | fix/mobile-390-overflow | 22 | 2026-08-06T20:22:39+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-search-refine-c` |
| Nishfleet/TinyStudio.io | gate/semgrep-actionlint-20260825 | 1 | 2026-08-25T00:25:50+05:30 | pushed | `/home/nish/workspaces/products/TinyStudio.io` |
| Nishfleet/TinyStudio.io | lane1-audit-cta-reverify | 1 | 2026-08-21T13:43:08+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-io-lane1-20260821-124044` |
| Nishfleet/TinyStudio.io | lane1/pricing-callout-dup-reconcile-20260821 | 1 | 2026-08-21T12:37:45+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-io-lane1-20260821-114544` |
| Nishfleet/TinyStudio.io | loop/e1-pilot-delivery-packet | 15 | 2026-08-05T19:36:38+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-cycle-20260805-candidates/candidate-1` |
| Nishfleet/TinyStudio.io | loop/e1-pilot-delivery-packet | 15 | 2026-08-05T19:36:38+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-cycle-20260805-candidates/candidate-3` |
| Nishfleet/TinyStudio.io | loop/e1-pilot-delivery-packet | 15 | 2026-08-05T19:36:38+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-cycle-20260805-candidates/candidate-4` |
| Nishfleet/TinyStudio.io | loop/e1-pilot-delivery-packet | 15 | 2026-08-05T19:36:38+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-cycle-20260805-candidates/candidate-5` |
| Nishfleet/TinyStudio.io | main | 24 | 2026-08-06T20:23:08+05:30 | skipped (main/master branch) | `/home/nish/workspaces/products/TinyStudio.io-agent-self-serve` |
| Nishfleet/TinyStudio.io | rescue/tinystudio-io-candidates-1-ace2eb53 | 20 | 2026-08-06T17:08:34+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-io-candidates-1` |
| Nishfleet/TinyStudio.io | rescue/tinystudio-io-candidates-2-2e0e4692 | 20 | 2026-08-06T17:06:02+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-io-candidates-2` |
| Nishfleet/TinyStudio.io | rescue/tinystudio-io-candidates-3-6091a189 | 20 | 2026-08-06T17:08:13+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-io-candidates-3` |
| Nishfleet/TinyStudio.io | rescue/tinystudio-io-candidates-4-7ba91802 | 20 | 2026-08-06T17:17:55+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/tinystudio-io-candidates-4` |
| Nishfleet/aiconverter-app | fix/admin-dodo-prices-auth-regression-20260813 | 1 | 2026-08-13T20:03:35+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-dodo-admin-auth-guard` |
| Nishfleet/aiconverter-app | lane1-customer-trials-20260823 | 1 | 2026-08-23T07:29:04+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260823-071036` |
| Nishfleet/aiconverter-app | lane1-indexnow-retire-e7a8c5a727-20260823 | 1 | 2026-08-23T12:26:18+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260823-121037` |
| Nishfleet/aiconverter-app | lane1-producthunt-betalist-20260817 | 1 | 2026-08-17T07:29:27+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260817-070547` |
| Nishfleet/aiconverter-app | lane1-tinylaunch-listing-20260823 | 2 | 2026-08-23T14:45:00+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260823-134544` |
| Nishfleet/aiconverter-app | lane1/bing-indexnow-20260814 | 31 | 2026-08-19T00:30:59+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260814-215532` |
| Nishfleet/aiconverter-app | lane1/capterra-vendor-retire-20260823 | 1 | 2026-08-23T10:43:53+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260823-073032` |
| Nishfleet/aiconverter-app | lane1/formats-blank-first-paint | 1 | 2026-08-20T17:16:50+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260820-163034` |
| Nishfleet/aiconverter-app | lane1/home-rendered-load-reverify-20260817 | 1 | 2026-08-17T15:33:45+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260817-151536` |
| Nishfleet/aiconverter-app | lane1/open-launch-listing-20260817-r2 | 1 | 2026-08-17T11:44:22+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260817-112035` |
| Nishfleet/aiconverter-app | lane1/serp-wedge-evidence-20260817 | 1 | 2026-08-17T06:57:14+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260817-063036` |
| Nishfleet/aiconverter-app | lane1/tinylaunch-listing-20260821 | 1 | 2026-08-21T07:22:39+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260821-061036` |
| Nishfleet/fleet-ops | claim/issue-20 | 1 | 2026-08-26T01:19:00+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/issue-fleet-ops-20` |
| Nishfleet/inish-site | gate/semgrep-actionlint-20260825 | 1 | 2026-08-25T00:22:57+05:30 | pushed | `/home/nish/workspaces/products/inish-site` |
| Nishfleet/inish-site | lane1-rollback-target-identity-20260823 | 2 | 2026-08-23T14:31:32+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/inish-site-lane1-20260823-135032` |
| Nishfleet/tinystudio-in | docs/lane1-google-ai-answers-brand-disambiguation-reverify-20260817 | 1 | 2026-08-17T15:32:35+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260817-151531` |
| Nishfleet/tinystudio-in | docs/lane3-brand-tagline-studio-pages-already-resolved-20260821 | 1 | 2026-08-21T15:23:47+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane3-20260821-142055` |
| Nishfleet/tinystudio-in | fix/ci-hermetic-cross-repo-service-contract | 1 | 2026-08-22T21:28:16+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-in-cross-repo-ci-20260822` |
| Nishfleet/tinystudio-in | fix/lane1-footer-tap-targets-reverify-20260817 | 1 | 2026-08-17T16:38:04+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260817-161532` |
| Nishfleet/tinystudio-in | fix/lane1-jsonld-live-guard-20260814 | 1 | 2026-08-14T15:55:13+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260814-153039` |
| Nishfleet/tinystudio-in | fix/lane1-sitemap-homepage-lastmod-guard-20260822 | 3 | 2026-08-22T16:22:08+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260822-151034` |
| Nishfleet/tinystudio-in | fix/llms-offer-desc-c2 | 1 | 2026-08-21T19:08:20+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tsin-llms-c2-045a1cf2` |
| Nishfleet/tinystudio-in | fix/llms-offer-desc-c3 | 1 | 2026-08-21T19:27:55+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tsin-llms-c3-045a1cf2` |
| Nishfleet/tinystudio-in | fix/llms-offer-desc-c5 | 1 | 2026-08-21T18:59:39+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tsin-llms-c5-045a1cf2` |
| Nishfleet/tinystudio-in | fix/operator-copy-offername-article-reverify-lane1-20260820 | 1 | 2026-08-20T22:58:00+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260820-224032` |
| Nishfleet/tinystudio-in | lane1/product-hero-early-access-cta-reverify-20260817 | 2 | 2026-08-17T07:01:41+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260817-063537` |
| Nishfleet/tinystudio-in | lane1/test-active-operator-surfaces-tracked-artifact | 1 | 2026-08-21T13:35:13+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260821-105534` |
| Nishfleet/tinystudio-in | lane1/tracked-artifact-clock-refusal | 1 | 2026-08-12T07:58:49+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260812-072031` |
| nish3451/0509 | recovery/0509-parity-2026-07-22 | 2 | 2026-07-22T13:00:29Z | pushed | `/home/nish/workspaces/recovery/0509-dirty-restored-20260726/0509` |
| nish3451/nish-vault | docs/fleet2-agentdrop-compaction-proposal-2026-08-20 | 3 | 2026-08-21T23:34:18+05:30 | pushed | `/home/nish/workspaces/tooling/nish-vault` |
| nish3451/seo-fix-kit | docs/lane1-deployed-walk-public-promise-drift-20260821 | 1 | 2026-08-21T06:34:02+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-20260821-061032` |
| nish3451/seo-fix-kit | fix/check-canonical-same-origin-true-lane1 | 1 | 2026-08-21T01:48:24+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-20260821-011535` |
| nish3451/seo-fix-kit | fix/seo-public-check-quota-bypass-survives | 1 | 2026-08-13T20:04:21+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-public-check-quota-bypass-survives` |
| nish3451/seo-fix-kit | growth/zaatar-pr-delivery-comparison-20260822 | 1 | 2026-08-22T06:32:25+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-20260822-062537` |
| nish3451/seo-fix-kit | lane1-geo-wiki-checker-listing-20260823 | 3 | 2026-08-23T06:03:54+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-20260823-044532` |
| nish3451/seo-fix-kit | lane1-rankora-anj-executive-artifact-20260823 | 2 | 2026-08-23T09:40:45+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-20260823-090534` |
| nish3451/seo-fix-kit | lane1/discovery-venues-reverify-20260820 | 1 | 2026-08-20T20:52:43+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-20260820-203536` |
| nish3451/seo-fix-kit | lane1/joshuaopolko-openaeo-audit-20260822 | 2 | 2026-08-22T17:09:27+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-20260822-162534` |
| nish3451/seo-fix-kit | lane1/promise-audit-20260820 | 1 | 2026-08-20T22:57:08+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-20260820-223531` |
| nish3451/seo-fix-kit | lane1/promise-audit-spotcheck-20260817 | 1 | 2026-08-17T11:14:31+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-20260817-105534` |
| nish3451/seo-fix-kit | lane1/verify-harvest-public-check-snippet-provenance-already-landed-20260820 | 1 | 2026-08-20T16:23:02+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-20260820-160045` |
| nish3451/seo-fix-kit | pr77-resolve-20260818 | 155 | 2026-08-19T02:36:50+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/pr77-jsonld-resolve` |
| nish3451/seo-fix-kit | seo-fix-kit/promise-audit-refine-2 | 137 | 2026-08-03T22:34:49+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-candidate-1` |
| nish3451/seo-fix-kit | seo-fix-kit/promise-audit-refine-2 | 137 | 2026-08-03T22:34:49+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-candidate-3` |
| nish3451/seo-fix-kit | seo-fix-kit/promise-audit-refine-2 | 137 | 2026-08-03T22:34:49+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-candidate-4` |
| nish3451/seo-fix-kit | seo-fix-kit/promise-audit-refine-2 | 137 | 2026-08-03T22:34:49+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-lane1-candidate-5` |
| nish3451/seo-fix-kit | seo-fix-kit/promise-audit-refine-2 | 137 | 2026-08-03T22:34:49+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-promise-refine-2` |
| nish3451/seo-fix-kit | seo-fix-kit/proof-receipt-2 | 139 | 2026-08-08T16:56:18+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-proof-receipt-2` |
| nish3451/seo-fix-kit | seo-fix-kit/proof-receipt-2 | 139 | 2026-08-08T16:56:18+05:30 | already on origin | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-proof-receipt-refine-2` |
| nish3451/seo-fix-kit | seo-fix-kit/proof-receipt-3 | 139 | 2026-08-08T16:56:18+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-proof-receipt-3` |
| nish3451/seo-fix-kit | seo-fix-kit/proof-receipt-4 | 139 | 2026-08-08T16:56:18+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-proof-receipt-4` |
| nish3451/seo-fix-kit | seo-fix-kit/proof-receipt-5 | 139 | 2026-08-08T16:56:18+05:30 | pushed | `/home/nish/workspaces/agent-worktrees/seo-fix-kit-proof-receipt-5` |

## 2. UU (unresolved merge conflict) worktrees

| Repo | Branch | Worktree |
|------|--------|----------|
| Nishfleet/0509 | fix/real-proof-public-surfaces | `/home/nish/workspaces/_claude-worktrees/0509-pr633` |
| Nishfleet/inish-site | fix/route-contract-single-source | `/home/nish/workspaces/agent-worktrees/inish-site-lane1-20260812-123533` |
| Nishfleet/siterep | fix/release-readiness-truth-20260819 | `/home/nish/workspaces/agent-worktrees/fleet2-20260819T054522-20260819T054522-f92cda7f` |
| nish3451/seo-fix-kit | codex/repair-sprint-checkout | `/home/nish/workspaces/products/proof-seo-repair-sprint-checkout` |
| nish3451/seo-fix-kit | seo-fix-kit/lane1-first-party-funnel-instrumentation | `/home/nish/workspaces/agent-worktrees/pr97-funnel-resolve-20260819` |

## 3. Worktrees proved fully landed (safe to reclaim)

| Repo | Branch | Reason | Worktree |
|------|--------|--------|----------|
| Nishfleet/0509 | 0509-lane1-published-prices-annual-toggle | PR #757 merged (cf896c5a is ancestor of origin/main) | `/home/nish/workspaces/agent-worktrees/0509-lane1-20260815-105032` |
| Nishfleet/0509 | chore/lane3-proof-captures-pricing-faq | PR #641 merged (33d8b3af is ancestor of origin/main) | `/home/nish/workspaces/agent-worktrees/0509-lane3-20260812-012031` |
| Nishfleet/0509 | docs/saashub-listing | git cherry found no unmatched `+` lines (squash/rebase merged) | `/home/nish/workspaces/agent-worktrees/0509-lane1-20260810-000031` |
| Nishfleet/0509 | feat/ci-failure-telemetry | 0 commits ahead of origin/main | `/home/nish/workspaces/_claude-worktrees/0509-ci-failure-telemetry` |
| Nishfleet/0509 | feat/free-tier-beats-free-alternatives | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/0509-lane2-20260812-011034` |
| Nishfleet/0509 | feat/fullsite-watch-change-analysis | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/fullsite-watch-change-analysis` |
| Nishfleet/0509 | feat/fullsite-watch-plan-metering | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/fullsite-watch-plan-metering` |
| Nishfleet/0509 | fix/brand-page-live-claim-one-clock | git cherry found no unmatched `+` lines (squash/rebase merged) | `/home/nish/workspaces/agent-worktrees/0509-routed-ng-room-reconcile-2026-08-14-sol-p-1786697543` |
| Nishfleet/0509 | fix/market-signal-auth-diagnosis | PR #890 merged (1d3267d6 is ancestor of origin/main) | `/home/nish/workspaces/agent-worktrees/0509-lane1-20260822-231532` |
| Nishfleet/0509 | fix/ratchet-monotonic | 0 commits ahead of origin/main | `/home/nish/workspaces/products/wt/ratchet-monotonic` |
| Nishfleet/0509 | fix/search-proof-capture-ssr-hydration-f2 | git cherry found no unmatched `+` lines (squash/rebase merged) | `/home/nish/workspaces/agent-worktrees/0509-pr625-f2-20260811-231105` |
| Nishfleet/0509 | loop/dynamic-brand-sitemap-c1-20260810 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/dynamic-brand-sitemap-1` |
| Nishfleet/0509 | loop/dynamic-brand-sitemap-c2-20260810 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/dynamic-brand-sitemap-2` |
| Nishfleet/0509 | loop/dynamic-brand-sitemap-c3-20260810 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/dynamic-brand-sitemap-3` |
| Nishfleet/0509 | loop/dynamic-brand-sitemap-c4-20260810 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/dynamic-brand-sitemap-4` |
| Nishfleet/0509 | loop/dynamic-brand-sitemap-c5-20260810 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/dynamic-brand-sitemap-5` |
| Nishfleet/0509 | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/0509-lane1-20260815-063532` |
| Nishfleet/0509 | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/0509-lane1-20260822-163031` |
| Nishfleet/0509 | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/search-structured-data-1` |
| Nishfleet/0509 | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/search-structured-data-2` |
| Nishfleet/0509 | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/search-structured-data-4` |
| Nishfleet/0509 | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/search-structured-data-5` |
| Nishfleet/0509 | main | 0 commits ahead of origin/main | `/home/nish/workspaces/products/0509` |
| Nishfleet/0509 | p10b/gate-integrity-detector | 0 commits ahead of origin/main | `/home/nish/workspaces/_claude-worktrees/0509-gate-integrity` |
| Nishfleet/0509 | quality/d1-integration-tests | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/0509-p10a-d1-integration` |
| Nishfleet/TinyStudio.io | fix/sol-postmerge-165-usage-on-503 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-io-routed-ng-room-reconcile-2026-08-14-sol-p-1786710665` |
| Nishfleet/TinyStudio.io | improve/repository-product-contract-a121ce8c | PR #58 merged (11864a76 is ancestor of origin/main) | `/home/nish/workspaces/agent-worktrees/tinystudio-io-lane1-20260810-004533` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-correction-1` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-correction-2` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-correction-3` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-correction-4` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-correction-5` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-entity-1` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-entity-2` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-entity-4` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-ai-entity-5` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-heading-hierarchy-1` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-heading-hierarchy-2` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-heading-hierarchy-3` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-heading-hierarchy-4` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-heading-hierarchy-5` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-io-sitemap-1` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-io-sitemap-2` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-io-sitemap-3` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-io-sitemap-4` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-io-sitemap-5` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-llms-1` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-llms-3` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-llms-4` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-llms-5` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-meta-description-1` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-meta-description-2` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-meta-description-3` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-meta-description-4` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-meta-description-5` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-name-1` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-name-2` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-name-3` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-name-4` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-name-5` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-render-blocking-1` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-render-blocking-2` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-render-blocking-3` |
| Nishfleet/TinyStudio.io | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-render-blocking-5` |
| Nishfleet/TinyStudio.io | test/pr159-audit-cta-guard | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-io-routed-ng-room-reconcile-2026-08-14-sol-p-1786701791` |
| Nishfleet/aiconverter-app | codex/aiconverter-landing-copy | 0 commits ahead of origin/main | `/home/nish/workspaces/products/_codex-worktrees/2026-05-27-aiconverter-landing-copy` |
| Nishfleet/aiconverter-app | codex/fal-founder-videos | 0 commits ahead of origin/main | `/home/nish/workspaces/products/aiconverter-app-fal-founder-videos` |
| Nishfleet/aiconverter-app | codex/photo-ad-video-lab | 0 commits ahead of origin/main | `/home/nish/workspaces/products/_codex-worktrees/2026-05-31-aiconverter-photo-ad-lab` |
| Nishfleet/aiconverter-app | lane1/flowparse-wedge-proof-20260823 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260823-123533` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-app-candidate-first-run-1` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-app-candidate-first-run-3` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-app-candidate-first-run-4` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-app-candidate-first-run-5` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-app-receipt-candidate-1` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-app-receipt-candidate-2` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-app-receipt-candidate-3` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-app-receipt-candidate-5` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-candidate-formats-1` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-candidate-formats-2` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-candidate-formats-3` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-candidate-formats-4` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-candidate-formats-5` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-formats-1` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-formats-2` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-formats-3` |
| Nishfleet/aiconverter-app | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/aiconverter-formats-4` |
| Nishfleet/fleet-ops | claim/issue-21 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/issue-fleet-ops-21` |
| Nishfleet/fleet-ops | claim/issue-72 | git cherry found no unmatched `+` lines (squash/rebase merged) | `/home/nish/workspaces/tooling/fleet-ops-deploy` |
| Nishfleet/fleet2 | audition/ollama-gemma4-31b-20260819 | 0 commits ahead of origin/main | `/home/nish/workspaces/fleet2-wt/gemma4-31b` |
| Nishfleet/fleet2 | audition/ollama-mistral-large-3-675b-20260819 | 0 commits ahead of origin/main | `/home/nish/workspaces/fleet2-wt/mistral-large-3-675b` |
| Nishfleet/fleet2 | watchdog-memory-2026-08-18 | 0 commits ahead of origin/main | `/home/nish/workspaces/fleet2-wt/memory` |
| Nishfleet/fleet2 | watchdog-restore-drill-2026-08-18 | 0 commits ahead of origin/main | `/home/nish/workspaces/fleet2-wt/restore-drill` |
| Nishfleet/inish-site | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/inish-site-canonical-source-3` |
| Nishfleet/inish-site | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/inish-site-lane1` |
| Nishfleet/inish-site | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/inish-site-live-delivery-2` |
| Nishfleet/inish-site | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/inish-site-live-delivery-3` |
| Nishfleet/siterep | candidate/buyer-cta-c1 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-buyer-cta-c1` |
| Nishfleet/siterep | candidate/buyer-cta-c2 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-buyer-cta-c2` |
| Nishfleet/siterep | candidate/buyer-cta-c3 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-buyer-cta-c3` |
| Nishfleet/siterep | candidate/buyer-cta-c4 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-buyer-cta-c4` |
| Nishfleet/siterep | candidate/buyer-cta-c5 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-buyer-cta-c5` |
| Nishfleet/siterep | candidate/honesty-c1 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-honesty-c1` |
| Nishfleet/siterep | candidate/honesty-c2 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-honesty-c2` |
| Nishfleet/siterep | candidate/honesty-c3 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-honesty-c3` |
| Nishfleet/siterep | candidate/honesty-c4 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-honesty-c4` |
| Nishfleet/siterep | candidate/honesty-c5 | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-honesty-c5` |
| Nishfleet/siterep | codex/siterep-launch-hardening | 0 commits ahead of origin/main | `/home/nish/workspaces/products/_codex-worktrees/2026-07-13-siterep-launch-hardening` |
| Nishfleet/siterep | growth/mcp-origin-attribution-20260808 | git cherry found no unmatched `+` lines (squash/rebase merged) | `/home/nish/workspaces/agent-worktrees/siterep-lane1-c4` |
| Nishfleet/siterep | lane1/docs-install-activation-reverify-20260814 | git cherry found no unmatched `+` lines (squash/rebase merged) | `/home/nish/workspaces/agent-worktrees/siterep-lane1-20260814-104533` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/mcp-acquisition-c1` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/mcp-acquisition-c2` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/mcp-acquisition-c3` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-thin-home-c1` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-thin-home-c2` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-thin-home-c3` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/siterep-thin-home-c5` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-candidate-6` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-candidate-7` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-candidate-9` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-comparison-cta-c1` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-comparison-cta-c2` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-comparison-cta-c4` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-comparison-cta-c5` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-cta-followup-c1` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-cta-followup-c2` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-cta-followup-c3` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-cta-followup-c4` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-free-start/candidate-2` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-free-start/candidate-3` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-free-start/candidate-4` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-free-start/candidate-5` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-lane1` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-lane1-c1` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-lane1-c2` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-lane1-c3` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-paid-setup-c2` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-paid-setup-c3` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-paid-setup-c4` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-paid-setup-c5` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-price-candidate-1` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-price-candidate-2` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-price-candidate-3` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-price-candidate-5` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-refine-11` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-refine-12` |
| Nishfleet/siterep | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/siterep-shell-min-320-fix-20260813` |
| Nishfleet/siterep-public | ci/visual-check | 0 commits ahead of origin/main | `/home/nish/workspaces/products/siterep-public-vc` |
| Nishfleet/siterep-public | main | 0 commits ahead of origin/main | `/home/nish/workspaces/products/siterep-public` |
| Nishfleet/tinystudio-in | fix/public-structured-data | git cherry found no unmatched `+` lines (squash/rebase merged) | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260808-133036` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-attempt-1` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-attempt-2` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-attempt-3` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-attempt-4` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-attempt-5` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-final-repair` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-heading-1` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-heading-2` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-heading-3` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-heading-4` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-heading-5` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-heading-refine-1` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-heading-refine-2` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-refine-1` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/candidates/tinystudio-in-refine-2` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-deadline-candidate-1` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-deadline-candidate-2` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-deadline-candidate-4` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-gate-c1` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-gate-c2` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-gate-c3` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-gate-c4` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-gate-c5` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-in-7442-attempt-1` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-in-7442-attempt-2` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-in-7442-attempt-3` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-in-7442-attempt-4` |
| Nishfleet/tinystudio-in | main | 0 commits ahead of origin/main | `/home/nish/workspaces/agent-worktrees/tinystudio-in-7442-attempt-5` |
| nish3451/0509 | fix/review-2026-07-19 | PR #354 merged (2a6c6de2 is ancestor of origin/main) | `/home/nish/workspaces/recovery/mac-mirror-2026-07-22/0509` |
| nish3451/0509 | recovery/0509-parity-2026-07-22 | 0 commits ahead of origin/main | `/home/nish/workspaces/recovery/0509-dirty-operational-20260726` |
| nish3451/Drishti-Mindful-Screen-Time | fix/secret-scan-gitleaks-checkout-collision | 0 commits ahead of origin/main | `/home/nish/workspaces/products/Drishti - Mindful Screen Time` |
| nish3451/HotelDealsApp | fix/secret-scan-gitleaks-checkout-collision | 0 commits ahead of origin/main | `/home/nish/workspaces/products/HotelDealsApp` |
| nish3451/Promptly | fix/secret-scan-gitleaks-checkout-collision | 0 commits ahead of origin/main | `/home/nish/workspaces/products/Promptly` |
| nish3451/VibecodedProjects | fix/secret-scan-gitleaks-checkout-collision | 0 commits ahead of origin/main | `/home/nish/workspaces/products/VibecodedProjects` |
| nish3451/fleet-console-worker | main | 0 commits ahead of origin/main | `/home/nish/workspaces/tooling/fleet-console-worker` |
| nish3451/memory-compound | fix/test-suite-proof-contract | git cherry found no unmatched `+` lines (squash/rebase merged) | `/home/nish/workspaces/tooling/memory-compound` |
| nish3451/seo-fix-kit | lane1/public-pages-svg-social-images | PR #142 merged (fa0d6f95 is ancestor of origin/main) | `/home/nish/workspaces/agent-worktrees/fleet-review-seo-fix-kit-pr142-6e54da1b7e9f600e2e54cc802f238652520f5c93-deepseek/repo` |
| nish3451/seo-fix-kit | main | 0 commits ahead of origin/main | `/home/nish/workspaces/products/proof-seo` |

## 4. Errors / skipped

| Repo | Branch | Reason | Worktree |
|------|--------|--------|----------|
|  |  | no origin remote | `/home/nish/workspaces/agent-worktrees/free-pool-e2e-20260821T101759` |
|  |  | no origin remote | `/home/nish/workspaces/fleet-knowledge-base` |
| Nishfleet/0509 | chore/ci-github-hosted-runners | 11 commits ahead; push failed: To https://github.com/Nishfleet/0509.git  ! [rejected]          chore/ci-github-hosted-runners -> chore/ci-github-hosted-runners (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/0509.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/0509-ci-hosted` |
| Nishfleet/0509 | feat/competitor-site-schema-20260810 | 1 commits ahead; push failed: To https://github.com/Nishfleet/0509.git  ! [rejected]          feat/competitor-site-schema-20260810 -> feat/competitor-site-schema-20260810 (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/0509.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/0509-competitor-site-schema-20260810-2105` |
| Nishfleet/0509 | feat/slack-teams-webhook-delivery | 93 commits ahead; push failed: To https://github.com/Nishfleet/0509.git  ! [rejected]          feat/slack-teams-webhook-delivery -> feat/slack-teams-webhook-delivery (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/0509.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/0509-lane1-20260812-000532` |
| Nishfleet/aiconverter-app | lane1/bing-indexnow-20260820 | 1 commits ahead; push failed: To https://github.com/Nishfleet/aiconverter-app.git  ! [rejected]        lane1/bing-indexnow-20260820 -> lane1/bing-indexnow-20260820 (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/aiconverter-app.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260820-235039` |
| Nishfleet/aiconverter-app | lane1/futurepedia-taaft-dang-20260820 | 1 commits ahead; push failed: To https://github.com/Nishfleet/aiconverter-app.git  ! [rejected]        lane1/futurepedia-taaft-dang-20260820 -> lane1/futurepedia-taaft-dang-20260820 (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/aiconverter-app.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/aiconverter-app-lane1-20260820-204032` |
| Nishfleet/siterep | disclose-ai-visitor | 1 commits ahead; push failed: remote: This repository was archived so it is read-only. fatal: unable to access 'https://github.com/Nishfleet/siterep.git/': The requested URL returned error: 403 | `/home/nish/workspaces/agent-worktrees/siterep-lane1-20260821-233039` |
| Nishfleet/siterep | lane1/producthunt-manual-reminder-20260821 | 2 commits ahead; push failed: remote: This repository was archived so it is read-only. fatal: unable to access 'https://github.com/Nishfleet/siterep.git/': The requested URL returned error: 403 | `/home/nish/workspaces/agent-worktrees/siterep-lane1-20260821-210048` |
| Nishfleet/siterep | lane1/vs-webspeaker-20260819 | 4 commits ahead; push failed: remote: This repository was archived so it is read-only. fatal: unable to access 'https://github.com/Nishfleet/siterep.git/': The requested URL returned error: 403 | `/home/nish/workspaces/agent-worktrees/fleet2-20260819T054522-20260819T054522-38026b88` |
| Nishfleet/tinystudio-in | chore/refresh-msp-aware-market-benchmark-lane1 | 26 commits ahead; push failed: To https://github.com/Nishfleet/tinystudio-in.git  ! [rejected]          chore/refresh-msp-aware-market-benchmark-lane1 -> chore/refresh-msp-aware-market-benchmark-lane1 (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/tinystudio-in.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260811-232532` |
| Nishfleet/tinystudio-in | chore/refresh-msp-aware-market-benchmark-lane1 | 26 commits ahead; push failed: To https://github.com/Nishfleet/tinystudio-in.git  ! [rejected]          chore/refresh-msp-aware-market-benchmark-lane1 -> chore/refresh-msp-aware-market-benchmark-lane1 (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/tinystudio-in.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/tinystudio-in-pr93-resolve` |
| Nishfleet/tinystudio-in | fix/lane1-live-deploy-verifier-restore | 2 commits ahead; push failed: To https://github.com/Nishfleet/tinystudio-in.git  ! [rejected]          fix/lane1-live-deploy-verifier-restore -> fix/lane1-live-deploy-verifier-restore (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/tinystudio-in.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260820-194032` |
| Nishfleet/tinystudio-in | fix/lane1-llms-txt-description-names-managed-service-20260822 | 2 commits ahead; push failed: To https://github.com/Nishfleet/tinystudio-in.git  ! [rejected]          fix/lane1-llms-txt-description-names-managed-service-20260822 -> fix/lane1-llms-txt-description-names-managed-service-20260822 (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/tinystudio-in.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260822-081032` |
| Nishfleet/tinystudio-in | fix/lane1-reaffirm-no-editorial-copy-on-public | 1 commits ahead; push failed: To https://github.com/Nishfleet/tinystudio-in.git  ! [rejected]          fix/lane1-reaffirm-no-editorial-copy-on-public -> fix/lane1-reaffirm-no-editorial-copy-on-public (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/tinystudio-in.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260820-203031` |
| Nishfleet/tinystudio-in | fix/llms-offer-desc-c4 | 1 commits ahead; push failed: To https://github.com/Nishfleet/tinystudio-in.git  ! [rejected]          fix/llms-offer-desc-c4 -> fix/llms-offer-desc-c4 (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/tinystudio-in.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/tsin-llms-c4-045a1cf2` |
| Nishfleet/tinystudio-in | fix/operator-copy-offer-article | 1 commits ahead; push failed: To https://github.com/Nishfleet/tinystudio-in.git  ! [rejected]          fix/operator-copy-offer-article -> fix/operator-copy-offer-article (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/tinystudio-in.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260811-235532` |
| Nishfleet/tinystudio-in | lane1-llms-txt-website-correction | 1 commits ahead; push failed: To https://github.com/Nishfleet/tinystudio-in.git  ! [rejected]          lane1-llms-txt-website-correction -> lane1-llms-txt-website-correction (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/tinystudio-in.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260823-080533` |
| Nishfleet/tinystudio-in | lane1-schema-knowsabout-service-20260823 | 1 commits ahead; push failed: To https://github.com/Nishfleet/tinystudio-in.git  ! [rejected]          lane1-schema-knowsabout-service-20260823 -> lane1-schema-knowsabout-service-20260823 (non-fast-forward) error: failed to push some refs to 'https://github.com/Nishfleet/tinystudio-in.git' hint: Updates were rejected because the tip of your current branch is behind hint: its remote counterpart. If you want to integrate the remote changes, hint: use 'git pull' before pushing again. hint: See the 'Note about fast-forwards' in 'git push --help' for details. | `/home/nish/workspaces/agent-worktrees/tinystudio-in-lane1-20260823-094034` |
| andrewyng/context-hub | fix-multifile-output-empty-land | 1 commits ahead; push failed: remote: Permission to andrewyng/context-hub.git denied to nish3451. fatal: unable to access 'https://github.com/andrewyng/context-hub.git/': The requested URL returned error: 403 | `/home/nish/workspaces/tooling/context-hub-land` |
| andrewyng/context-hub | gate/semgrep-actionlint-20260825 | 1 commits ahead; push failed: remote: Permission to andrewyng/context-hub.git denied to nish3451. fatal: unable to access 'https://github.com/andrewyng/context-hub.git/': The requested URL returned error: 403 | `/home/nish/workspaces/tooling/context-hub` |
| code-yeongyu/codex-lsp | chore/bump-submodule-gitignore-fix | 1 commits ahead; push failed: remote: Permission to code-yeongyu/codex-lsp.git denied to nish3451. fatal: unable to access 'https://github.com/code-yeongyu/codex-lsp.git/': The requested URL returned error: 403 | `/home/nish/workspaces/tooling/codex-lsp` |
| codejunkie99/sageroute | pr-1 | 18 commits ahead; push failed: remote: Permission to codejunkie99/sageroute.git denied to nish3451. fatal: unable to access 'https://github.com/codejunkie99/sageroute.git/': The requested URL returned error: 403 | `/home/nish/workspaces/tooling/sageroute-reference` |
| mvanhorn/last30days-skill | smoke-839 | 3 commits ahead; push failed: remote: Permission to mvanhorn/last30days-skill.git denied to nish3451. fatal: unable to access 'https://github.com/mvanhorn/last30days-skill.git/': The requested URL returned error: 403 | `/home/nish/workspaces/tooling/last30days-skill` |
| nish3451/seo-fix-kit | codex/seofixkit-gate-0 | 135 commits ahead; push failed: remote: error: GH007: Your push would publish a private email address.         remote: You can make your email public or disable this protection by visiting:         remote: https://github.com/settings/emails         To https://github.com/nish3451/seo-fix-kit.git  ! [remote rejected] codex/seofixkit-gate-0 -> codex/seofixkit-gate-0 (push declined due to email privacy restrictions) error: failed to push some refs to 'https://github.com/nish3451/seo-fix-kit.git' | `/home/nish/workspaces/products/_codex-worktrees/2026-07-13-seofixkit-gate-0` |

## Method

Protocol followed, in order:
1. `git rev-list --count origin/main..<branch>` == 0; else
2. `git cherry origin/main <branch>` has no `+` lines; else
3. A PR for `<branch>` is `MERGED` and `git merge-base --is-ancestor <mergeCommit> origin/main` succeeds.

The first passing check proves the branch is fully landed.
Branches failing all three are genuinely unlanded and are pushed to origin so they become visible to other agents.
No worktree was deleted, stashed, or had changes reverted during this run.
