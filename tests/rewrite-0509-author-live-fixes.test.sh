#!/usr/bin/env bash
# tests/rewrite-0509-author-live-fixes.test.sh
#
# fleet-ops#5385: the 2026-09-11 live run of scripts/rewrite-0509-author.sh hit
# four defects (hot-fixed in a working copy, landed here), plus one more:
#   1. required_status_checks + enforce-admins declined the direct admin push
#      ("protected branch hook declined") -> the relax window must set
#      enforce_admins=false, and the restore verify must GET-verify it too.
#   2. The rollback snapshot was kept even when main still carried the bad
#      email -> snapshot refreshed whenever main is not yet rewritten.
#   3. The idempotent re-run check used "SHA still resolves", but old SHAs stay
#      reachable via refs/pull/* and untouched stale branches -> use
#      merge-base --is-ancestor against main instead.
#   4. (new) stage5's "default branch not main after rename-back" and
#      "protection missing on main" checks raced GitHub's eventual consistency
#      -> poll up to 12 times at 5s before declaring failure.
#
# Offline drills (repo stub-gh drill pattern): the script under test is a
# top-level runner (trap + dispatch), so each drill copies it with the dispatch
# section stripped, sources the functions, and stubs gh/sleep/git. Nothing runs
# against GitHub; stage2's mirror clone is redirected to a local fixture repo
# so refs/pull/* behaviour is exercised for real.
# shellcheck disable=SC1091,SC2030,SC2031,SC2034,SC2329
# (drill file: gh/sleep/git stubs are invoked via the sourced copy of the
# script under test; source paths are built at runtime; subshell exports are
# intentional)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/scripts/rewrite-0509-author.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "scripts/rewrite-0509-author.sh missing"
bash -n "$script" || fail "script: bash syntax error"
grep -qF 'prot_put true false' "$script" \
  || fail "protect_off must relax with enforce_admins=false (prot_put true false)"
grep -qF '.enforce_admins.enabled' "$script" \
  || fail "restore verify must GET-check enforce_admins"

scratch="$(mktemp -d -t rw0509.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

style(){ # $1 = tag; emit a funcs-only copy of the script (dispatch stripped)
  sed -e '/^# --- dispatch/,$d' \
      -e '/^while ((\$#))/,/^esac; shift; done$/d' \
      "$script" > "$scratch/funcs-$1.sh"
  echo 'trap - EXIT' >> "$scratch/funcs-$1.sh"
}

first_json_line(){ # first line starting "BODY: {" in $1
  grep -m1 '^BODY: {' "$1" | sed 's/^BODY: //'
}

# === Drill (a): protection dance =============================================
style a
(
  export REWRITE_0509_LOGROOT="$scratch/a"
  mkdir -p "$scratch/a/work"
  cat > "$scratch/a/protection-before.json" <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": true},
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": {"enabled": false},
  "allow_force_pushes": {"enabled": false},
  "allow_deletions": {"enabled": false},
  "block_creations": {"enabled": false},
  "required_conversation_resolution": {"enabled": false},
  "lock_branch": {"enabled": false},
  "allow_fork_syncing": {"enabled": false}
}
EOF
  cat > "$scratch/a/ruleset.json" <<'EOF'
{"name":"0509 branch rules","target":"branch","enforcement":"active",
 "conditions":{},"rules":[]}
EOF
  RULES_JSON="$scratch/a/ruleset.json"
  GH_LOG="$scratch/a/gh.log"; : > "$GH_LOG"
  gh(){
    printf 'CALL: %s\n' "$*" >> "$GH_LOG"
    local args=("$@") m=GET path=""
    local i body
    for ((i=0; i<${#args[@]}; i++)); do
      case ${args[i]} in
        -X) m=${args[i+1]:-GET};;
        --input)
          body="$(cat | tr -d '\n')"       # consume the piped body (one line)
          printf 'BODY: %s\n' "$body" >> "$GH_LOG"
          path=${args[i-1]:-}      # arg right before --input is the path
          break;;
        repos/*) [[ $m == GET ]] && path=${args[i]};;
      esac
    done
    [[ $m == PUT ]] && return 0
    case ${path:-} in
      repos/Nishfleet/0509/branches/main/protection)
        canned='{"allow_force_pushes":{"enabled":false},"enforce_admins":{"enabled":true}}';;
      repos/Nishfleet/0509/rulesets/21391031)
        canned='{"enforcement":"active"}';;
      *) echo "STUB-gh unhandled GET: $*" >&2; return 1;;
    esac
    local j   # honour --jq the way gh does
    for ((j=0; j<${#args[@]}; j++)); do
      if [[ ${args[j]} == --jq ]]; then jq -r "${args[j+1]}" <<<"$canned"; return 0; fi
    done
    printf '%s\n' "$canned"
  }
  . "$scratch/funcs-a.sh"
  PROT_JSON="$scratch/a/protection-before.json"
  RULES_JSON="$scratch/a/ruleset.json"

  # relax: the protection PUT body must carry enforce_admins=false
  protect_off
  relax_body="$(first_json_line "$GH_LOG")"
  [[ -n $relax_body ]] || fail "no protection PUT body logged on relax: $(cat "$GH_LOG")"
  jq -e '.enforce_admins == false and .allow_force_pushes == true' <<<"$relax_body" \
    || { echo "$relax_body"; fail "relax PUT must carry enforce_admins=false + allow_force_pushes=true"; }
  grep -qF 'CALL: api -X PUT repos/Nishfleet/0509/rulesets/21391031' "$GH_LOG" \
    || fail "ruleset must be disabled during the relax window"

  # restore: the PUT body must re-carry the fetched enforce_admins value (true)
  : > "$GH_LOG"
  restore_out="$(protect_on 2>&1)" \
    || fail "protect_on should succeed with GET-verified enforce_admins=true"
  restore_body="$(first_json_line "$GH_LOG")"
  jq -e '.enforce_admins == true and .allow_force_pushes == false' <<<"$restore_body" \
    || fail "restore PUT must re-carry the fetched enforce_admins value (true)"
  grep -q 'protection restored.*ruleset active (GET-verified)' <<<"$restore_out" \
    || fail "restore verify did not GET-verify; got: $restore_out"
) || fail "drill (a) relax/restore body"
ok "Drill (a): prot_put emits enforce_admins=false when relaxing, fetched value when restoring"

# negative: restore verify catches enforce_admins drift
(
  export REWRITE_0509_LOGROOT="$scratch/a"
  : > "$scratch/a/gh.log"
  gh(){  # --jq-aware stub; the drifted enforce_admins is what must trip the gate
    local args=("$@") m=GET path="" jq=""
    local i
    for ((i=0; i<${#args[@]}; i++)); do
      case ${args[i]} in
        -X) m=${args[i+1]:-GET};;
        --jq) jq=${args[i+1]:-""};;
        repos/*) path=${args[i]};;
      esac
    done
    [[ $m == PUT ]] && return 0
    case ${path:-} in
      repos/Nishfleet/0509/branches/main/protection)
        canned='{"allow_force_pushes":{"enabled":false},"enforce_admins":{"enabled":false}}';;
      repos/Nishfleet/0509/rulesets/21391031)
        canned='{"enforcement":"active"}';;
      *) return 1;;
    esac
    jq -r "$jq" <<<"$canned"
  }
  . "$scratch/funcs-a.sh"
  PROT_JSON="$scratch/a/protection-before.json"   # snapshot says enforce_admins=true
  RULES_JSON="$scratch/a/ruleset.json"
  set +e
  restore_out="$(protect_on 2>&1)"; rc=$?
  set -e
  if ((rc == 0)); then fail "protect_on must report failure when enforce_admins drifted"; fi
  grep -q 'LOUD: restore verify failed.*enforce_admins' <<<"$restore_out" \
    || fail "expected LOUD failure naming enforce_admins; got: $restore_out"
) || fail "drill (a-) negative restore verify"
ok "Drill (a-): restore verify flags drifted enforce_admins"

# === Drill (b): ancestor check ===============================================
mk_fixture(){ # $1 = dir; $2 = pull-only|ancestor; prints short SHA of old commit
  local d="$1" mode="$2"
  git init -q -b main "$d"
  git -C "$d" -c user.email=x@x -c user.name=x commit -q --allow-empty -m base
  local old base
  base=$(git -C "$d" rev-parse HEAD)
  if [[ $mode == "pull-only" ]]; then
    # old commit live only under refs/pull/1/head (GitHub keeps old PR heads)
    git -C "$d" -c user.email=x@x -c user.name=nishant345@users.noreply.github.com \
      commit -q --allow-empty -m "old C off-main"
    old=$(git -C "$d" rev-parse HEAD)
    git -C "$d" update-ref refs/pull/1/head "$old"
    git -C "$d" update-ref refs/heads/main "$base"
  else
    git -C "$d" -c user.email=x@x -c user.name=nishant345@users.noreply.github.com \
      commit -q --allow-empty -m "old C on main"
    old=$(git -C "$d" rev-parse HEAD)
    git -C "$d" update-ref refs/pull/1/head "$old"
  fi
  git -C "$d" rev-parse --short=9 "$old"
}

style b
export FXFIXTURE=""
run_stage2(){ # $1 = fixture path, $2 = KNOWN_SHORT; run stage2 in a subshell
  (
    export FXFIXTURE="$1"
    export REWRITE_0509_LOGROOT="$scratch/b"
    mkdir -p "$scratch/b/work"
    local REAL_GIT
    REAL_GIT="$(command -v git)"
    git(){ # intercept stage2's mirror clone -> local fixture
      if [[ $1 == "clone" && $2 == "--mirror" ]]; then
        # stub args: clone --mirror <url> <dest>; run off the fixture instead
        # shellcheck disable=SC2319
        "$REAL_GIT" clone --mirror "file://$FXFIXTURE" "$4"
        return $?
      fi
      "$REAL_GIT" "$@"
    }
    . "$scratch/funcs-b.sh"
    BAD="nishant345@users.noreply.github.com"
    KNOWN_SHORT="$2"
    stage2
  )
}

# pull-only case: must PASS (the old "SHA still resolves" check would have died)
fx="$scratch/fixture-pull"
short=$(mk_fixture "$fx" pull-only)
out="$(run_stage2 "$fx" "$short" 2>&1)" \
  || fail "stage2 should PASS when the old SHA sits only under refs/pull: $out"
grep -q "already clean" <<<"$out" \
  || fail "expected idempotent re-run detection: $out"
ok "Drill (b): refs/pull-only old SHA passes the idempotent re-run check"

# control: old SHA still an ancestor of main must still die
fx2="$scratch/fixture-anc"
short2=$(mk_fixture "$fx2" ancestor)
out="$(run_stage2 "$fx2" "$short2" 2>&1; echo RC=$?)"
grep -q "still an ancestor of main" <<<"$out" \
  || fail "ancestor-of-main old SHA must still fail: $out"
grep -q "RC=1" <<<"$out" || fail "ancestor case should exit nonzero: $out"
ok "Drill (b-): ancestor-of-main old SHA still fails (check is not vacuous)"

# === Drill (c): stage5 rename-back eventual-consistency polling ==============
style c
(
  export REWRITE_0509_LOGROOT="$scratch/c"
  mkdir -p "$scratch/c"
  : > "$scratch/c/sleeps"
  sleep(){ printf '%s\n' "$*" >> "$scratch/c/sleeps"; }
  DB_CALLS="$scratch/c/db-calls"; : > "$DB_CALLS"
  PROT_CALLS="$scratch/c/prot-calls"; : > "$PROT_CALLS"
  gh(){
    case "$*" in
      *"-X POST"*) return 0;;
      *"repos/Nishfleet/0509 --jq .default_branch")
        printf 'call\n' >> "$DB_CALLS"
        # GitHub lag: first 4 GETs still report the cachebust name
        if [[ $(wc -l <"$DB_CALLS") -le 4 ]]; then
          printf 'main-rewrite-cachebust\n'; else printf 'main\n'; fi
        return 0;;
      *"repos/Nishfleet/0509/branches/main/protection --jq .url")
        printf 'call\n' >> "$PROT_CALLS"
        # lag: first 3 GETs fail (404-ish)
        if [[ $(wc -l <"$PROT_CALLS") -le 3 ]]; then return 1; fi
        printf 'https://api.github.com/repos/Nishfleet/0509/branches/main/protection\n'
        return 0;;
    esac
    echo "STUB-gh unhandled: $*" >&2; return 1
  }
  . "$scratch/funcs-c.sh"
  stage5 || fail "stage5 must PASS when both laggy checks recover"
  [[ $(wc -l <"$DB_CALLS") -gt 4 ]] \
    || fail "default-branch check did not retry: $(wc -l <"$DB_CALLS") calls"
  [[ $(wc -l <"$PROT_CALLS") -gt 3 ]] \
    || fail "protection check did not retry: $(wc -l <"$PROT_CALLS")"
  [[ $(wc -l <"$scratch/c/sleeps") -ge 5 ]] \
    || fail "expected 5s backoff between polls: $(cat "$scratch/c/sleeps")"
) || fail "drill (c) retry path"
ok "Drill (c): stage5 retries laggy rename-back checks and passes"

# negative: permanently stale default_branch must still die (bounded, loud)
(
  export REWRITE_0509_LOGROOT="$scratch/c"
  : > "$scratch/c/sleeps"
  sleep(){ :; }
  gh(){
    case "$*" in
      *"-X POST"*) return 0;;
      *"repos/Nishfleet/0509 --jq .default_branch") printf 'main-rewrite-cachebust\n'; return 0;;
    esac; return 1
  }
  . "$scratch/funcs-c.sh"
  set +e
  stale_out="$(stage5 2>&1)"; rc=$?
  set -e
  if ((rc == 0)); then fail "stage5 must FAIL when default_branch never converges"; fi
  grep -q 'FATAL: default branch not main' <<<"$stale_out" \
    || fail "expected bounded loud failure; got: $stale_out"
) || fail "drill (c-): permanently stale default_branch did not fail loud"
ok "Drill (c-): permanently stale default_branch still fails loud"

echo "ALL OK"
