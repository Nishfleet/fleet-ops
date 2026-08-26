#!/usr/bin/env bash
# tests/worker-prompt-systemd-run.test.sh
#
# Locks the worker.md prompt to include the pi-systemd-run rule and
# forbids nohup appearing outside a prohibition context.
#
# Invariants:
#   1. prompts/worker.md mentions `pi-systemd-run`.
#   2. If prompts/worker.md mentions `nohup`, every line that does is in a
#      prohibition context (contains never/not/no/forbidden/banned/prohibited/
#      refuse/refuses/wrong/die/dies/died/must/should/cannot/prohibition).
#   3. The example is a `pi` path, not a Claude path.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
prompt="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$prompt" ]] || fail "missing $prompt"

grep -q 'pi-systemd-run' "$prompt" \
  || fail "worker.md must mention pi-systemd-run"
ok "worker.md mentions pi-systemd-run"

# The example must be a `pi` path, not `claude -p`.
grep -A2 'pi-systemd-run' "$prompt" | grep -q 'pi --print' \
  || fail 'worker.md example must show a `pi --print` path'
ok "worker.md example is a pi path"

nohup_count=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  nohup_count=$((nohup_count + 1))
  text="${line#*:}"
  if ! grep -qiE '\b(never|not|no|forbidden|banned|prohibited|refuse|refuses|wrong|die|dies|died|must|should|cannot|prohibition)\b' <<<"$text"; then
    fail "nohup appears outside a prohibition context: $line"
  fi
done < <(grep -n -i -E '\bnohup\b' "$prompt" || true)

if [[ "$nohup_count" -eq 0 ]]; then
  ok "nohup does not appear in worker.md"
else
  ok "all $nohup_count nohup occurrences are in a prohibition context"
fi

echo "OK: worker.md carries the pi-systemd-run rule"
