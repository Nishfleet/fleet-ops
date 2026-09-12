#!/usr/bin/env bash
# tests/seat-caps-zero-yield.test.sh
#
# fleet-ops#4271 (session-waste #4260): a seat cannot hold cap > 0 while its
# trailing-7-day yield is 0 PRs over >= 20 picks. The population study showed
# seven seats took 637 picks (26% of all runs) and produced 15 PRs (3%) over
# 2026-09-01..09-07; each pick still costs a claim cycle and a RestartSec=240
# delay on a live issue, so an infra-dying or low-yield seat must not be
# picked while a working one is free.
#
# This test is the LOCAL offline gate for the invariant. It reads the live
# config/seat-caps.json and a seat-yield fixture (SEAT_YIELD_JSON, defaulting
# to a fixture that mirrors the current live ~/.local/state/pi-packet/
# seat-yield.json) and asserts:
#   1. Every seat in the fixture with sessions >= 20 AND pr_count == 0 has
#      cap == 0 in the config (the zero-yield retirement).
#   2. Every such cap=0 row carries intentional_cap_zero=yield and a dated
#      reason (the re-audition path, yield gate #3251, is the only way back
#      in — never an auto-expire).
#   3. The eight seats named in the issue are all capped to 0 (seven
#      surviving rows — the eighth, xkiro/deepseek/deepseek-v4-flash, was
#      retired 2026-09-10 when every DeepSeek V4 flash id was banned).
#
# When the next zero-yield seat appears (>= 20 picks, 0 PRs), the fixture
# must be updated to include it AND the config must cap it to 0, or this test
# fails — so the next zero-yield seat is caught without a human reading a
# table.
#
# Hosted by tests/seat.lib.test.sh (workers cannot add a ci.yml line).
# Offline. Reads the live config; the seat-yield fixture is a scratch file.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
caps="${SEAT_CAPS_JSON:-$repo_root/config/seat-caps.json}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$caps" ]] || fail "seat-caps.json not found: $caps"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-caps-zero-yield.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# The seat-yield fixture. Mirrors the live ~/.local/state/pi-packet/
# seat-yield.json as of 2026-09-07 (fleet-ops#4271): the eight zero-yield
# seats at sessions >= 20 / pr_count 0, plus healthy seats with PRs so the
# invariant is not vacuous. SEAT_YIELD_JSON override lets a replay drill point
# this test at a different fixture.
yield="${SEAT_YIELD_JSON:-$scratch/seat-yield.json}"
if [[ "$yield" == "$scratch/seat-yield.json" ]]; then
cat >"$yield" <<'JSON'
{
  "commandcode/poolside/laguna-s-2.1-free": { "yield": 0.0, "sessions": 20, "pr_count": 0, "provisional": false },
  "hetzner/Qwen/Qwen3.6-35B-A3B-FP8": { "yield": 0.0, "sessions": 20, "pr_count": 0, "provisional": false },
  "opencode/nemotron-3-ultra-free": { "yield": 0.25, "sessions": 20, "pr_count": 5, "provisional": false },
  "opencode/mimo-v2.5-free": { "yield": 0.0, "sessions": 20, "pr_count": 0, "provisional": false },
  "xkiro/deepseek/deepseek-v4-pro": { "yield": 0.0, "sessions": 20, "pr_count": 0, "provisional": false },
  "xkiro/minimax/minimax-m3:free": { "yield": 0.0, "sessions": 20, "pr_count": 0, "provisional": false },
  "zenmux/z-ai/glm-4.7-flash-free": { "yield": 0.0, "sessions": 20, "pr_count": 0, "provisional": false },
  "deepseek/deepseek-flash": { "yield": 0.25, "sessions": 20, "pr_count": 5, "provisional": false },
  "openrouter/deepseek/deepseek-v4.1-flash": { "yield": 0.35, "sessions": 20, "pr_count": 7, "provisional": false }
}
JSON
fi
[[ -f "$yield" ]] || fail "seat-yield fixture not found: $yield"
jq . "$yield" >/dev/null || fail "seat-yield fixture does not parse"

# --- 1. every zero-yield seat (>=20 picks, 0 PRs) is capped 0 in the config --
echo "--- scenario 1: zero-yield seats (>=20 picks, 0 PRs) are capped 0 ---"
bad=0
checked=0
while IFS=$'\t' read -r seat sessions pr_count; do
  [[ -n "$seat" ]] || continue
  # Only seats with >= 20 picks and 0 PRs trigger the invariant.
  if (( sessions < 20 )); then continue; fi
  if (( pr_count > 0 )); then continue; fi
  checked=$((checked + 1))
  prov="${seat%%/*}"
  model="${seat#*/}"
  cap=$(jq -r --arg p "$prov" --arg m "$model" \
    '(.providers[$p].models[$m] // "missing") | if type == "object" then .cap else . end' \
    "$caps")
  if [[ "$cap" == "missing" ]]; then
    echo "  $seat: zero-yield (>=20 picks, 0 PRs) but NOT in the seat-caps allowlist — must be capped 0 (fleet-ops#4271)" >&2
    bad=$((bad + 1)); continue
  fi
  if [[ "$cap" != "0" ]]; then
    echo "  $seat: zero-yield (>=20 picks, 0 PRs) but cap=$cap — must be capped 0 (fleet-ops#4271)" >&2
    bad=$((bad + 1)); continue
  fi
  ok "$seat: zero-yield (>=20 picks, 0 PRs) capped 0"
done < <(jq -r 'to_entries[] | [.key, (.value.sessions // 0), (.value.pr_count // 0)] | @tsv' "$yield")
[[ "$bad" == "0" ]] || fail "scenario1: $bad zero-yield seat(s) not capped 0 (fleet-ops#4271)"
if (( checked == 0 )); then
  fail "scenario1: fixture has no zero-yield seat with >=20 picks — the invariant is vacuous; add one"
fi
ok "scenario1: every zero-yield seat (>=20 picks, 0 PRs) is capped 0"

# --- 2. every zero-yield cap=0 row carries intentional_cap_zero=yield + date --
echo "--- scenario 2: zero-yield cap=0 rows are intentional (yield) + dated ---"
bad2=0
while IFS=$'\t' read -r seat sessions pr_count; do
  [[ -n "$seat" ]] || continue
  if (( sessions < 20 )); then continue; fi
  if (( pr_count > 0 )); then continue; fi
  prov="${seat%%/*}"
  model="${seat#*/}"
  icz=$(jq -r --arg p "$prov" --arg m "$model" \
    '.providers[$p].models[$m].intentional_cap_zero // ""' "$caps")
  if [[ "$icz" != "yield" ]]; then
    echo "  $seat: zero-yield cap=0 must carry intentional_cap_zero=yield (got '$icz') — re-audition only via the yield gate #3251 (fleet-ops#4271)" >&2
    bad2=$((bad2 + 1)); continue
  fi
  reason=$(jq -r --arg p "$prov" --arg m "$model" \
    '.providers[$p].models[$m].reason // ""' "$caps")
  if ! grep -qE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' <<<"$reason"; then
    echo "  $seat: zero-yield cap=0 reason must be dated (fleet-ops#4271)" >&2
    bad2=$((bad2 + 1)); continue
  fi
  ok "$seat: intentional_cap_zero=yield with dated reason"
done < <(jq -r 'to_entries[] | [.key, (.value.sessions // 0), (.value.pr_count // 0)] | @tsv' "$yield")
[[ "$bad2" == "0" ]] || fail "scenario2: $bad2 zero-yield cap=0 row(s) missing intentional_cap_zero=yield or a dated reason (fleet-ops#4271)"
ok "scenario2: every zero-yield cap=0 row is intentional (yield) with a dated reason"

# --- 3. the eight seats named in the issue are all capped 0 -----------------
# (seven surviving rows: the eighth, xkiro/deepseek/deepseek-v4-flash, was
# deleted with the fleet-wide DeepSeek V4 flash ban on 2026-09-10 — a retired
# seat cannot be "capped 0", it is absent.)
echo "--- scenario 3: the eight issue seats are capped 0 ---"
declare -A issue_seats=(
  ["commandcode/poolside/laguna-s-2.1-free"]=1
  ["hetzner/Qwen/Qwen3.6-35B-A3B-FP8"]=1
  ["opencode/nemotron-3-ultra-free"]=1
  ["opencode/mimo-v2.5-free"]=1
  ["xkiro/deepseek/deepseek-v4-pro"]=1
  ["xkiro/minimax/minimax-m3:free"]=1
  ["zenmux/z-ai/glm-4.7-flash-free"]=1
)
bad3=0
for seat in "${!issue_seats[@]}"; do
  prov="${seat%%/*}"
  model="${seat#*/}"
  cap=$(jq -r --arg p "$prov" --arg m "$model" \
    '(.providers[$p].models[$m] // "missing") | if type == "object" then .cap else . end' \
    "$caps")
  if [[ "$cap" != "0" ]]; then
    echo "  $seat: must be capped 0 (fleet-ops#4271), got '$cap'" >&2
    bad3=$((bad3 + 1)); continue
  fi
  ok "$seat: capped 0"
done
[[ "$bad3" == "0" ]] || fail "scenario3: $bad3 of the seven surviving issue seats not capped 0 (fleet-ops#4271)"
ok "scenario3: all seven surviving issue seats capped 0"

ok "seat-caps-zero-yield: no cap>0 seat holds 0 PRs over >=20 picks; the seven surviving issue seats are capped 0 with intentional_cap_zero=yield (fleet-ops#4271)"
