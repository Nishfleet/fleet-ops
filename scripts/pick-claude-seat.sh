#!/usr/bin/env bash
# Pick which Claude seat an orchestrator `claude -p` job runs on. Called once, at
# job start, by the "Run the orchestrator session" step of agent-dispatch.yml;
# a running process is never switched.
#
# Two seats, neutral labels:
#   a  the runner's own CLAUDE_CONFIG_DIR (kept as is)
#   b  the default login (the caller runs `unset CLAUDE_CONFIG_DIR`)
# The seat is time-based: epoch / 7200 % 2, so two hours on one, then two on the
# other. Bucket 0 is seat a, bucket 1 is seat b. Before launching, the chosen
# seat's five-hour usage is read; at CLAUDE_SEAT_SKIP_AT (default 95) percent or
# more the other seat is used instead. If the usage call or its parse fails, the
# bucket's seat stays and a warning is printed.
#
# stdout: `keep` (leave CLAUDE_CONFIG_DIR alone) or `default` (unset it).
# stderr: one log line `claude seat: bucket=<0|1> seat=<a|b> five_hour=<n>`.
#
# The credentials files are only read, never written. The token never enters a
# variable or argv: jq renders it into a curl config on a process-substitution
# fd (argv is world-readable in /proc). No `set -x`.
#
# Test hook: CLAUDE_SEAT_EPOCH overrides the clock.
set -uo pipefail

skip_at=${CLAUDE_SEAT_SKIP_AT:-95}
now=${CLAUDE_SEAT_EPOCH:-$(date +%s)}
bucket=$(( now / 7200 % 2 ))
usage_url=https://api.anthropic.com/api/oauth/usage

# Where seat a lives. With no CLAUDE_CONFIG_DIR both seats are the default login
# and there is nothing to alternate.
if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
  echo "::warning::claude seat: CLAUDE_CONFIG_DIR is unset, nothing to alternate; keeping the default" >&2
  echo "claude seat: bucket=$bucket seat=b five_hour=n/a" >&2
  echo keep
  exit 0
fi

dir_of() { if [ "$1" = a ]; then echo "$CLAUDE_CONFIG_DIR"; else echo "$HOME/.claude"; fi; }

# five_hour_of <a|b>: prints the five-hour utilization, or returns 1.
five_hour_of() {
  local cred resp n
  cred="$(dir_of "$1")/.credentials.json"
  [ -r "$cred" ] || return 1
  resp=$(curl -s --max-time 10 "$usage_url" \
    --config <(jq -r '"header = \"Authorization: Bearer " + .claudeAiOauth.accessToken + "\""' "$cred") \
    -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || return 1
  n=$(jq -er '.five_hour.utilization | select(type == "number")' <<<"$resp" 2>/dev/null) || return 1
  echo "$n"
}

full() { jq -en --argjson n "$1" --argjson t "$skip_at" '$n >= $t' >/dev/null 2>&1; }

if [ "$bucket" = 0 ]; then seat=a; other=b; else seat=b; other=a; fi

if used=$(five_hour_of "$seat"); then
  if full "$used"; then
    if alt=$(five_hour_of "$other") && ! full "$alt"; then
      echo "::notice::claude seat: bucket seat is at $used percent, using the other seat" >&2
      seat=$other
      used=$alt
    else
      echo "::warning::claude seat: bucket seat is at $used percent and the other seat is full or unreadable; keeping the bucket seat" >&2
    fi
  fi
else
  echo "::warning::claude seat: usage unreadable for the bucket seat; keeping it" >&2
  used=n/a
fi

echo "claude seat: bucket=$bucket seat=$seat five_hour=$used" >&2
if [ "$seat" = a ]; then echo keep; else echo default; fi
