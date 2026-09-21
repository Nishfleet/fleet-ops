#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
unit="$repo_root/systemd/pi-issue@.service"

# Extract the LAST ExecStopPost line
line="$(grep -o "ExecStopPost=/bin/sh -c '\[ \"\$SERVICE_RESULT\" = success ].*sh %i" "$unit" | tail -1)"
[[ -n "$line" ]] || { echo "FAIL: could not find the artifact-check ExecStopPost line"; exit 1; }
echo "OK: found the artifact-check ExecStopPost line"

# Check dispatcher verdict shape
grep -qF 'gh api "repos/Nishfleet/$r/branches/claim/issue-$n" >/dev/null 2>&1 && exit 0' <<< "$line" || { echo "FAIL: dispatcher lost the branch probe"; exit 1; }
grep -qF 'repos/Nishfleet/$r/pulls?state=all&head=Nishfleet:claim/issue-$n' <<< "$line" || { echo "FAIL: dispatcher lost the PR probe"; exit 1; }
grep -qF 'the run exited 0 with no artifact' <<< "$line" || { echo "FAIL: dispatcher lost the no-artifact FAILED outcome"; exit 1; }
grep -qF '>&2; exit 1' <<< "$line" || { echo "FAIL: the no-artifact path must still exit 1"; exit 1; }
echo "OK: artifact verdict intact"

# Advisory-only
grep -qF '"jev handoff: score=' <<< "$line" || { echo "FAIL: missing the jev handoff comment marker"; exit 1; }
grep -qF 'JEV_HANDOFF' <<< "$line" || { echo "FAIL: missing the JEV_HANDOFF=0 rollback kill-switch"; exit 1; }
echo "OK: handoff kill-switch present"

# Jev call goes through pass-through
grep -qF '127.0.0.1:4000/jev' <<< "$line" || { echo "FAIL: the Jev call must use the LiteLLM pass-through endpoint"; exit 1; }
grep -qF 'typesafe-jev.env' <<< "$line" || { echo "FAIL: LITELLM_JEV_KEY must be sourced from the seats env file"; exit 1; }
if grep -qF 'VERCEL_AI_GATEWAY_JEV_KEY' <<< "$line"; then echo "FAIL: must not read the gateway key directly"; exit 1; fi
echo "OK: Jev reaches 127.0.0.1:4000/jev via the seats env"

# Template checks
template="$repo_root/.fleet/jev-handoff-template.json"
grep -qF '"type": "score"' "$template" || { echo "FAIL: template questions must be score questions"; exit 1; }
grep -qF '"criteria"' "$template" || { echo "FAIL: score questions need criteria arrays"; exit 1; }
for key in state next_step blockers proof_refs; do
  grep -qF "\"$key\"" "$template" || { echo "FAIL: template missing question $key"; exit 1; }
done
echo "OK: template covers state/next_step/blockers/proof_refs with criteria"

# JSONL row
grep -qF 'issue-handoffs' <<< "$line" || { echo "FAIL: JSONL row must log under .../jev/issue-handoffs/"; exit 1; }
grep -qF 'state_sha256: $hash' <<< "$line" || { echo "FAIL: JSONL row must carry state_sha256"; exit 1; }
grep -qF 'score: $score' <<< "$line" || { echo "FAIL: JSONL row must carry the min score"; exit 1; }
echo "OK: JSONL receipt shape pinned"

# Idempotence
grep -qF '*"jev handoff:"*' <<< "$line" || { echo "FAIL: re-score guard missing"; exit 1; }
grep -qF '.fleet/handoff.md' <<< "$line" || { echo "FAIL: empty-body fallback to the handoff template missing"; exit 1; }
echo "OK: idempotence + fallback pinned"

# Success-path only
grep -qF '[ "$SERVICE_RESULT" = success ] || exit 0' <<< "$line" || { echo "FAIL: handoff scoring must only run on success exits"; exit 1; }
echo "OK: success-path only"

# pause-safely contract
for d in "current state of the work" "next concrete step" "blockers" "references proof"; do
  grep -qiF "$d" "$template" || { echo "FAIL: template dimension '$d' missing"; exit 1; }
done
echo "OK: scoring dimensions match the pause-safely note shape"

echo "PASS: pi-issue-jev-handoff"
