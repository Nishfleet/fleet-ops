# fleet-ops

The fleet's operational surface under version control: systemd user units,
shell scripts, and Pi prompts that run on Nish's VPS. CI-gated so no unit,
script, or prompt lands unseen.

One doc per topic under `docs/`. Each topic below was a README section; add new
operational prose to the topic's own file, not here.

- [What lives here](docs/layout.md)
- [Install](docs/install.md)
- [systemd by default](docs/systemd-by-default.md)
- [Claim shared files before editing (interactive sessions)](docs/claim-shared-files.md)
- [Daily update](docs/daily-update.md)
- [Mac daily update](docs/mac-daily-update.md)
- [Daily digest prompts and the waiting count (fleet-ops#10072)](docs/digest-prompts.md)
- [Tether: our own always-on agent (fleet-ops#9980)](docs/tether.md)
- [Agent lock (fleet-ops#9977)](docs/agent-lock.md)
- [Remote Control stays on (OOM storm 2026-10-09)](docs/remote-control.md)
- [Managed-settings defaults](docs/managed-settings-defaults.md)
- [Agent autonomy drop-in](docs/agent-autonomy-drop-in.md)
- [Beacon OTLP drop-in](docs/beacon-otlp-drop-in.md)
- [Claude plugin drop-ins](docs/claude-plugin-drop-ins.md)
- [claude.ai connectors off on the server](docs/claudeai-connectors-off.md)
- [Browser tool: Chrome DevTools MCP](docs/browser-tool.md)
- [Drive filesystem server](docs/drive-filesystem-server.md)
- [CI](docs/ci.md)
- [Allowlist](docs/allowlist.md)
- [Intake enrolment](docs/intake-enrolment.md)
- [Triage admission (needs-triage)](docs/triage-admission.md)
- [Red main issues](docs/red-main-issues.md)
- [Workflow notes](docs/workflow-notes.md)
- [Worker capacity](docs/worker-capacity.md)
- [Private detail scan](docs/private-detail-scan.md)
- [Provider watch](docs/provider-watch.md)

Design and enforced rules: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Recovery steps:
[docs/RUNBOOK.md](docs/RUNBOOK.md).

## Tincan relay approval policy

The relay's `approval.json` was made by hand on the box on 2026-10-22 and nothing in the repo
said what the gate was (fleet-ops#9979). It is now rendered from one roster, so adding an agent
is one line and updates every gate at once.

- `config/tincan-relay/agents.txt` is the roster of our agents. `config/tincan-relay/policy.jq`
  renders the policy from it with stock `jq`: every roster agent gets a gate whose `unless` list
  is the roster plus the relay, so a request whose chain names any other agent is held for 24 hours
  and reported to Hermes. The render has no secrets (agent names, a notify target, a ttl).
- `ansible/tasks/tincan-relay-policy.yml` (run by `ansible/host.yml`) renders the file, installs it at
  `~/.local/state/tincan-relay/approval.json` (0600), reads it back, and fails the run when it is
  missing, not JSON, or not a gate: a missing file turns the gate off and a malformed one makes the
  relay refuse new sends. It also fails when the roster names an agent the relay does not have.
- The daily update (`ansible/update.yml`) restarts the system-unit `tincan-listen-claude-vps.service`
  after a tincan upgrade once its control group holds only its own process, as root.
- Install or re-run: `sudo systemctl start fleet-host-config.service`. Read it:
  `jq . ~/.local/state/tincan-relay/approval.json`. Live agents:
  `tincan agents --json --socket ~/.local/state/tincan-relay/admin.sock`.
- Rollback: delete `approval.json` (the gate is off, as before 2026-10-22), then delete
  `config/tincan-relay/` and `ansible/tasks/tincan-relay-policy.yml` in a PR.
- Tests: `tests/test_tincan_relay_policy.py` (roster is clean, policy renders, loud check exit
  codes, installed bytes equal the render).
