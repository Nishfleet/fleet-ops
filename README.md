# fleet-ops

The fleet's operational surface under version control: systemd user units,
shell scripts, and Pi prompts that run on Nish's VPS. CI-gated so no unit,
script, or prompt lands unseen.

How the fleet runs, in one page: [docs/README.md](docs/README.md).

One doc per topic under `docs/`. Add new operational prose to the topic's own
file, not here.

- [Install](docs/install.md)
- [systemd by default](docs/systemd-by-default.md)
- [Daily update](docs/daily-update.md)
- [Mac daily update](docs/mac-daily-update.md)
- [Remote Control](docs/remote-control.md)
- [Managed-settings defaults](docs/managed-settings-defaults.md)
- [Agent autonomy drop-in](docs/agent-autonomy-drop-in.md)
- [claude.ai connectors off on the server](docs/claudeai-connectors-off.md)
- [Browser tool](docs/browser-tool.md)
- [Drive filesystem server](docs/drive-filesystem-server.md)
- [Triage admission](docs/triage-admission.md)
- [Private detail scan](docs/private-detail-scan.md)
- [Router notes](docs/litellm-router-notes.md)
- [Cloudflare credentials](docs/cloudflare-credentials.md)
- [D1 migrations](docs/d1-migrations.md) and [D1 backup](docs/d1-backup-mechanism.md)

Recovery steps: [docs/RUNBOOK.md](docs/RUNBOOK.md). Postmortems stay in
[docs/incidents/](docs/incidents/).

## Tincan relay approval policy

The relay's `approval.json` was made by hand on the box on 2026-10-22 and nothing in the repo
said what the gate was (fleet-ops#9979). It is now rendered from one roster, so adding an agent
is one line and updates every gate at once.

- `config/tincan-relay/agents.txt` is the roster of our agents. `config/tincan-relay/policy.jq`
  renders the policy from it with stock `jq`: every roster agent gets a gate whose `unless` list
  is the roster plus the relay, so a request whose chain names any other agent is held for 24 hours
  and reported to the notify target. The render has no secrets (agent names, a notify target, a ttl).
- `ansible/tasks/tincan-relay-policy.yml` (run by `ansible/host.yml`) renders the file and installs it at
  `~/.local/state/tincan-relay/approval.json` (0600) through the copy module's `validate:`, so a
  render that is not JSON or not a gate fails the run before it replaces the live file (an empty
  gate turns the gate off and a malformed one makes the relay refuse new sends). It also fails when the roster names an agent the relay does not have.
- The locked listener unit itself is already in the repo and installed by the host playbook:
  `rootfs/etc/systemd/system/tincan-listen-claude-vps.service` (fleet-ops#9985).
- The daily update (`ansible/update.yml`) restarts that system unit
  after a tincan upgrade once its control group holds only its own process, as root.
- Install or re-run: `sudo systemctl start fleet-host-config.service`. Read it:
  `jq . ~/.local/state/tincan-relay/approval.json`. Live agents:
  `tincan agents --json --socket ~/.local/state/tincan-relay/admin.sock`.
- Rollback: delete `approval.json` (the gate is off, as before 2026-10-22), then delete
  `config/tincan-relay/` and `ansible/tasks/tincan-relay-policy.yml` in a PR.
- Tests: `tests/test_tincan_relay_policy.py` (roster is clean, policy renders, loud check exit
  codes, installed bytes equal the render).
