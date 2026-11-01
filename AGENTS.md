# Agent notes for fleet-ops

Stock features only. FINAL, Nish 2026-11-01: every home-built recipe, wrapper,
listener, watcher, scorer, sync unit, hand-off prompt, custom gate or policy was
deleted in favour of the vendor's own feature, and none comes back. A PR that adds
a workflow, unit, timer, script, plugin, prompt or gate is wrong unless it names, in
the PR body, the vendor doc showing stock cannot do it today. Changes under
`.github/`, `ansible/`, `systemd/`, `rootfs/`, `containers/`, `config/`, `infra/`
need Nish's approval (CODEOWNERS); the reviewer App covers the rest.

## How this repo works

- One worker lane: `.github/workflows/agent.yml`. An issue labelled `agent-ready`
  starts one worker on a box runner (user `fleet-runner`), the worker opens one PR,
  CI runs, the reviewer App reviews, the merge queue merges, `deploy-box.yml` applies
  the host play on merge. Product repos call the lane with a 10-line
  `workflow_call` stub.
- CI is `.github/workflows/ci.yml`, under 50 lines, hosted runners: host-play syntax,
  unit-file verify, python-only tests under `tests/`, actionlint. A check that goes red
  for a reason other than the change is deleted, not patched.
- The box is `ansible/host.yml`, applied by `ansible-pull` on every merge to main and
  nightly. Anything on the box that is not in the play comes back from the play.
- Alerts are symptoms only (site down, deploy failed, backup or restore failed,
  error spike), under 10 rules, and open issues the lane fixes.
- Kept on purpose: Tailscale SSH, unattended-upgrades, fail2ban, restic drills,
  Prometheus and Grafana (stock dashboards), Hermes on its own installer, Remote
  Control, Tether (a product), the LiteLLM router with plain rows for the paid seats.

Before any change, read the vendor's docs for the feature you touch and name them in
the PR body. Full rules: the vault `_system/shared-memory/global-standing-rules.md`.
