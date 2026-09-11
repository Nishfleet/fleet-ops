#!/usr/bin/env bash
# rewrite-0509-author.sh — fleet-ops#5385: strip nishant345@users.noreply.github.com
# from Nishfleet/0509 (4 commits on main), force-push rewritten refs, cache-bust,
# reseed the worker checkout, then re-enrol intake by reverting fleet-ops#5384.
# Staged + idempotent; every stage logs to $LOGROOT/run-<ts>.log. --rollback
# restores the pre-rewrite refs from $BEFORE. Only run for real after #5384 merges.
#
#   --dry-run          every stage except push/rename/protection; prints intents
#   --rollback         stage R only
#   --skip-drain       skip the intake-drain wait
#   --max-drain-min N  bound the drain wait (default 360)
#   --no-cachebust     skip the main -> tmp -> main rename
set -Eeuo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
PATH="$HOME/.local/bin:$PATH"

REPO=Nishfleet/0509 ISSUE=5385 RULESET=21391031
BAD=nishant345@users.noreply.github.com
KNOWN_SHORT="bfa176df6 45be71f49 3a930dd53 df0cf8a47"
LOGROOT="${REWRITE_0509_LOGROOT:-/home/nish/workspaces/agent-state/0509-history-rewrite}"
WORK="$LOGROOT/work" MIRROR="$WORK/0509.git" BEFORE="$LOGROOT/0509.before.git"
INTAKE_JSON="${REWRITE_0509_INTAKE_JSON:-/home/nish/workspaces/tooling/fleet-ops-deploy-clone/config/intake-repos.json}"
SEED="${REWRITE_0509_SEED:-/home/nish/workspaces/products/0509}"
PROT_JSON="$LOGROOT/protection-before.json" RULES_JSON="$LOGROOT/ruleset-$RULESET.json"
DRY=0 ROLLBACK=0 SKIP_DRAIN=0 CACHEBUST=1 MAX_DRAIN=360
ALREADY=0 DISABLED=0 VDONE=0 KNOWN_FULL="" TREE_BEFORE="" COUNT_BEFORE=""

while (($#)); do case "$1" in
  --dry-run) DRY=1;; --rollback) ROLLBACK=1;; --skip-drain) SKIP_DRAIN=1;;
  --no-cachebust) CACHEBUST=0;; --max-drain-min) MAX_DRAIN="${2:?--max-drain-min needs N}"; shift;;
  -h|--help) sed -n '2,13p' "$0"; exit 0;;
  *) echo "unknown flag: $1" >&2; exit 2;;
esac; shift; done

mkdir -p "$WORK"
LOG="$LOGROOT/run-$(date -u +%Y%m%dT%H%M%SZ).log"
log(){ printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }
vd(){ VDONE=1; echo "VERDICT: $*"; }
die(){ log "FATAL: $*"; vd "FAIL $*"; exit 1; }
on_exit(){ local rc=$?
  if ((DISABLED)); then log "exit-trap: restoring protection"; protect_on || log "LOUD: protection restore failed"; fi
  if ((VDONE==0)); then echo "VERDICT: FAIL unexpected-exit rc=$rc"; fi; }
trap on_exit EXIT

# --- protection dance -------------------------------------------------------
prot_put(){ # $1 = allow_force_pushes bool, $2 = enforce_admins override (optional); GET shape -> PUT shape
  local ea="${2:-}"; [[ -n $ea ]] || ea=$(jq '.enforce_admins.enabled' "$PROT_JSON")
  jq --argjson afp "$1" --argjson ea "$ea" '{
    required_status_checks:(.required_status_checks|if .==null then null
      else {strict,checks:(.checks//(.contexts|map({context:.})))} end),
    enforce_admins:$ea,
    required_pull_request_reviews:(.required_pull_request_reviews|if .==null then null else {
      dismiss_stale_reviews,require_code_owner_reviews,required_approving_review_count,
      require_last_push_approval:(.require_last_push_approval//false),
      dismissal_restrictions:(.dismissal_restrictions|if .==null then null else
        {users:[.users[]?.login],teams:[.teams[]?.slug]} end),
      bypass_pull_request_allowances:(.bypass_pull_request_allowances|if .==null then null else
        {users:[.users[]?.login],teams:[.teams[]?.slug],apps:[.apps[]?.slug]} end)} end),
    restrictions:(.restrictions|if .==null then null else
      {users:[.users[]?.login],teams:[.teams[]?.slug],apps:[.apps[]?.slug]} end),
    required_linear_history:(.required_linear_history.enabled//false),
    allow_force_pushes:$afp,
    allow_deletions:(.allow_deletions.enabled//false),
    block_creations:(.block_creations.enabled//false),
    required_conversation_resolution:(.required_conversation_resolution.enabled//false),
    lock_branch:(.lock_branch.enabled//false),
    allow_fork_syncing:(.allow_fork_syncing.enabled//false)}' "$PROT_JSON" \
    | gh api -X PUT "repos/$REPO/branches/main/protection" --input - >/dev/null
}
ruleset_put(){ # $1 = active|disabled; PUT = fetched body's writable fields, enforcement changed
  jq --arg e "$1" 'to_entries
    |map(select(.key|IN("name","target","enforcement","conditions","rules","bypass_actors")))
    |from_entries|.enforcement=$e' "$RULES_JSON" \
    | gh api -X PUT "repos/$REPO/rulesets/$RULESET" --input - >/dev/null
}
protect_off(){ DISABLED=1; prot_put true false; ruleset_put disabled
  log "protection relaxed: allow_force_pushes=true, enforce_admins=false (required checks would decline a direct admin push), ruleset $RULESET disabled"; }
protect_on(){ prot_put false; ruleset_put active; DISABLED=0
  local afp enf
  afp=$(gh api "repos/$REPO/branches/main/protection" --jq .allow_force_pushes.enabled)
  enf=$(gh api "repos/$REPO/rulesets/$RULESET" --jq .enforcement)
  local ea_want ea_now; ea_want=$(jq -r '.enforce_admins.enabled' "$PROT_JSON")
  ea_now=$(gh api "repos/$REPO/branches/main/protection" --jq .enforce_admins.enabled)
  if [[ "$afp" != "false" || "$enf" != "active" || "$ea_now" != "$ea_want" ]]; then
    log "LOUD: restore verify failed afp=$afp enf=$enf enforce_admins=$ea_now(want $ea_want)"; return 1; fi
  log "protection restored: allow_force_pushes=false, enforce_admins=$ea_now, ruleset active (GET-verified)"; }

# --- refspec collection -----------------------------------------------------
collect_refspecs(){ # $1 = git dir, stdin = open-PR head branch names
  local dir="$1" b t
  printf 'refs/heads/main:refs/heads/main\n'
  while read -r t; do printf 'refs/tags/%s:refs/tags/%s\n' "$t" "$t"; done \
    < <(git -C "$dir" for-each-ref refs/tags --format='%(refname:strip=2)')
  while read -r b; do
    if [[ -n $b ]] && git -C "$dir" rev-parse --verify --quiet "refs/heads/$b" >/dev/null; then
      printf 'refs/heads/%s:refs/heads/%s\n' "$b" "$b"; fi
  done
}
open_pr_heads(){ gh pr list -R "$REPO" --state open -L 200 --json headRefName --jq '.[].headRefName'; }

# --- stages -----------------------------------------------------------------
stage0(){ # preflight
  gh api user --jq .login >/dev/null 2>&1 || die "gh auth not ok (gh api user failed)"
  git filter-repo --version >/dev/null 2>&1 || die "git-filter-repo missing"
  command -v jq >/dev/null || die "jq missing"
  jq -e '[.deferred[]?.name]|index("0509")' "$INTAKE_JSON" >/dev/null 2>&1 \
    || die "0509 not under .deferred in $INTAKE_JSON (merge fleet-ops#5384 first)"
  jq -e '[.repos[]?.name]|index("0509")|not' "$INTAKE_JSON" >/dev/null 2>&1 \
    || die "0509 still under .repos in $INTAKE_JSON"
  log "stage0 ok — 0509 deferred in intake config"; }

drained(){ # 0 only when all three drain conditions hold
  if systemctl --user list-units --no-legend 'pi-issue@0509-*' 2>/dev/null | grep -q .; then
    log "drain: pi-issue@0509-* still active"; return 1; fi
  local mq since
  mq=$(gh api graphql -f query='query{repository(owner:"Nishfleet",name:"0509"){mergeQueue(branch:"main"){entries{totalCount}}}}' \
      --jq '.data.repository.mergeQueue.entries.totalCount // 0') || mq=ERR
  if [[ $mq != "0" ]]; then log "drain: merge queue state=$mq"; return 1; fi
  since=$(date -u -d '20 min ago' +%Y-%m-%dT%H:%M:%SZ)
  if [[ $(gh pr list -R "$REPO" --state merged --search "merged:>$since" -L 1 --json number --jq 'length') != "0" ]]; then
    log "drain: merge inside last 20min"; return 1; fi
  return 0
}
stage1(){ # drain gate
  if ((SKIP_DRAIN)); then log "stage1 skipped (--skip-drain)"; return; fi
  local deadline=$((SECONDS + MAX_DRAIN*60))
  until drained; do
    if ((SECONDS >= deadline)); then log "WARN drain timeout after ${MAX_DRAIN}m — proceeding anyway"; return; fi
    sleep 300
  done
  log "stage1 ok — intake drained"; }

stage2(){ # fresh mirror + snapshots + known-SHA check
  rm -rf "$MIRROR"
  git clone --mirror "https://github.com/$REPO.git" "$MIRROR" >>"$LOG" 2>&1 || die "mirror clone failed"
  git -C "$MIRROR" for-each-ref --format='%(refname) %(objectname)' | sort >"$LOGROOT/refs-before.txt"
  if git -C "$MIRROR" log refs/heads/main --format='%ae%n%ce' | grep -Fqx "$BAD"; then
    rm -rf "$BEFORE"; cp -a "$MIRROR" "$BEFORE"; log "rollback snapshot refreshed -> $BEFORE (main not yet rewritten)"
  elif [[ -d $BEFORE ]]; then log "keeping rollback snapshot $BEFORE (main already rewritten)"
  else cp -a "$MIRROR" "$BEFORE"; log "rollback snapshot -> $BEFORE"; fi
  TREE_BEFORE=$(git -C "$MIRROR" rev-parse 'refs/heads/main^{tree}')
  COUNT_BEFORE=$(git -C "$MIRROR" rev-list --count refs/heads/main)
  git -C "$MIRROR" log refs/heads/main --format='%H%x09%ae%x09%ce' \
    | awk -F'\t' -v b="$BAD" '$2==b||$3==b{print $1}' | sort -u >"$LOGROOT/bad-main.txt"
  git -C "$MIRROR" log --all --format='%H%x09%ae%x09%ce' \
    | awk -F'\t' -v b="$BAD" '$2==b||$3==b{print $1}' | sort -u >"$LOGROOT/bad-all.txt"
  if [[ -s $LOGROOT/bad-main.txt ]]; then
    local s f
    for s in $KNOWN_SHORT; do
      f=$(git -C "$MIRROR" rev-parse --verify --quiet "$s^{commit}") || true
      [[ -n $f ]] || die "bad commits on main but known SHA $s does not resolve"
      KNOWN_FULL+="$f "
    done
    KNOWN_FULL=${KNOWN_FULL% }
    tr ' ' '\n' <<<"$KNOWN_FULL" | sort >"$WORK/known-full.txt"
    if ! diff -q "$WORK/known-full.txt" "$LOGROOT/bad-main.txt" >/dev/null; then
      die "bad-email commits on main are not the 4 known SHAs: $(tr '\n' ' ' <"$LOGROOT/bad-main.txt")"; fi
    log "stage2 ok — tree=$TREE_BEFORE commits=$COUNT_BEFORE bad-main=4(known) bad-all-refs=$(wc -l <"$LOGROOT/bad-all.txt")"
  else
    # Old SHAs stay reachable via refs/pull/* and untouched stale branches; the
    # invariant is "not an ancestor of main", not "does not resolve".
    for s in $KNOWN_SHORT; do
      if git -C "$MIRROR" rev-parse --verify --quiet "$s^{commit}" >/dev/null \
         && git -C "$MIRROR" merge-base --is-ancestor "$s" refs/heads/main 2>/dev/null; then
        die "main clean of $BAD yet $s is still an ancestor of main"; fi
    done
    ALREADY=1; log "stage2 — main already clean of $BAD (idempotent re-run)"
  fi; }

stage3(){ # filter-repo rewrite + invariants
  if ((ALREADY)); then
    [[ -f $LOGROOT/commit-map.txt ]] || die "already rewritten; no prior commit-map.txt"
    log "stage3 skipped — prior commit-map.txt reused"; return; fi
  cat >"$WORK/mailmap" <<EOF
Nish <257724087+nish3451@users.noreply.github.com> Nish <$BAD>
Nishfleet Agent <agent@nishfleet.local> Nishfleet Agent <$BAD>
Nish <257724087+nish3451@users.noreply.github.com> <$BAD>
EOF
  local out
  if ! out=$(cd "$MIRROR" && git filter-repo --mailmap "$WORK/mailmap" 2>&1); then
    if grep -qi force <<<"$out"; then
      log "filter-repo demanded --force on a mirror; retrying"
      (cd "$MIRROR" && git filter-repo --mailmap "$WORK/mailmap" --force) >>"$LOG" 2>&1 \
        || die "filter-repo --force failed"
    else printf '%s\n' "$out" >>"$LOG"; die "filter-repo failed (see $LOG)"; fi
  fi
  cp "$MIRROR/filter-repo/commit-map" "$LOGROOT/commit-map.txt" \
    || die "commit-map missing at $MIRROR/filter-repo/commit-map"
  if git -C "$MIRROR" log --all --format='%ae %ce' | grep -Fq "$BAD"; then
    die "invariant: $BAD still present after rewrite"; fi
  if [[ $(git -C "$MIRROR" rev-parse 'refs/heads/main^{tree}') != "$TREE_BEFORE" ]]; then
    die "invariant: main tree changed"; fi
  if [[ $(git -C "$MIRROR" rev-list --count refs/heads/main) != "$COUNT_BEFORE" ]]; then
    die "invariant: commit count changed"; fi
  while read -r t; do
    git -C "$MIRROR" rev-parse --verify --quiet "$t^{}" >/dev/null \
      || die "invariant: tag $t no longer resolves"
  done < <(git -C "$BEFORE" for-each-ref refs/tags --format='%(refname)')
  local s
  for s in $KNOWN_FULL; do
    grep -q "^$s " "$LOGROOT/commit-map.txt" || die "invariant: $s missing from commit-map"; done
  log "stage3 ok — 0 bad emails, tree+count preserved, tags resolve, 4 SHAs mapped"; }

stage4(){ # relax protection, force-push, restore
  local rs=() line prheads
  prheads=$(open_pr_heads) || die "gh pr list failed"
  while read -r line; do rs+=("$line"); done < <(collect_refspecs "$MIRROR" <<<"$prheads")
  local leases=() r old
  for line in "${rs[@]}"; do
    r=${line%%:*}; old=$(awk -v k="$r" '$1==k{print $2}' "$LOGROOT/refs-before.txt")
    [[ -n $old ]] || die "no stage2 snapshot SHA for $r — cannot lease it"
    leases+=("--force-with-lease=$r:$old")
  done
  if ((DRY)); then
    log "stage4 dry-run: would relax protection, push --atomic with ${#leases[@]} leases over ${#rs[@]} refspecs, restore:"
    printf '  %s\n' "${rs[@]}" >>"$LOG"; printf '  %s\n' "${rs[@]}" >&2
    return; fi
  gh api "repos/$REPO/branches/main/protection" >"$PROT_JSON" || die "cannot fetch protection"
  gh api "repos/$REPO/rulesets/$RULESET" >"$RULES_JSON" || die "cannot fetch ruleset $RULESET"
  protect_off
  printf '%s\n' "${rs[@]}" >"$LOGROOT/pushed-refs.txt"
  # Atomic + leased: no bare --force. Each ref is overwritten only if the remote
  # still holds the SHA we snapshotted in stage2; anything that moved (e.g. an
  # auto-merge landing inside the protection window) aborts the WHOLE push.
  if ! git -C "$MIRROR" push --atomic "${leases[@]}" "https://github.com/$REPO.git" "${rs[@]}" >>"$LOG" 2>&1; then
    if ((DISABLED)); then protect_on || log "LOUD: restore failed"; fi
    die "force-push failed"; fi
  protect_on || die "protection restore failed"
  log "stage4 ok — pushed ${#rs[@]} refs, protection restored"; }

# --- eventual-consistency polls (fleet-ops#5385 live run) -------------------
# GitHub lags cross-ref effects: after the rename-back, .default_branch and the
# re-attached classic protection on main can be stale for seconds. Poll before
# declaring failure so one healthy run is not failed by a lag.
poll_default_branch(){ # poll default_branch until it is "main" (12 tries, 5s apart)
  local i db
  for ((i=1; i<=12; i++)); do
    db=$(gh api "repos/$REPO" --jq .default_branch)
    if [[ $db == "main" ]]; then return 0; fi
    ((i<12)) && { log "poll: .default_branch=$db (want main), retry $i/11"; sleep 5; }
  done; return 1
}
poll_protection_present(){ # poll the classic protection GET on main (12 tries, 5s apart)
  local i
  for ((i=1; i<=12; i++)); do
    if gh api "repos/$REPO/branches/main/protection" --jq .url >/dev/null 2>&1; then return 0; fi
    ((i<12)) && { log "poll: main protection not visible yet, retry $i/11"; sleep 5; }
  done; return 1
}

stage5(){ # cache bust: rename main away and back
  if ((CACHEBUST==0)); then log "stage5 skipped (--no-cachebust)"; return; fi
  if ((DRY)); then log "stage5 dry-run: would rename main->main-rewrite-cachebust, wait 60s, rename back"; return; fi
  gh api -X POST "repos/$REPO/branches/main/rename" -f new_name=main-rewrite-cachebust >/dev/null \
    || die "rename away failed"
  sleep 60
  gh api -X POST "repos/$REPO/branches/main-rewrite-cachebust/rename" -f new_name=main >/dev/null \
    || die "rename back failed"
  poll_default_branch || die "default branch not main after rename-back (12 polls)"
  poll_protection_present || die "protection missing on main after rename-back (12 polls)"
  log "stage5 ok — default branch main, protection present"; }

stage6(){ # reseed the worker checkout
  if [[ ! -d $SEED/.git ]]; then log "stage6 WARN: $SEED missing — skip"; return; fi
  git -C "$SEED" fetch origin >>"$LOG" 2>&1 || log "WARN: seed fetch failed"
  if ((DRY)); then
    log "stage6 dry-run: fetched; would prune, update-ref main->origin/main, reset if HEAD=main, worktree prune"
    return; fi
  git -C "$SEED" remote prune origin >>"$LOG" 2>&1 || true
  git -C "$SEED" update-ref refs/heads/main origin/main
  if [[ $(git -C "$SEED" rev-parse --abbrev-ref HEAD) == "main" ]]; then
    git -C "$SEED" reset --hard origin/main >>"$LOG" 2>&1 || die "seed reset failed"; fi
  git -C "$SEED" worktree prune
  log "stage6 ok — seed refreshed"; }

stage7(){ # verify rewritten identities + report + issue comment
  local rep="$LOGROOT/report.md" s old new ae al cl nfail=0 rows="" cstat
  for s in $KNOWN_SHORT; do
    old=$(awk -v p="$s" 'index($1,p)==1{print $1; exit}' "$LOGROOT/commit-map.txt")
    new=$(awk -v p="$s" 'index($1,p)==1{print $2; exit}' "$LOGROOT/commit-map.txt")
    if [[ -z $old || -z $new ]]; then nfail=1; rows+="| $s | MISSING | |"$'\n'; continue; fi
    ae=$(git -C "$MIRROR" log -1 --format='%ae' "$new")
    if ((DRY)); then
      rows+="| \`${old:0:9}\` | \`${new:0:9}\` | local: $(git -C "$MIRROR" log -1 --format='%an <%ae> / %cn <%ce>' "$new") |"$'\n'
      continue; fi
    al=$(gh api "repos/$REPO/commits/$new" --jq '.author.login // "none"' 2>/dev/null || echo ERR)
    cl=$(gh api "repos/$REPO/commits/$new" --jq '.committer.login // "none"' 2>/dev/null || echo ERR)
    if [[ $al == nishant345 || $cl == nishant345 ]]; then nfail=1; fi
    if [[ $ae == 257724087+* && $al != nish3451 ]]; then nfail=1; fi
    rows+="| \`${old:0:9}\` | \`${new:0:9}\` | author=$al committer=$cl |"$'\n'
  done
  cstat="(dry-run: not checked)"
  if ((DRY==0)); then
    if gh api "repos/$REPO/contributors?per_page=100" --jq '.[].login' | grep -qx nishant345; then
      cstat="nishant345 still listed — cache pending (GitHub lags)"; else cstat="nishant345 gone"; fi
  fi
  {
    echo "# 0509 history-rewrite report (fleet-ops#$ISSUE)"; echo
    if ((DRY)); then echo "**DRY RUN** — nothing pushed, no protection/rename changes."; echo; fi
    echo "- tree: \`$TREE_BEFORE\` == \`$(git -C "$MIRROR" rev-parse 'refs/heads/main^{tree}')\`"
    echo "- commits: $COUNT_BEFORE == $(git -C "$MIRROR" rev-list --count refs/heads/main)"
    echo "- $BAD on any ref after rewrite: $(git -C "$MIRROR" log --all --format='%ae %ce' | grep -Fc "$BAD" || true)"
    echo; echo "| old | new | identity after |"; echo "|---|---|---|"; printf '%s' "$rows"
    echo; echo "## refs pushed"
    if [[ -f $LOGROOT/pushed-refs.txt ]]; then awk '{printf "- `%s`\n",$0}' "$LOGROOT/pushed-refs.txt"
    else echo "- none (dry-run)"; fi
    echo; echo "## protection"
    if [[ -f $PROT_JSON ]]; then echo "- classic + ruleset $RULESET relaxed then restored (GET-verified)"
    else echo "- untouched"; fi
    echo; echo "## contributors"; echo "- $cstat"; echo; echo "## verdict"
    if ((nfail)); then echo "FAIL — identity check(s) failed"; else echo "PASS"; fi
  } >"$rep"
  log "report -> $rep"
  if ((DRY)); then log "dry-run: would post report to fleet-ops#$ISSUE"
  else gh issue comment "$ISSUE" -R Nishfleet/fleet-ops --body-file "$rep" >/dev/null \
    || log "WARN: issue comment failed"; fi
  if ((nfail)); then vd "FAIL identity check(s) failed"; exit 1; fi
  log "stage7 ok"; }

stage8(){ # resume intake: revert the fleet-ops#5384 squash
  if ((DRY)); then log "stage8 dry-run: would revert the #5384 merge commit on fleet-ops, PR + auto-merge"; return; fi
  local msha url fo="$WORK/fleet-ops"
  msha=$(gh pr view 5384 -R Nishfleet/fleet-ops --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null || true)
  [[ -n $msha ]] || { log "WARN: #5384 has no mergeCommit — open the revert PR by hand"; return; }
  rm -rf "$fo"
  git clone "https://github.com/Nishfleet/fleet-ops.git" "$fo" >>"$LOG" 2>&1 || die "fleet-ops clone failed"
  git -C "$fo" checkout -b resume/0509-intake-post-rewrite >>"$LOG" 2>&1
  git -C "$fo" -c user.name=nish3451 -c user.email=257724087+nish3451@users.noreply.github.com \
    revert --no-commit "$msha" >>"$LOG" 2>&1 || die "revert $msha failed"
  git -C "$fo" -c user.name=nish3451 -c user.email=257724087+nish3451@users.noreply.github.com \
    commit -m "resume(intake): re-enrol 0509 after main history rewrite (reverts #5384)" >>"$LOG" 2>&1
  git -C "$fo" push origin HEAD >>"$LOG" 2>&1 || die "push resume branch failed"
  url=$(gh pr create -R Nishfleet/fleet-ops --title "resume(intake): re-enrol 0509 post-rewrite" \
    --body "Reverts the fleet-ops#5384 squash ($msha). Ordered by fleet-ops#5385 step 7." \
    --head resume/0509-intake-post-rewrite)
  gh pr merge --auto --squash -R Nishfleet/fleet-ops "$url" >>"$LOG" 2>&1 || log "WARN: auto-merge arm failed"
  local crc=0
  gh issue comment "$ISSUE" -R Nishfleet/fleet-ops \
    --body "intake resume PR (auto-merge armed): $url" >>"$LOG" 2>&1 || crc=$?
  ((crc==0)) || log "ALERT rewrite0509: gh issue comment FAILED (rc=$crc) at stage8 — resume-PR notice lost ($url); check $LOG and post it manually (fleet-ops silent-drop)"
  log "stage8 ok — $url"; }

stageR(){ # rollback: force-push pre-rewrite refs back (needs $BEFORE + refs-before.txt)
  if [[ ! -f $BEFORE/HEAD || ! -f $LOGROOT/refs-before.txt ]]; then
    die "rollback needs $BEFORE and refs-before.txt"; fi
  local rs=() b old line dance=0 prheads
  prheads=$(open_pr_heads) || die "gh pr list failed"
  rs+=("refs/heads/main:refs/heads/main")
  while read -r line; do rs+=("$line"); done \
    < <(git -C "$BEFORE" for-each-ref refs/tags --format='refs/tags/%(refname:strip=2):refs/tags/%(refname:strip=2)')
  while read -r b; do
    old=$(awk -v r="refs/heads/$b" '$1==r{print $2}' "$LOGROOT/refs-before.txt")
    if [[ -n $old ]]; then rs+=("$old:refs/heads/$b"); fi
  done <<<"$prheads"
  if gh api "repos/$REPO/branches/main/protection" >"$PROT_JSON" 2>/dev/null \
     && gh api "repos/$REPO/rulesets/$RULESET" >"$RULES_JSON" 2>/dev/null; then
    protect_off; dance=1
  else log "WARN: protection state unfetchable — attempting raw push"; fi
  if ! git -C "$BEFORE" push --atomic --force "https://github.com/$REPO.git" "${rs[@]}" >>"$LOG" 2>&1; then
    if ((dance)); then protect_on || log "LOUD: restore failed"; fi
    die "rollback push failed"; fi
  if ((dance)); then protect_on || die "protection restore failed"; fi
  local rrc=0 rmain
  rmain=$(git -C "$BEFORE" rev-parse refs/heads/main)
  gh issue comment "$ISSUE" -R Nishfleet/fleet-ops \
    --body "rollback done: pre-rewrite refs force-pushed (main=$rmain)." >>"$LOG" 2>&1 || rrc=$?
  ((rrc==0)) || log "ALERT rewrite0509: gh issue comment FAILED (rc=$rrc) at stageR — rollback-done notice lost (main=$rmain); check $LOG and post it manually (fleet-ops silent-drop)"
  log "stageR ok — rolled back ${#rs[@]} refs"; }

# --- dispatch ---------------------------------------------------------------
log "rewrite-0509-author.sh dry=$DRY rollback=$ROLLBACK skip_drain=$SKIP_DRAIN max_drain=${MAX_DRAIN}m cachebust=$CACHEBUST log=$LOG"
if ((ROLLBACK)); then stageR; vd PASS; exit 0; fi
stage0; stage1; stage2; stage3; stage4; stage5; stage6; stage7
if ((DRY)); then vd PASS; exit 0; fi
stage8
vd PASS
