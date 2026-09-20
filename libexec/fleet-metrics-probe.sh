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

# FLEET_PROM_OUT / CI_PROBE_NOW / CI_PROBE_REPOS are test overrides only; the
# service sets none of them.
T="${FLEET_PROM_OUT:-/var/lib/prometheus/node-exporter/fleet.prom}"
N="$T.$$"
NOW="${CI_PROBE_NOW:-$(date -u +%s)}"
# The enrolled set is config/intake-repos.json (the enrolment truth); the
# fallback keeps the probe emitting if that file is unreadable.
REPOS="${CI_PROBE_REPOS:-$(jq -r '.repos[].name' "$(dirname "$0")/../config/intake-repos.json" 2>/dev/null | tr '\n' ' ')}"
[ -n "$(printf '%s' "$REPOS" | tr -d '[:space:]')" ] || REPOS="fleet-ops 0509"

{
    # fleet-ops#2963: the verdict is the newest completed PUSH-triggered run
    # on main carrying a real conclusion — skipped/cancelled/null runs are not
    # verdicts (the newest-completed-of-any-trigger read fired false
    # FleetMainRed on a green 0509 trunk 2026-09-19, same family as
    # fleet-ops#3626), and event=push keeps scheduled-monitor successes from
    # masking a red trunk. fleet_main_ci_run_timestamp_seconds records the
    # verdict run's update time — the source timestamp the issue requires, so
    # evidence age is queryable as time() minus the series.
    # No verdict (GitHub unreachable, no completed push run, every completed
    # run cancelled/skipped) emits NOTHING for the repo: absent reads as
    # unknown via FleetProbeStale, never as a fabricated green or red.
    echo '# HELP fleet_main_ci_green Latest completed push-triggered run on the default branch returned a success verdict (1) or a real non-success verdict (0).'
    echo '# TYPE fleet_main_ci_green gauge'
    echo '# HELP fleet_main_ci_run_timestamp_seconds Update time of the run that produced the fleet_main_ci_green verdict (evidence-as-of).'
    echo '# TYPE fleet_main_ci_run_timestamp_seconds gauge'
    for r in $REPOS; do
        out=$(timeout 20 gh api "repos/Nishfleet/$r/actions/runs?branch=main&per_page=100&status=completed&event=push" \
              --jq '[.workflow_runs[] | select(.conclusion == "success" or .conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure")][0] // empty | "\(.conclusion) \(.updated_at | fromdateiso8601)"' 2>/dev/null)
        [ -z "$out" ] && continue
        c=${out%% *}
        [ "$c" = success ] && v=1 || v=0
        echo "fleet_main_ci_green{repo=\"$r\"} $v"
        echo "fleet_main_ci_run_timestamp_seconds{repo=\"$r\"} ${out##* }"
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

    # fleet-ops#5807: merge-queue head wait and hosted-CI queue depth were
    # blind — 2026-09-12 the 0509 merge queue head sat 2h20m with 67 hosted
    # runs queued and no alert fired. Same probe, same 5-minute cadence: no
    # new unit, no faster poll. The queued/in_progress counts are one REST
    # point each; the by_workflow detail series are what lets a dispatched
    # repair packet name its top slot consumers (workflow x count), and
    # ci_workflow_run_median_seconds gives the hold-time half of that.
    echo '# HELP ci_hosted_runs_queued GitHub-hosted Actions runs currently queued (vendor API only).'
    echo '# TYPE ci_hosted_runs_queued gauge'
    echo '# HELP ci_hosted_runs_in_progress GitHub-hosted Actions runs currently in progress (vendor API only).'
    echo '# TYPE ci_hosted_runs_in_progress gauge'
    echo '# HELP ci_hosted_runs_queued_by_workflow Queued hosted runs split by workflow name.'
    echo '# TYPE ci_hosted_runs_queued_by_workflow gauge'
    echo '# HELP ci_hosted_runs_in_progress_by_workflow In-progress hosted runs split by workflow name.'
    echo '# TYPE ci_hosted_runs_in_progress_by_workflow gauge'
    echo '# HELP ci_workflow_run_median_seconds Median duration of the last 30 completed runs per workflow.'
    echo '# TYPE ci_workflow_run_median_seconds gauge'
    echo '# HELP ci_merge_queue_entries Entries waiting in the GitHub merge queue (vendor API only).'
    echo '# TYPE ci_merge_queue_entries gauge'
    echo '# HELP ci_merge_queue_head_wait_seconds Age of the oldest merge-queue entry (vendor API only).'
    echo '# TYPE ci_merge_queue_head_wait_seconds gauge'
    for r in $REPOS; do
        for st in queued in_progress; do
            out=$(timeout 20 gh api "repos/Nishfleet/$r/actions/runs?status=$st&per_page=100" 2>/dev/null)
            [ -z "$out" ] && continue
            printf '%s' "$out" | jq -r --arg repo "$r" --arg st "$st" '
                "ci_hosted_runs_\($st){repo=\"\($repo)\"} \(.total_count // 0)",
                (.workflow_runs // [] | group_by(.name)[] |
                  "ci_hosted_runs_\($st)_by_workflow{repo=\"\($repo)\",workflow=\"\(.[0].name | gsub("\\\\"; "\\\\") | gsub("\""; "\\\""))\"} \(length)")
            ' 2>/dev/null
        done

        done_out=$(timeout 20 gh api "repos/Nishfleet/$r/actions/runs?status=completed&per_page=30" 2>/dev/null)
        if [ -n "$done_out" ]; then
            printf '%s' "$done_out" | jq -r --arg repo "$r" '
                [.workflow_runs // [] | .[]
                  | select(.run_started_at != null)
                  | {name, dur: ((.updated_at | fromdateiso8601) - (.run_started_at | fromdateiso8601))}]
                | group_by(.name)[]
                | ([.[].dur] | sort) as $d
                | "ci_workflow_run_median_seconds{repo=\"\($repo)\",workflow=\"\(.[0].name | gsub("\\\\"; "\\\\") | gsub("\""; "\\\""))\"} \($d[(((($d | length) - 1) / 2) | floor)])"
            ' 2>/dev/null
        fi
    done

    # mergeQueue is GraphQL-only, so it is budgeted against the App rate
    # limit (the fleet-ops#5762 20% floor): under the floor the query is
    # skipped and the series simply absent for this cycle.
    rl=$(timeout 15 gh api rate_limit 2>/dev/null)
    remaining=$(printf '%s' "$rl" | jq -r '.rate.remaining // 0' 2>/dev/null)
    limit=$(printf '%s' "$rl" | jq -r '.rate.limit // 5000' 2>/dev/null)
    remaining="${remaining:-0}"; limit="${limit:-5000}"
    if [ "$remaining" -ge $((limit / 5)) ] 2>/dev/null; then
        for r in $REPOS; do
            mq=$(timeout 20 gh api graphql -f query='query($name:String!){repository(owner:"Nishfleet",name:$name){mergeQueue(branch:"main"){entries(first:1){totalCount nodes{enqueuedAt}}}}}' -f name="$r" 2>/dev/null)
            [ -z "$mq" ] && continue
            printf '%s' "$mq" | jq -r --arg repo "$r" --argjson now "$NOW" '
                if (.data.repository // null) == null then empty
                else .data.repository.mergeQueue as $mq |
                  if $mq == null then
                      "ci_merge_queue_entries{repo=\"\($repo)\"} 0",
                      "ci_merge_queue_head_wait_seconds{repo=\"\($repo)\"} 0"
                  else
                      "ci_merge_queue_entries{repo=\"\($repo)\"} \($mq.entries.totalCount // 0)",
                      (($mq.entries.nodes[0].enqueuedAt // null) as $e |
                        if $e == null then
                          "ci_merge_queue_head_wait_seconds{repo=\"\($repo)\"} 0"
                        else
                          "ci_merge_queue_head_wait_seconds{repo=\"\($repo)\"} \([0, ($now - ($e | fromdateiso8601))] | max)"
                        end)
                  end
                end' 2>/dev/null
        done
    fi
# Atomic: node_exporter must never read a half-written textfile.
} > "$N" && mv -f "$N" "$T"
