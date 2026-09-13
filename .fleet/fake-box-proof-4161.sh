#!/usr/bin/env bash
# Isolated proof of install.sh remove_retired_drain_timers (fleet-ops#4161):
# stop+disable+rm on a FAKE box, covering real files AND dangling symlinks
# (the fleet-ops#4199 regression), wants-links included, plus the idempotent
# no-op second pass. The LIVE units are never touched.
set -u
BOX=/tmp/fake-box-4161
rm -rf "$BOX"
mkdir -p "$BOX/.config/systemd/user/timers.target.wants" "$BOX/units"
UC="~/.config/systemd/user"; U="$BOX/.config/systemd/user"

# unit fragments (the deploy-clone targets)
for f in fleet-merged-pr-close.service fleet-merged-pr-close.timer \
         fleet-issue-close-duplicates.service fleet-issue-close-duplicates.timer; do
  printf '[Unit]\nDescription=fake %s\n' "$f" > "$BOX/units/$f"
done

# four permutations of what a live box can carry:
#   1. real unit FILE          (fresh-copy box)
#   2. symlink -> existing     (this box: ~/.config symlinks the deploy clone)
#   3. DANGLING symlink        (fleet-ops#4199: target already pulled away)
#   4. absent                  (fresh box: the loop must no-op)
ln -s "$BOX/units/fleet-merged-pr-close.service"     "$U/fleet-merged-pr-close.service"
printf 'real\n' > "$U/fleet-merged-pr-close.timer"
ln -s "$BOX/units/fleet-issue-close-duplicates.service" "$U/fleet-issue-close-duplicates.service"
ln -s "$BOX/units/GONE-4199.timer"                   "$U/fleet-issue-close-duplicates.timer"
# wants: one dangling, one real-targeted (both must go)
ln -s "$BOX/units/GONE-4199.timer"                   "$U/timers.target.wants/fleet-merged-pr-close.timer"
ln -s "$BOX/units/fleet-merged-pr-close.timer"       "$U/timers.target.wants/fleet-issue-close-duplicates.timer"

# stub systemctl: records every invocation, succeeds
cat > "$BOX/stub-systemctl" <<'EOF'
#!/usr/bin/env bash
echo "STUB: $*" >> /tmp/fake-box-4161/stub.log
exit 0
EOF
chmod +x "$BOX/stub-systemctl"

# extract the function from the REAL install.sh (no copy drift)
sed -n '/^remove_retired_drain_timers() {/,/^}/p' install.sh > "$BOX/fn.sh"
grep -q "remove_retired_drain_timers() {" "$BOX/fn.sh" || { echo "FAIL: function not extracted"; exit 2; }

bash -c '
  HOME=/tmp/fake-box-4161
  SYSTEMCTL=/tmp/fake-box-4161/stub-systemctl
  user_unit_changed=0
  source /tmp/fake-box-4161/fn.sh
  remove_retired_drain_timers
  echo "USER_UNIT_CHANGED=$user_unit_changed"
' || { echo "FAIL: function exited nonzero"; exit 1; }

echo "=== stub calls:"; sort "$BOX/stub.log"
echo "=== residue check (must list NOTHING):"
find "$U" -name "fleet-*" -o -name "*4199*" | grep -v timers.target.wants/$ || true
ls "$U" 2>/dev/null
LEFT=$(find "$U" \( -name "fleet-merged-pr-close.*" -o -name "fleet-issue-close-duplicates.*" \) | wc -l)
[ "$LEFT" = 0 ] || { echo "FAIL: $LEFT unit/wants paths survived"; exit 1; }

echo "=== second pass (idempotent no-op):"
rm -f "$BOX/stub.log"
out=$(bash -c 'HOME=/tmp/fake-box-4161; SYSTEMCTL=/tmp/fake-box-4161/stub-systemctl; user_unit_changed=0; source /tmp/fake-box-4161/fn.sh; remove_retired_drain_timers; echo "UC2=$user_unit_changed"')
echo "$out"
echo "$out" | grep -q "UC2=0" || { echo "FAIL: second pass should not flip user_unit_changed"; exit 1; }
[ -s "$BOX/stub.log" ] && { echo "FAIL: second pass should not call systemctl"; exit 1; }

# receipts survive the #4149 .bak/retired sweep (fleet-ops#5663 record)
printf 'receipt\n' > "$U/fleet-merged-pr-close.timer.pre-issue-4161-20260913T202400Z"
rm -f "${U}"/*.bak* "${U}"/*.retired*
[ -f "$U/fleet-merged-pr-close.timer.pre-issue-4161-20260913T202400Z" ] || { echo "FAIL: receipt would be swept"; exit 1; }

echo "FAKE-BOX-PROOF-OK"
