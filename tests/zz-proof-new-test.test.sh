#!/usr/bin/env bash
# fleet-ops#5889 acceptance proof: a NEW tests/*.test.sh with NO ci.yml change
# must turn `P14 tests / PR checks` green. This file is auto-run by the
# listing gate's new glob host (no ci.yml entry, no host line). Deleted in
# the follow-up commit of this same PR series; the passing run of this
# commit on P14 is the proof.

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f .github/workflows/ci.yml ]] || fail "ci.yml missing"
echo "OK: zz-proof-new-test reached and passing; ci.yml untouched by fleet-ops#5889"
