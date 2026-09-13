# tests/measure-p14-main.test.sh
# shellcheck shell=bash
#
# fleet-ops#6159: measure.sh must gain a `p14-main:` line that RUNS the ci.yml
# P14 shape (shellcheck / semgrep / systemd-analyze + the exact suite list)
# against a prepared tree of the measured main, prints red suites by name, and
# prints ok on a green one — never a fabricated green. Verdicts are cached by
# main sha; UNAVAILABLE decays. Hermetic: fixtures only, no git, no network
# assertions, no full-suite execution.
#
# Fixture-1 (deliberately broken main): an unclosed-if in bin/tool.sh
# (shellcheck red) + tests/b-red.test.sh failing + tests/c-gone listed in the
# fixture ci.yml but missing on disk (the #3740 incident class) — the line
# must name all three.
# Fixture-2 (the same tree, both breakages fixed): the line must be ok.
# Fixture-3: zero budget -> UNAVAILABLE:timeout, never a fabricated ok.

set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/measure-p14-main.sh"
measure="$repo_root/measure.sh"

[[ -f "$lib" ]] || fail "missing lib/measure-p14-main.sh"
[[ -f "$measure" ]] || fail "missing measure.sh"
grep -q 'measure-p14-main' "$measure" \
    || fail "measure.sh must source the p14-main detector"
grep -q 'p14-main' "$repo_root/.github/workflows/ci.yml" 2>/dev/null || true

scratch="$(mktemp -d -t measure-p14-main.XXXXXX)"
keep_scratch() {
    if [ "${KEEP_SCRATCH:-}" != 1 ]; then rm -rf "$scratch"; fi
}
trap keep_scratch EXIT INT TERM

export PATH="$repo_root/bin:$PATH"   # the fixture overrides nothing; PATH formality

# --- fixture-1: deliberately broken main -----------------------------------
fx1="$scratch/fx1"
mkdir -p "$fx1/tests" "$fx1/bin" "$fx1/.github/workflows" "$fx1/.github/scripts"
cat > "$fx1/.github/workflows/ci.yml" <<'YML'
name: fixture
on: [push]
jobs:
  tests:
    steps:
      - run: |
          bash tests/a-ok.test.sh
          bash tests/b-red.test.sh
          bash tests/c-gone.test.sh
YML
printf '#!/usr/bin/env bash\nexit 0\n' > "$fx1/tests/a-ok.test.sh"
printf '#!/usr/bin/env bash\necho "intentional fixture failure"\nexit 1\n' > "$fx1/tests/b-red.test.sh"
printf '#!/usr/bin/env bash\nif true; then\n' > "$fx1/bin/tool.sh"        # unclosed if: shellcheck red
printf '#!/usr/bin/env bash\nexit 0\n' > "$fx1/install.sh"
printf '#!/usr/bin/env bash\n' > "$fx1/.github/scripts/gate-integrity.sh"   # shebang: an empty file is an SC2148 red

# --- fixture-2: the same tree, fixed ----------------------------------------
fx2="$scratch/fx2"
cp -r "$fx1" "$fx2"
printf '#!/usr/bin/env bash\nif true; then\n  :\nfi\n' > "$fx2/bin/tool.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fx2/tests/b-red.test.sh"
printf '#!/usr/bin/env bash
exit 0
' > "$fx2/tests/c-gone.test.sh"   # #3740 class: listed, now present

# shellcheck disable=SC1090
source "$lib"

# 1. fixture-1: the line names every red part.
line1=$(MEASURE_P14_MAIN_TREE="$fx1" MEASURE_P14_MAIN_STATE="$scratch/m1" \
    fleet_p14_main_line "$repo_root") || fail "detector must exit 0 (fixture-1)"
grep -q '^p14-main(main=fixture): ' <<<"$line1" \
    || fail "no p14-main verdict: $line1"
grep -q 'red suites=' <<<"$line1" || fail "broken fixture must be red: $line1"
for want in shellcheck b-red c-gone; do
    grep -q "$want" <<<"$line1" || fail "fixture-1 must name $want: $line1"
done
grep -q 'suites=2' <<<"$line1" || fail "only 2 listed suites exist on disk: $line1"
grep -q 'detail=' <<<"$line1" || fail "a red verdict must cite its detail file: $line1"
detail1=$(grep -oE 'detail=[^ ]+' <<<"$line1" | cut -d= -f2)
[ -f "$detail1" ] || fail "detail file must exist: $detail1"
grep -q 'b-red' "$detail1" || fail "detail must trail the failing suite: $detail1"
ok "fixture-1: $line1"

# 2. fixture-2: the same tree, fixed -> ok, no red, no detail.
line2=$(MEASURE_P14_MAIN_TREE="$fx2" MEASURE_P14_MAIN_STATE="$scratch/m2" \
    fleet_p14_main_line "$repo_root") || fail "detector must exit 0 (fixture-2)"
grep -q '^p14-main(main=fixture): ok' <<<"$line2" \
    || fail "fixed fixture must be ok: $line2"
grep -q 'b-red' <<<"$line2" && fail "fixed b-red still reported: $line2"
grep -q 'shellcheck' <<<"$line2" && fail "fixed shellcheck still reported: $line2"
grep -q 'detail=' <<<"$line2" && fail "ok verdict must not cite a detail file: $line2"
ok "fixture-2: $line2"

# 3. zero budget -> UNAVAILABLE:timeout, never a fabricated ok.
line3=$(MEASURE_P14_MAIN_TREE="$fx1" MEASURE_P14_MAIN_STATE="$scratch/m3" \
    MEASURE_P14_MAIN_TIMEOUT_S=0 fleet_p14_main_line "$repo_root") \
    || fail "detector must exit 0 (timeout)"
grep -q 'UNAVAILABLE:timeout' <<<"$line3" || fail "zero budget must time out: $line3"
ok "timeout: $line3"

# 4. the nested guard: MEASURE_P14_MAIN set -> silent, exit 0 (recursion dies).
line4=$(MEASURE_P14_MAIN=1 MEASURE_P14_MAIN_TREE="$fx1" MEASURE_P14_MAIN_STATE="$scratch/m4" \
    fleet_p14_main_line "$repo_root") || fail "nested call must exit 0"
[ -z "$line4" ] || fail "nested call must stay silent, got: $line4"
ok "nested guard silent"

# 5. missing tree -> UNAVAILABLE, never fabricated.
line5=$(MEASURE_P14_MAIN_TREE="$scratch/nowhere" MEASURE_P14_MAIN_STATE="$scratch/m5" \
    fleet_p14_main_line "$repo_root") || fail "detector must exit 0 (missing tree)"
grep -q 'UNAVAILABLE:tree-missing' <<<"$line5" || fail "missing tree: $line5"
ok "missing tree: $line5"

ok "all measure-p14-main assertions passed"
