There is no dispatch wrapper. Call `pi` directly:

```
pi --print --provider <provider> --model <model>
```

Prompt goes on stdin. Pi rejects a `--` end-of-options flag.

For work that must outlive this session, use `pi-systemd-run`, never
`nohup pi ... &` — the launching shell reaps a nohup'd child and leaves
dead-seat EXTLOAD lines. `pi-systemd-run --unit <name> --stdin <packet.md>
-- pi --print --provider <provider> --model <model>` (a thin
`systemd-run --user --collect --no-block` wrapper; not a dispatcher).
Canonical wording: fleet-ops README and `prompts/heartbeat.md`.
