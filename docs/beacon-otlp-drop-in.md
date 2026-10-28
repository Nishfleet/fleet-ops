## Beacon OTLP drop-in

`rootfs/etc/claude-code/managed-settings.d/70-beacon-otlp.json` is a managed-settings
drop-in that carries only Beacon's OpenTelemetry `env` keys (telemetry on, OTLP gRPC to
`127.0.0.1:4317`, logs and metrics exporters, tool details and prompts). It exists because
worker lanes run `--setting-sources project,local` and so never read `~/.claude/settings.json`
where those keys live; managed settings are read whatever `--setting-sources` says, and the
`env` block merges key by key with `/etc/claude-code/managed-settings.json`. It carries no
hooks: workers keep `disableAllHooks`. Scope: every Claude Code process on the box, including
`retro-weekly`, which runs without a network namespace to the host, so its exports fail
locally and harmlessly. Nothing leaves the box: the endpoint is loopback and Beacon's
collector only writes `~/.beacon/endpoint/logs/runtime.jsonl` (mode 0600).

- Verify: a worker-style run (`claude -p --setting-sources project,local --settings
  '{"disableAllHooks":true}'`) that runs `echo MARKER` leaves `claude_code` `otlp` lines
  with that marker in `~/.beacon/endpoint/logs/runtime.jsonl`.
- Switch it off: fast, `sudo rm /etc/claude-code/managed-settings.d/70-beacon-otlp.json`
  (takes effect for the next Claude Code launch; running sessions keep their start-up values;
  the next `fleet-host-config.service` run puts the file back until a PR retires it). Durable:
  a PR that deletes the file from `rootfs/` and adds its `/etc` path to `retired` in
  `ansible/host.yml`.

