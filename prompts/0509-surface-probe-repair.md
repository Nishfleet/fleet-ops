The 0509 authenticated surface-matrix probe failed. Diagnose and act. Never page or message Nish. Never print secrets.

Evidence:
- journalctl --user -u 0509-surface-probe.service -n 80
- The probe run log: /tmp/0509-surface-probe-run.log (the full Playwright + dev-server output)
- The exported metrics: cat /var/lib/prometheus/node-exporter/fleet-surface-probe-0509.prom
- The consecutive-failure state: cat /home/nish/.local/state/0509-surface-probe/state

What the probe does: it resets a dedicated checkout at /home/nish/workspaces/0509-probe to 0509 origin/main, runs `npx playwright test --project=local-auth --grep "surface audit"` (the routes × {390,1440,2000} × {light,dark} × {free,scout,starter,agency,expired} matrix from e2e/surface-audit.mjs), and exports fleet_probe_success. A failure means a real defect shipped to 0509 main — the matrix is deterministic rules only (contrast, control-row alignment, gutter, overflow, tap targets, focus rings), no model.

Diagnose:
1. Is it a flake or a real regression? Re-run the probe once: `bash /home/nish/.local/bin/0509-surface-probe`. If it passes, the failure was transient (dev-server boot race, port collision, network blip on git fetch) — leave a note in the run log and exit 0. If it fails again, it is a real regression on shipped 0509 main.
2. If real: read /tmp/0509-surface-probe-run.log for the failing rule, route, theme, viewport and fixture tier. The matrix prints the exact cell and the rule it violated.
3. Identify the 0509 commit that introduced the defect: `cd /home/nish/workspaces/0509-probe && git log --oneline -20 origin/main` and cross-reference with the failing surface. The probe resets to origin/main every run, so the failing commit is recent main.
4. File the defect as a NEW issue in Nishfleet/0509 (plain, no labels) with the failing cell, the rule, the run-log tail, and the suspected commit. Do NOT fix it here — this is the fleet-ops repo, the defect is in 0509. Use `fleet-issue-file file -R Nishfleet/0509 --title "SURFACE: <rule> failing on <route> in <theme> at <viewport> for <tier>" --body "<evidence, run-log tail, no secrets>"`.
5. If the probe cannot run at all (exit 2 — checkout missing, npm install failed, node/npm missing), that is a probe-organ failure, not a 0509 regression. Repair the organ: re-provision the checkout (`git clone https://github.com/Nishfleet/0509.git /home/nish/workspaces/0509-probe && cd /home/nish/workspaces/0509-probe && npm install --ignore-scripts && npx playwright install chromium`), then re-run the probe to green.

Constraints:
- Never page, email, or message Nish.
- Never print secrets or credential values.
- Never push to 0509 main, never deploy, never run `npm run deploy`. The probe observes; the defect is fixed by a 0509 PR through normal review, not from here.
- A 0509 surface defect is filed as a new issue, not fixed in this repo.
- Exit nonzero if the probe is still failing when you finish.
