## Summary

`install.sh --system` copied `config/fleet_rules.yml` to `/etc/prometheus/fleet_rules.yml` but only ran `sudo systemctl daemon-reload` (systemd, not Prometheus). Prometheus re-reads its rule files only on `systemctl reload prometheus` (ExecReload is `kill -HUP`), so a merged alert rule sat on disk until the next Prometheus restart or a manual reload — the same gap as ConsoleLying (#1157) and FleetGhCacheStale (#1232 / PR #1305).

After a `--system` copy of `fleet_rules.yml`:
- Byte-compare the live file to the repo copy **before** `install -D`. Only when the bytes actually changed, `sudo systemctl reload prometheus` (guarded on `is-active --quiet prometheus`).
- Prove every group named in the installed file is present in `GET /api/v1/rules` (`prove_rules_loaded`). A group that fails to parse never loads; Prometheus keeps serving the old rules. The proof fails `install.sh --system` loudly (rc=1) instead of silently serving stale rules.
- Skip the reload when the file bytes did not change (no wasted HUP on a byte-identical re-install).

`PM_RULES_FILE` and `PM_RULES_URL` env overrides let tests point the proof at a scratch file and a `file://` stub of the rules API without touching `/etc` or the real daemon.

## Verification

Ran the new drill and the nested CI host end-to-end:

```
$ bash tests/install-prometheus-rules-reload.test.sh
OK: install.sh carries the prometheus reload + rules-proof seam (fleet-ops#1307)
OK: scenario A: changed fleet_rules.yml reloads prometheus and the proof passes
OK: scenario B: byte-identical fleet_rules.yml skips the prometheus reload
OK: scenario C: an unloaded group fails install.sh --system loudly
OK: install.sh --system reloads prometheus and proves fleet_rules.yml groups (fleet-ops#1307)
exit 0

$ bash tests/rule-enforcement.test.sh   # nests the new drill
... OK: rule-enforcement: install prometheus rules-reload drill
exit 0

$ bash tests/fleet-ops-deploy.test.sh    # exercises install.sh --system path
... OK: scenario18: deploy invokes install.sh then install.sh --system
... OK: fleet-ops deploy step: install, drift detection, merge, and canary pass offline
exit 0
```

Scenario A: a changed `fleet_rules.yml` triggers `sudo systemctl reload prometheus` and the proof reports the loaded groups (exit 0). Scenario B: a byte-identical re-install skips the reload (no HUP). Scenario C: a group missing from the rules API makes `install.sh --system` exit rc=1 with a loud `rules proof failed` line — fail-closed, so a parse error cannot silently drop a new alert group.

Closes #1307
