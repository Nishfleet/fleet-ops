#!/usr/bin/env bash
# lib/seat-probe.sh GROUP [GROUP...] — ExecCondition gate (fleet-ops#7776).
# Probes a LiteLLM router group with a 1-token streaming chat completion
# requesting a forced tool call. Live = HTTP 200 with a `tool_calls` chunk
# on a non-devin deployment (`x-litellm-model-id` header). Walled = anything
# else: ONE `SEAT-WALL group=<g> retry_after=<s>` line per wall episode,
# per-group backoff (5m doubling to 30m) under $FLEET_SEAT_PROBE_STATE_DIR,
# and health_class=seat-wall in pi-seat-health.json. A suppressed re-check
# costs zero API calls — on 2026-09-18 the units burned a full
# claim/start/verdict cycle per attempt (14+ tools=0 runs in 2h).
#
# Exit 0 = live, 1 = seat-walled (ExecCondition "skip", not a failure),
# 2 = probe infrastructure broken (usage / key unreadable).
# FLEET_SEAT_PROBE=0 disables the gate entirely — the revert switch.

set -u
[ "${FLEET_SEAT_PROBE:-1}" = "1" ] || exit 0
[ $# -ge 1 ] || { echo "usage: seat-probe.sh GROUP..." >&2; exit 2; }

URL=${FLEET_SEAT_PROBE_URL:-http://127.0.0.1:4000/v1/chat/completions}
CURL=${FLEET_SEAT_PROBE_CURL:-curl}
KEY_CMD=${FLEET_SEAT_PROBE_KEY_CMD:-fleet-litellm-key master}
DIR=${FLEET_SEAT_PROBE_STATE_DIR:-$HOME/workspaces/agent-state/lanes}
HF=${FLEET_SEAT_PROBE_HEALTH_FILE:-$DIR/pi-seat-health.json}
MIN=${FLEET_SEAT_PROBE_MIN_BACKOFF:-300}
MAX=${FLEET_SEAT_PROBE_MAX_BACKOFF:-1800}
NOW=${FLEET_SEAT_PROBE_NOW:-$(date +%s)}
mkdir -p "$DIR"

health() { # group class status retry_after — rewrite the seat-health record
  printf '{"provider":"litellm","model":"%s","http_status":%s,"retry_after":%s,"health_class":"%s","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"%s","source":"seat_probe"}\n' \
    "$1" "${3:-null}" "${4:-null}" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$HF.tmp" &&
    mv "$HF.tmp" "$HF"
}

probe() { # group -> 0 live / 1 walled / 2 infra
  local key hdr body code walled=1 kc
  read -ra kc <<<"$KEY_CMD"
  key=$("${kc[@]}") || return 2
  hdr=$(mktemp) body=$(mktemp)
  code=$($CURL -sS -m "${FLEET_SEAT_PROBE_TIMEOUT:-20}" -D "$hdr" -o "$body" \
    -w '%{http_code}' -H "Authorization: Bearer $key" \
    -H 'content-type: application/json' \
    -d '{"model":"'"$1"'","stream":true,"max_tokens":1,"messages":[{"role":"user","content":"call the probe_ok tool"}],"tools":[{"type":"function","function":{"name":"probe_ok","description":"seat probe","parameters":{"type":"object","properties":{}}}}],"tool_choice":"required"}' \
    "$URL") || code=000
  [ "$code" = 200 ] &&
    ! grep -qi '^x-litellm-model-id:.*devin' "$hdr" &&
    grep -q '"tool_calls"' "$body" && walled=0
  rm -f "$hdr" "$body"
  return $walled
}

rc=0
for g in "$@"; do
  st="$DIR/seat-wall-$g.json" next=0 prev=0
  if [ -f "$st" ]; then
    eval "$(grep -oE '"(next_probe_at|retry_after)":[0-9]+' "$st" | sed -e 's/"next_probe_at":/next=/' -e 's/"retry_after":/prev=/')"
  fi
  if [ "$next" -gt "$NOW" ]; then
    echo "seat-probe: $g walled, $((next - NOW))s of backoff left" >&2
    rc=1; continue
  fi
  if probe "$g"; then
    rm -f "$st"
    grep -qE '"model": *"'"$g"'"' "$HF" 2>/dev/null && grep -q seat-wall "$HF" &&
      health "$g" healthy 200 null
    continue
  elif [ $? -eq 2 ]; then
    echo "seat-probe: infra fault (key/curl) — not a wall" >&2; exit 2
  fi
  ra=$((prev * 2)); [ "$ra" -lt "$MIN" ] && ra=$MIN; [ "$ra" -gt "$MAX" ] && ra=$MAX
  printf '{"group":"%s","retry_after":%s,"next_probe_at":%s,"walled_at":"%s"}\n' \
    "$g" "$ra" "$((NOW + ra))" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$st.tmp" && mv "$st.tmp" "$st"
  health "$g" seat-wall null "$ra"
  echo "SEAT-WALL group=$g retry_after=$ra"
  rc=1
done
exit "$rc"
