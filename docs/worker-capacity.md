## Worker capacity

The concurrency bound is the runner count (#8429): 10 `agent` runners
(`actions.runner.Nishfleet.netcup-agent-1..10` in org runner group 3, shared
by every enrolled repo including drive since 2026-10-06; live count:
`gh api orgs/Nishfleet/actions/runner-groups/3/runners --jq .total_count`;
sized from measured memory pressure, fleet-ops#8860), all in `agent.slice` (`rootfs/etc/systemd/system/agent.slice`,
26G/28G, `MemorySwapMax=1G`). RAM safety is per-unit `MemoryMax` plus
systemd-oomd, not an admission charge. Live RAM is
`systemctl --user show -p MemoryPeak <unit>` and `systemd-cgtop`.

Runners 11-36 are retired (#10480): `ansible/host.yml` stops, disables and
deletes their units from `agent_runner_retired_ids`. Their registrations at
GitHub stay until an org admin removes them, because that needs a token the VPS
key does not hold.

