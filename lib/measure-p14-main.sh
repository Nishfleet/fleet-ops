# fleet-ops#6159: the p14-main measure line.
# shellcheck shell=bash
#
# 4th caught-by-hand sighting: the P14 suites (the ci.yml `tests` job:
# the static steps (shellcheck+semgrep+systemd-analyze) and the ~100-suite
# verify-command) go red on main while the suites run as PR checks only, so measure.sh's
# main-green view (check-runs on main HEAD) is structurally blind and a
# main-breaking merge silently blocks every PR until a judge trips over it by
# hand (model_cap, senior_seat_available, mark_seat_*, shellcheck #6037 —
# 4 reds inside 24h, all found by hand). This detector RUNS the P14 shape
# against origin/main instead of trusting any check-run, and prints the red
# parts by name. The issue's 4th case was "shellcheck rc=1 on main" — the
# static steps count as suites here, exactly as the issue names them.
#
# Cost: the whole verdict is cached by main sha, so the judge pays the
# minutes once per main-advance and every later read of the same main is a
# cache hit. UNAVAILABLE verdicts (whole-loop timeout) decay after 1h so a
# quiet day retries instead of freezing blind.
#
# Contract (testable in isolation; mirrors lib/attest-waiting.sh):
#   fleet_p14_main_line <repo_root>    prints exactly one line on stdout:
#     p14-main(main=<12hex>): ok suites=<n>
#     p14-main(main=<12hex>): red suites=<name[,name...]>[ missing=<t[,t...]>][ detail=<path>]
#     p14-main: UNAVAILABLE:<why>        — never a fabricated ok
#   Printed part names: shellcheck | semgrep | systemd-analyze | <suite-basename>
#   `missing=` = the binary is absent, that part skipped — honest blindness,
#   never folded into ok.
# Env: MEASURE_P14_MAIN_TREE=<dir>        run in this prepared tree (tests):
#                                      no git involved, verdict still cached
#                                      under sha key "fixture" when the state
#                                      dir is overridden (hermetic tests)
#      MEASURE_P14_MAIN_SHA=<sha>       measure this sha instead of origin/main
#      MEASURE_P14_MAIN_STATE=<dir>     cache dir (default
#                                      ~/workspaces/agent-state/measure/p14-main)
#      MEASURE_P14_MAIN_TIMEOUT_S       whole-verification budget (default 2100:
#                                      the honest 109-suite pass extrapolates to
#                                      ~34min on the reference VPS — the measured
#                                      22-suite prefix took 8min — and the
#                                      judge's 42-min cliff (fleet-ops#4891)
#                                      leaves the headroom; a clipped pass
#                                      decays after 1h and retries)
#      MEASURE_P14_MAIN_SUITE_TIMEOUT_S per-suite/step cap (default 300:
#                                      ci-standards-audit, the heaviest legit
#                                      suite, exceeded 120s on the reference
#                                      VPS — the #6159 rc=124 sighting — 300
#                                      is headroom, still bounded; every
#                                      timeout carries -k 30 so a TERM-ignoring
#                                      suite dies, the #3969 hang-kill class)
#      GITHUB_ACTIONS (Actions)         the detector short-circuits to
#                                      UNAVAILABLE:ci-context — the Actions P14
#                                      job already covers this exact commit and
#                                      a 109-suite pass inside the 3
#                                      measure.sh-executor tests would blow its
#                                      30-min budget. Drills disarm it by
#                                      prefixing GITHUB_ACTIONS= (empty).
#      MEASURE_P14_MAIN=0               skip entirely, stay silent (the suite
#                                      loop exports it so suites that
#                                      re-execute measure.sh terminate)

# Pure-bash comma-join. No IFS assignment, no subprocess — sgscan's
# ifs-tampering WARNING (the only 2 findings on the #6159 diff) adjudicated
# Act-on: the corpus keeps IFS=, out of lib/ and this deletes both
# occurrences. $1.. = the items; callers guard non-empty (set -u: $1). Part
# names are CI-derived identifiers (no commas), so the join is lossless.
_fleet_p14_main_join() {
    local out="$1" part
    shift
    for part in "$@"; do
        out="$out,$part"
    done
    printf '%s' "$out"
}

_fleet_p14_main_state() {
    printf '%s' "${MEASURE_P14_MAIN_STATE:-$HOME/workspaces/agent-state/measure/p14-main}"
}

# Compute the verdict for ONE prepared tree. Prints the line, always rc=0.
# Runs in a subshell: the caller's set -e and traps are isolated from every
# external command here (measure.sh dies mid-header if we let one fail).
_fleet_p14_main_compute() {
(
    local tree="$1" main_sha="$2" state="$3"
    local t0
    t0=$(date +%s)
    local budget="${MEASURE_P14_MAIN_TIMEOUT_S:-2100}"
    local stepcap="${MEASURE_P14_MAIN_SUITE_TIMEOUT_S:-300}"

    cd "$tree" 2>/dev/null || { echo "p14-main: UNAVAILABLE:tree-cd-failed"; return 0; }

    # --- the P14 suite list: exactly the lines ci.yml executes. ci.yml is the
    # single source; this must never drift from it, so it is parsed, not
    # copied. (The issue points at reusable-pr-checks.yml, which merely
    # executes the verify-command ci.yml passes it — the list lives there.)
    local list; list=$(mktemp -t p14-list.XXXXXX) 2>/dev/null \
        || { echo "p14-main: UNAVAILABLE:tmp-missing"; return 0; }
    grep -oE 'bash tests/[a-zA-Z0-9._-]+\.test\.sh' .github/workflows/ci.yml 2>/dev/null \
        | sed -E 's|bash tests/||; s|\.test\.sh$||' | sort -u > "$list" 2>/dev/null || true
    if [ ! -s "$list" ]; then
        rm -f "$list" 2>/dev/null || true
        echo "p14-main: UNAVAILABLE:p14-list-unreadable"
        return 0
    fi

    # --- shells/scan/units: the ci.yml static steps. PATH-prepended exactly
    # like ci.yml does (CI installs both into ~/.local/bin; this host keeps
    # its production copies there too).
    export PATH="$HOME/.local/bin:$PATH"

    local reds=() missing=() name out rc src
    local detail="$state/$main_sha.detail"

    # 1. shellcheck — ci.yml semantics: bin/!(*.py|*.ts) regular files, plus
    #    .github/scripts/gate-integrity.sh and install.sh, -x, no extra flags.
    if command -v shellcheck >/dev/null 2>&1; then
        local scfiles=() f
        for f in bin/*; do
            case "$f" in
                *.py|*.ts) ;;
                *) [ -f "$f" ] && scfiles+=("$f") ;;
            esac
        done
        for f in .github/scripts/gate-integrity.sh install.sh; do
            [ -f "$f" ] && scfiles+=("$f")
        done
        if [ "${#scfiles[@]}" -gt 0 ]; then
            rc=0
            timeout -k 30 "$stepcap" shellcheck -x "${scfiles[@]}" >"$detail.out" 2>&1 || rc=$?
            if [ "$rc" -ne 0 ]; then
                reds+=("shellcheck")
                { echo "--- shellcheck (rc=$rc)"; tail -5 "$detail.out" 2>/dev/null; } >> "$detail" 2>/dev/null || true
            fi
        fi
    else
        missing+=("shellcheck")
    fi

    # 2. semgrep — the exact ci.yml invocation (registry ruleset, --error).
    if command -v semgrep >/dev/null 2>&1; then
        src=0
        timeout -k 30 "$stepcap" semgrep --config p/default --error . >"$detail.out" 2>&1 || src=$?
        if [ "$src" -ne 0 ]; then
            reds+=("semgrep")
            { echo "--- semgrep (rc=$src)"; tail -5 "$detail.out" 2>/dev/null; } >> "$detail" 2>/dev/null || true
        fi
    else
        missing+=("semgrep")
    fi

    # 3. systemd-analyze verify — services/timers plain, slices
    #    --recursive-errors=no (fleet-ops#92, #4174). A missing ExecStart
    #    target is a REAL deploy fault: let it print as red.
    if command -v systemd-analyze >/dev/null 2>&1; then
        local unit
        shopt -s nullglob
        for unit in systemd/*.service systemd/*.timer; do
            if [ "$(date +%s)" -ge $((t0 + budget)) ]; then
                printf 'p14-main(main=%s): UNAVAILABLE:timeout(during-systemd-analyze) detail=%s\n' \
                    "${main_sha:0:12}" "$detail"
                return 0
            fi
            timeout -k 30 "$stepcap" systemd-analyze verify --man=no "$unit" >/dev/null 2>&1 \
                || { reds+=("systemd-analyze"); break; }
        done
        for unit in systemd/*.slice; do
            timeout -k 30 "$stepcap" systemd-analyze verify --man=no --recursive-errors=no "$unit" >/dev/null 2>&1 \
                || { reds+=("systemd-analyze"); break; }
        done
        shopt -u nullglob
    else
        missing+=("systemd-analyze")
    fi

    # 4. THE SUITE LIST — the part only a local run can see. Sequential, one
    #    heavy process at a time; per-suite cap; whole-loop budget. Suites that
    #    re-execute measure.sh see MEASURE_P14_MAIN=0 and stay cheap.
    # shellcheck disable=SC2030  # the export targets exactly the child suites
    export MEASURE_P14_MAIN=0
    local suites=0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ "$(date +%s)" -ge $((t0 + budget)) ]; then
            printf 'p14-main(main=%s): UNAVAILABLE:timeout(after=%d/%d suites) detail=%s\n' \
                "${main_sha:0:12}" "$suites" "$(wc -l < "$list")" "$detail"
            rm -f "$list" 2>/dev/null || true
            return 0
        fi
        if [ ! -f "tests/$name.test.sh" ]; then
            reds+=("$name")   # listed but gone: the #3740 incident class
            continue
        fi
        out=$(mktemp -t p14-suite.XXXXXX) 2>/dev/null || break
        rc=0
        # </dev/null: a suite that reads stdin (the #6159 live sighting — the
        # #22 fleet-blind-audit) would otherwise drain $list through its
        # inherited fd and silently truncate the pass to the suites before it
        # (22 of 109). -k 30: the #3969 hang-kill teeth.
        timeout -k 30 "$stepcap" bash "tests/$name.test.sh" > "$out" 2>&1 < /dev/null || rc=$?
        if [ "$rc" -ne 0 ]; then
            reds+=("$name")
            { echo "--- $name (rc=$rc)"; tail -5 "$out" 2>/dev/null; } >> "$detail" 2>/dev/null || true
        fi
        rm -f "$out" 2>/dev/null || true
        suites=$((suites + 1))
    done < "$list"
    rm -f "$list" 2>/dev/null || true

    # --- assemble the one line
    local joined bodies=""
    if [ "${#reds[@]}" -gt 0 ]; then
        joined=$(_fleet_p14_main_join "${reds[@]}")
        bodies="red suites=$joined"
    else
        bodies="ok"
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        joined=$(_fleet_p14_main_join "${missing[@]}")
        bodies="$bodies missing=$joined"
    fi
    if [ "${#reds[@]}" -gt 0 ]; then
        bodies="$bodies detail=$detail"
        touch "$detail" 2>/dev/null || true
    fi
    printf 'p14-main(main=%s): %s suites=%d\n' "${main_sha:0:12}" "$bodies" "$suites"
    rm -f "$detail.out" 2>/dev/null || true
)
}

fleet_p14_main_line() {
    local repo_root="${1:-$PWD}"

    # Nested invocation (a suite re-executed measure.sh inside our loop):
    # stay silent so the recursion terminates and costs nothing.
    # the parent never exports MEASURE_P14_MAIN; it only ever reads the
    # inherited value, so the subshell modification cannot be lost where it
    # matters
    # shellcheck disable=SC2031
    [ -n "${MEASURE_P14_MAIN:-}" ] && return 0

    local state; state=$(_fleet_p14_main_state)
    mkdir -p "$state" 2>/dev/null || true

    # --- resolve the target: TREE overrides (tests/fixtures, prepared trees);
    # otherwise measure EXACTLY origin/main via a throwaway worktree.
    local tree="" main_sha="" created=0
    if [ -n "${MEASURE_P14_MAIN_TREE:-}" ]; then
        tree="$MEASURE_P14_MAIN_TREE"
        main_sha="${MEASURE_P14_MAIN_SHA:-fixture}"
        if [ ! -d "$tree" ]; then
            echo "p14-main: UNAVAILABLE:tree-missing"
            return 0
        fi
    else
        # Actions runners already own the P14 verdict for this exact commit —
        # the very checks this line re-derives. A 109-suite pass here, inside
        # the 3 measure.sh-executor suites, blew the 30-min P14 job budget
        # (the #6159 courtship: 22-suite prefix = 8min alone). The judge's
        # VPS keeps the real, sha-cached verdict. Drills disarm with an
        # EMPTY GITHUB_ACTIONS (the #9/-#10-#6-8 fixture tests do exactly
        # that) — an unset-or-empty value means not-Actions.
        if [ -n "${GITHUB_ACTIONS:-}" ]; then
            echo "p14-main: UNAVAILABLE:ci-context(the-Actions-P14-job-covers-this-commit)"
            return 0
        fi
        if ! command -v git >/dev/null 2>&1; then
            echo "p14-main: UNAVAILABLE:git-missing"
            return 0
        fi
        if [ -n "${MEASURE_P14_MAIN_SHA:-}" ]; then
            main_sha="$MEASURE_P14_MAIN_SHA"
        else
            main_sha=$(git -C "$repo_root" rev-parse --short=12 origin/main 2>/dev/null) || {
                echo "p14-main: UNAVAILABLE:no-origin-main"
                return 0
            }
        fi
        # --- cache: facts (ok/red) about a sha are immortal; UNAVAILABLE
        # decays after 1h (mtime) so a quiet day retries, never frozen blind.
        # If the binary shas ever drift, the 12-hex key still guards.
        local cached cmts
        if cached=$(cat "$state/$main_sha" 2>/dev/null) \
           && printf '%s' "$cached" | grep -q '^p14-main'; then
            if printf '%s' "$cached" | grep -q 'UNAVAILABLE'; then
                cmts=$(stat -c %Y "$state/$main_sha" 2>/dev/null || echo 0)
                if [ "$(date +%s)" -lt $((cmts + 3600)) ]; then
                    printf '%s\n' "$cached"
                    return 0
                fi
            else
                printf '%s\n' "$cached"
                return 0
            fi
        fi
        # --- throwaway worktree of exactly that sha. Absolute path: a
        # relative one plants a live tree inside the -C target and trips
        # DEPLOY-CHECK-DIRTY-CLONE (fleet-ops#5687).
        if ! command -v mktemp >/dev/null 2>&1; then
            echo "p14-main: UNAVAILABLE:tmp-missing"
            return 0
        fi
        tree=$(mktemp -d -t p14-main-XXXXXXXX 2>/dev/null) || {
            echo "p14-main: UNAVAILABLE:tmp-missing"
            return 0
        }
        created=1
        (
            git -C "$repo_root" worktree prune >/dev/null 2>&1
            git -C "$repo_root" worktree add --quiet --detach "$tree" "$main_sha" >/dev/null 2>&1
        ) || {
            rm -rf "$tree" 2>/dev/null || true
            echo "p14-main: UNAVAILABLE:worktree-add-failed"
            return 0
        }
    fi

    # --- compute, isolated: any crash inside cost one UNAVAILABLE line, never
    # the header, and the worktree always dies with the subshell. Cleanup runs
    # AFTER compute inside the same subshell: the earlier order rm -rf'd the
    # tree before compute could cd into it, so every production (non-TREE) run
    # printed UNAVAILABLE:tree-cd-failed while the TREE-mode tests stayed
    # green (fleet-ops#6159, caught by the fixture-GIT-repo drill). rm -rf +
    # worktree prune (not worktree remove): once the dir is gone the
    # administrative state is exactly what prune exists to clean.
    local line
    line=$(
        _fleet_p14_main_compute "$tree" "$main_sha" "$state"
        # cleanup only what we created: TREE-mode fixtures belong to the caller
        if [ "$created" -eq 1 ]; then
            rm -rf "$tree" 2>/dev/null || true
            git -C "$repo_root" worktree prune >/dev/null 2>&1 || true
        fi
    ) 2>/dev/null
    if [ -z "$line" ]; then
        if [ "$created" -eq 1 ]; then
            rm -rf "$tree" 2>/dev/null || true
            git -C "$repo_root" worktree prune >/dev/null 2>&1 || true
        fi
        echo "p14-main: UNAVAILABLE:compute-failed"
        return 0
    fi

    # --- print first (the judge streams), then persist. Only real verdicts
    # about a sha are cached; TREE-mode fixtures cache under their own key,
    # which is exactly what hermetic tests want.
    printf '%s\n' "$line"
    local tmp; tmp=$(mktemp -t p14-cache.XXXXXX) 2>/dev/null || return 0
    printf '%s\n' "$line" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$state/$main_sha" 2>/dev/null || true
    return 0
}
