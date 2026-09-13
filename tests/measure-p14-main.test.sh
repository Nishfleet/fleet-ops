# tests/measure-p14-main.test.sh
# shellcheck shell=bash
#
# fleet-ops#6159: measure.sh must gain a `p14-main:` line that RUNS the ci.yml
# P14 shape (shellcheck / semgrep / systemd-analyze + the exact suite list)
# against a prepared tree of the measured main, prints red suites by name, and
# prints ok on a green one — never a fabricated green. Verdicts are cached by
# main sha; UNAVAILABLE decays. Hermetic: fixture trees, no network, no
# full-suite execution (the production drill uses a throwaway fixture GIT
# repo, not this checkout).
#
# Fixture-1 (deliberately broken main): an unclosed-if in bin/tool.sh
# (shellcheck red) + tests/b-red.test.sh failing + tests/c-gone listed in the
# fixture ci.yml but missing on disk (the #3740 incident class) — the line
# must name all three.
# Fixture-2 (the same tree, both breakages fixed): the line must be ok.
# Fixture-3: zero budget -> UNAVAILABLE:timeout, never a fabricated ok.
# Fixture-4 (production mode — the acceptance's "against a local worktree of
# origin/main HEAD"): a fixture GIT repo whose origin/main goes red->green
# in two commits; no MEASURE_P14_MAIN_TREE/SHA, so the detector resolves
# origin/main itself, worktree-adds the committed sha, computes, and cleans
# up (no leaked worktree registration). Also proves the sha-keyed cache: a
# 0s-budget call returns the STORED verdict instead of recomputing into
# UNAVAILABLE:timeout.

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

# --- production mode: the acceptance's worktree-of-origin/main-HEAD path -----
# 6. no TREE, no SHA: the detector resolves origin/main of the measured repo
#    itself, worktree-adds EXACTLY that commit, computes, prints, cleans up,
#    and caches under the 12-hex sha. Fixture repo = the whole universe.
fxrepo="$scratch/fxrepo"
mkdir -p "$fxrepo/tests" "$fxrepo/bin" "$fxrepo/.github/workflows" "$fxrepo/.github/scripts"
cat > "$fxrepo/.github/workflows/ci.yml" <<'YML'
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
printf '#!/usr/bin/env bash\nexit 0\n' > "$fxrepo/tests/a-ok.test.sh"
printf '#!/usr/bin/env bash\necho "intentional fixture failure"\nexit 1\n' > "$fxrepo/tests/b-red.test.sh"
printf '#!/usr/bin/env bash\nif true; then\n' > "$fxrepo/bin/tool.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fxrepo/install.sh"
printf '#!/usr/bin/env bash\n' > "$fxrepo/.github/scripts/gate-integrity.sh"
git -C "$fxrepo" init -q -b main
git -C "$fxrepo" add -A
git -C "$fxrepo" -c user.email=f@x -c user.name=f commit -qm 'red main'
red_sha=$(git -C "$fxrepo" rev-parse --short=12 main)
git -C "$fxrepo" update-ref refs/remotes/origin/main "$red_sha"

p1=$(GITHUB_ACTIONS= MEASURE_P14_MAIN_STATE="$scratch/mp" fleet_p14_main_line "$fxrepo") \
    || fail "detector must exit 0 (production, red main)"
grep -q "^p14-main(main=$red_sha): red suites=" <<<"$p1" \
    || fail "production mode must measure the committed main, not a working dir: $p1"
grep -q 'b-red' <<<"$p1" || fail "production red must name the broken suite: $p1"
grep -q 'suites=2' <<<"$p1" || fail "production red counts only on-disk suites: $p1"
[ -f "$scratch/mp/$red_sha.detail" ] \
    || fail "production red must write its detail file: $scratch/mp/$red_sha.detail"
# the worktree the verdict was computed in is gone: registration cleaned.
wt_count=$(git -C "$fxrepo" worktree list --porcelain | grep -c '^worktree ')
[ "$wt_count" -eq 1 ] \
    || fail "production mode must not leak worktree registrations (got $wt_count, want 1)"
ok "production red: $p1"

# 7. green main at a NEW committed sha: the verdict tracks the measured
#    commit, not whatever the fixture's working dir now holds.
printf '#!/usr/bin/env bash\nif true; then\n  :\nfi\n' > "$fxrepo/bin/tool.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fxrepo/tests/b-red.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fxrepo/tests/c-gone.test.sh"
git -C "$fxrepo" add -A
git -C "$fxrepo" -c user.email=f@x -c user.name=f commit -qm 'green main'
green_sha=$(git -C "$fxrepo" rev-parse --short=12 main)
git -C "$fxrepo" update-ref refs/remotes/origin/main "$green_sha"

p2=$(GITHUB_ACTIONS= MEASURE_P14_MAIN_STATE="$scratch/mp" fleet_p14_main_line "$fxrepo") \
    || fail "detector must exit 0 (production, green main)"
grep -qE "^p14-main\(main=$green_sha\): ok( |$)" <<<"$p2" \
    || fail "production green main must be ok: $p2"
grep -q 'red suites=' <<<"$p2" && fail "green production verdict must not be red: $p2"
ok "production green: $p2"

# 8. the verdict is cached by main sha: a THIRD call with a 0s budget must
#    return the STORED green verdict, not recompute into UNAVAILABLE:timeout.
p3=$(GITHUB_ACTIONS= MEASURE_P14_MAIN_STATE="$scratch/mp" MEASURE_P14_MAIN_TIMEOUT_S=0 \
    fleet_p14_main_line "$fxrepo") || fail "detector must exit 0 (cache probe)"
[ "$p3" = "$p2" ] || fail "cache probe must return the stored verdict, got: $p3"
ok "cache hit: $p3"

# 9. the Actions guard: GITHUB_ACTIONS set -> UNAVAILABLE:ci-context, never a
#    compute (the Actions P14 job already covers the commit; the 109-suite
#    pass would blow its 30-min budget through the 3 measure.sh-executor
#    tests). Setting GITHUB_ACTIONS=1 drills it on the VPS too — same code
#    path, no居Áç制度的 environment assumption.
line9=$(GITHUB_ACTIONS=1 MEASURE_P14_MAIN_STATE="$scratch/m9" \
    fleet_p14_main_line "$repo_root") || fail "detector must exit 0 (Actions guard)"
grep -q 'UNAVAILABLE:ci-context' <<<"$line9" \
    || fail "GITHUB_ACTIONS must short-circuit to UNAVAILABLE:ci-context: $line9"
ok "Actions guard: $line9"

# 10. the stdin-drain class — the #6159 live sighting: 22 of 109 suites, the
#     #22 fleet-blind-audit read the loop's $list through its unredirected
#     stdin. Fixture: 26 suites, #22 (tstdin, sorts between s* and u*) reads
#     ITS stdin; the fix (</dev/null on every suite) keeps the pass at 26.
#     All 26 pass, so the line must be ok suites=26 — a drained pass would
#     stop at 22 and this assert fails by name.
fx3="$scratch/fx3"
mkdir -p "$fx3/tests" "$fx3/bin" "$fx3/.github/workflows" "$fx3/.github/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fx3/install.sh"
printf '#!/usr/bin/env bash\n' > "$fx3/.github/scripts/gate-integrity.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fx3/bin/tool.sh"
{
  echo 'name: fixture3'
  echo 'on: [push]'
  echo 'jobs:'
  echo '  tests:'
  echo '    steps:'
  echo '      - run: |'
  for i in $(seq -w 1 21); do echo "          bash tests/s$i.test.sh"; done
  echo '          bash tests/tstdin.test.sh'
  for i in 1 2 3 4; do echo "          bash tests/u0$i.test.sh"; done
} > "$fx3/.github/workflows/ci.yml"
for i in $(seq -w 1 21); do printf '#!/usr/bin/env bash\nexit 0\n' > "$fx3/tests/s$i.test.sh"; done
printf '#!/usr/bin/env bash\nwhile read -r x; do :; done\nexit 0\n' > "$fx3/tests/tstdin.test.sh"
for i in 1 2 3 4; do printf '#!/usr/bin/env bash\nexit 0\n' > "$fx3/tests/u0$i.test.sh"; done
line10=$(MEASURE_P14_MAIN_TREE="$fx3" MEASURE_P14_MAIN_STATE="$scratch/m10" \
    fleet_p14_main_line "$repo_root") || fail "detector must exit 0 (stdin-drill)"
grep -q 'suites=26' <<<"$line10" \
    || fail "a stdin-reading #22 must not drain the pass (want 26): $line10"
grep -qE ': ok( |$)' <<<"$line10" || fail "all-26-pass must be ok: $line10"
ok "stdin-drain: $line10"

ok "all measure-p14-main assertions passed"
