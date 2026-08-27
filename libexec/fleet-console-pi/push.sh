#!/usr/bin/env bash
# Generate live-truth data, independently recompute every tile, then push
# shell+data to the fleet-console Worker's KV (fleet-ops#1157).
#
# No hand-built orchestration: one generate, one verify, one push attempt
# per run. systemd owns restart/backoff via Restart=on-failure + RestartSec.
# A failed push exits non-zero and the timer's next fire retries; a
# transient Cloudflare blip is handled by systemd, not by a hand-rolled
# retry loop here. Verify piggybacks this cycle — no new timer.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
W="${WRANGLER:-/home/nish/.local/share/safe-deploy/bin/wrangler}"
NS="${KV_NAMESPACE_ID:-e39df754bd1f4085a50818e992ad4050}"
ENV_FILE="${CF_ENV:-/home/nish/.config/fleet-console/cf.env}"

[ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "no CF token; not pushing" >&2; exit 1; }

# 1. Generate live truth. Failure exits non-zero -> systemd restarts.
python3 "$DIR/generate.py"

# 2. Independent truth-check of every tile (fleet-ops#1157). Stamps
#    disputed + verify onto data.json and writes
#    fleet-console-tiles.prom. A mismatch does NOT fail the push: the
#    page must still render, with DISPUTED, so Nish can see the lie.
#    A verify crash DOES fail the run (fail loud; next timer retries).
python3 "$DIR/verify.py"

# 3. Push only if bytes changed (avoid redundant KV writes; NOT a debounce).
push_if_changed() {
  local key="$1" file="$2"
  local stamp="$DIR/.pushed-$key.sha"
  local sha; sha=$(sha256sum "$file" | awk '{print $1}')
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$sha" ]; then
    echo "$key unchanged ($sha); skip"
    return 0
  fi
  "$W" kv key put "$key" --namespace-id "$NS" --path "$file" --remote
  echo "$sha" > "$stamp"
  echo "pushed $key ($sha)"
}

push_if_changed fleet "$DIR/data.json"
push_if_changed shell "$DIR/shell.html"
echo "push complete $(date -u +%H:%M:%SZ)"
