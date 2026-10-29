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
