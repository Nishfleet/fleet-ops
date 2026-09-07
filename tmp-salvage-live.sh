#!/usr/bin/env bash
# reproduce live SIGTERM drill properly (origin remote set)
set -uo pipefail
scratch="$(mktemp -d)"
echo "scratch=$scratch"
name=live
git init -q --bare "$scratch/$name.git"
git init -q "$scratch/$name"
(
  cd "$scratch/$name"
  git config user.name test; git config user.email t@t
  git remote add origin "$scratch/$name.git"
  git commit -q --allow-empty -m init
  git push -q origin HEAD:main
  git checkout -q -B main origin/main
)
printf 'uncommitted engine\n' >"$scratch/$name/engine.txt"
git -C "$scratch/$name" remote -v
pkt="$scratch/live-packet.md"
printf 'live packet\n' >"$pkt"
unit="salvage-live-ptest"
export PI_SALVAGE_NOW="20260827T161000Z"
./bin/pi-systemd-run --unit "$unit" --working-directory "$scratch/$name" --stdin "$pkt" -- /bin/sleep 25
sleep 0.5
systemctl --user show "$unit.service" --property=ExecStopPost,ExecStartPost,OnFailure
state="$(systemctl --user is-active "$unit.service" 2>/dev/null || true)"
echo "state before stop: $state"
systemctl --user stop "$unit.service" >/dev/null 2>&1 || true
echo "--- refs on live.git:"
git -C "$scratch/$name.git" show-ref || true
echo "--- stop-related journal:"
journalctl --user -u "$unit.service" --no-pager 2>/dev/null | tail -12
systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true
rm -rf "$scratch"