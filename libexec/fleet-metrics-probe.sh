#!/bin/sh
# Fleet metrics probe. Glue sweep 2026-09-18 (exporter lane).
#
# Replaces libexec/fleet-metrics-export.py (4,679 lines, ~90 gauge families).
# Emits ONLY the facts that have no stock exporter on this host, because
# they live behind a vendor API rather than a /metrics endpoint. Everything
# else config/fleet_rules.yml alerts on comes from LiteLLM's own prometheus
# callback, node_exporter, the restic restore-test textfile, or up{}.
#
# curl + jq + gh only. No Python, no library, no state directory.
# Adding a metric here requires a rule that consumes it: a gauge nothing
# alerts on is exactly what this sweep deleted.
#
# The brief asked for this to be a single curl|jq ExecStart= line. It is a file
# instead because systemd's escape handling and $-expansion both rewrite the
# line before /bin/sh ever sees it: `\"` is silently dropped (so Prometheus
# label quotes vanish and the textfile is unparseable) and `$T` is expanded by
# systemd, not the shell. Proven with systemd-analyze --user verify on the
# one-line version. Same dependencies, same size, and it can actually be read.
set -u

T=/var/lib/prometheus/node-exporter/fleet.prom
N="$T.$$"

{
    echo '# HELP fleet_main_ci_green Latest completed CI run on the default branch succeeded (1) or not (0).'
    echo '# TYPE fleet_main_ci_green gauge'
    for r in fleet-ops 0509; do
        # Latest PUSH-triggered run with a real verdict, not just the newest
        # completed run of any trigger. False FleetMainRed on a green 0509
        # trunk 2026-09-19T06:35Z (and 3x in the previous 24h): the newest
        # completed run was `Auto revert` (event=workflow_run, conclusion
        # `skipped`), and a skipped run is not a failed trunk. Same bug family
        # as fleet-ops#3626 (a cancelled run counted as red) — that fix lived
        # in the deleted 4,679-line exporter and was not carried over by the
        # glue sweep. Looks back over the last 100 completed push runs for the
        # first success/failure/timed_out/startup_failure so a run that was
        # cancelled or skipped by a newer push does not become the verdict.
        c=$(gh api "repos/Nishfleet/$r/actions/runs?branch=main&per_page=100&status=completed&event=push" \
              --jq '[.workflow_runs[].conclusion | select(.=="success" or .=="failure" or .=="timed_out" or .=="startup_failure")][0] // empty' 2>/dev/null)
        # No answer means GitHub was unreachable (or no push verdict exists at
        # all — main is unarmed), not that main is green. Emit nothing and let
        # FleetProbeStale catch a persistent outage.
        [ -z "$c" ] && continue
        [ "$c" = success ] && v=1 || v=0
        echo "fleet_main_ci_green{repo=\"$r\"} $v"
    done

    echo '# HELP fleet_prepaid_credits_usd Prepaid vendor credit remaining, USD (vendor API only).'
    echo '# TYPE fleet_prepaid_credits_usd gauge'
    echo '# HELP fleet_prepaid_used_usd Prepaid vendor credit CONSUMED this cycle, USD.'
    echo '# TYPE fleet_prepaid_used_usd gauge'
    t=$(jq -r .accessToken "$HOME/.config/cursor/auth.json" 2>/dev/null)
    if [ -n "$t" ] && [ "$t" != null ]; then
        curl -s --max-time 10 -X POST \
            -H "Authorization: Bearer $t" \
            -H 'Content-Type: application/json' -d '{}' \
            https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage 2>/dev/null \
          | jq -r '.planUsage | select(.limit != null)
                   | "fleet_prepaid_credits_usd{provider=\"cursor\"} \(.limit - (.limit * ((.apiPercentUsed // 0) / 100)))",
                     "fleet_prepaid_used_usd{provider=\"cursor\"} \(.limit * ((.apiPercentUsed // 0) / 100))"' \
            2>/dev/null
    fi
# Atomic: node_exporter must never read a half-written textfile.
} > "$N" && mv -f "$N" "$T"
