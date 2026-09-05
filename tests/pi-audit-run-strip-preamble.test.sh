#!/usr/bin/env bash
# tests/pi-audit-run-strip-preamble.test.sh
#
# fleet-ops#3594 replay drill: Pi's stdout preamble/epilogue (EXTLOAD-OK lines,
# the OSC 777 notify escape, PACKET-VERDICT) must never become the vote reason.
# Two shapes captured from the 2026-09-05T10:46Z journal: the reason paragraph
# before PASS followed by the notify+PACKET-VERDICT trailer, and PASS followed
# by an interleaved EXTLOAD-OK line. Before the fix the extracted reason was the
# noise itself and pi-audit-tally's evidence gate refused every candidate.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_bin="${PI_AUDIT_RUN_BIN:-$repo_root/bin/pi-audit-run}"
tally_bin="$repo_root/bin/pi-audit-tally"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f "$run_bin" && -f "$tally_bin" ]] || fail "missing $run_bin or $tally_bin"
# The scripts are not sourceable; lift the pure functions under test.
eval "$(sed -n '/^strip_harness_noise()/,/^}/p; /^extract_verdict()/,/^}/p; /^extract_reason()/,/^}/p' "$run_bin")"
eval "$(sed -n '/^reason_has_evidence()/,/^}/p' "$tally_bin")"
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
body='Ad slot frequency cap. Files: src/routes/ads.ts and src/lib/ads/cap.ts.
- required: cap per-user ad impressions in src/routes/ads.ts
- accept: test in tests/ads-cap.test.ts'
printf 'EXTLOAD-OK extension=bash-spawn-hook guard=tool_call depth_max=1 ceiling=7500/8000\nEXTLOAD-OK extension=packet-verdict mode=print-safe\nEXTLOAD-OK extension=seat-health source=after_provider_response\n0509#1624 names a concrete gap: src/routes/ads.ts has no per-user frequency cap, the body carries required/accept lines, no open duplicate identified, and it advances the north star (beats the customer edge parity).\n\nPASS\n\033]777;notify;Pi;Ready for input\007PACKET-VERDICT tools=0 class=no-tools\n' >"$scratch/out1"
printf '0509#1624: src/routes/ads.ts lacks the cap; spec complete; no duplicate; north-star fit (customer edge).\nPASS\nEXTLOAD-OK extension=seat-health source=after_provider_response\n' >"$scratch/out2"
for n in 1 2; do
    v=$(extract_verdict "$scratch/out$n")
    [[ "$v" == PASS ]] || fail "shape $n: verdict '$v' != PASS"
    r=$(extract_reason "$scratch/out$n")
    case "$r" in *EXTLOAD-OK*|*PACKET-VERDICT*|*']777;notify'*) fail "shape $n: harness noise leaked into reason: $r";; esac
    [[ "$r" == *'0509#1624'* && "$r" == *'src/routes/ads.ts'* ]] || fail "shape $n: reason lost the citation: '$r'"
    reason_has_evidence "$r" 1624 "$body" || fail "shape $n: evidence gate refused the cleaned reason"
done
noise=$(printf '\033]777;notify;Pi;Ready for input\007PACKET-VERDICT tools=0 class=no-tools')
if reason_has_evidence "$noise" 1624 "$body"; then fail "noise-only reason admitted as evidence"; fi
printf 'PASS: pi-audit-run strips harness noise; verdict-block reason admitted by the evidence gate (fleet-ops#3594)\n'
