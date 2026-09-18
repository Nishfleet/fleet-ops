#!/usr/bin/env bash
# tests/no-dead-credential-paths.test.sh
#
# fleet-ops#7664 — ONE seat-credential root. /home/nish/fleet2/etc was deleted
# with the control plane (2026-08-23); on 2026-09-18 22 Pi providers and both
# provider extensions still hardcoded it, so every direct Pi provider on the
# VPS resolved NO key ("No API key found for devin") and the seats ledger parked
# them as corpses. Nish: "no glue or scotch tape fixes" — this gate keeps the
# class out for good.
#
#   1. no tracked non-archive file references the dead path
#   2. every `!cmd` apiKey in config/pi-models.json names an absolute path or
#      helper that EXISTS on the host (seats root, a ~/.config/<x> env, or a
#      ~/.local/bin key helper) and is non-empty, never fleet2, and keeps '=' inside values
#      (cut -f2-). CI without the host dirs: existence check SKIPs.
#   3. both provider extensions import ./seat-env (env + models) and MANIFEST
#      installs the helper beside each of them
#   4. the pi-models check is proven RED on a fixture that still names fleet2

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1
if hits="$(git -C "$repo" grep -n -E '/fleet2/etc|~/fleet2' -- ':!*.md' ':!archive/*' ':!.fleet/*' ":!tests/$(basename "$0")")"; then
  fail "dead credential path still referenced:"$'\n'"$hits"
fi

# 2 (reusable check; $2 = seats dir or empty to skip existence)
check_models() {
  python3 - "$1" "${2:-}" <<'PY'
import json, os, re, sys
path, on_host = sys.argv[1], sys.argv[2] == "host"
d = json.load(open(path)); bad = []
for name, prov in d.get("providers", {}).items():
    k = str(prov.get("apiKey", ""))
    if not k.startswith("!"): continue
    if re.search(r"/fleet2/etc|~/fleet2", k): bad.append(f"{name}: dead credential path: {k}"); continue
    if "cut -d= -f2 " in k: bad.append(f"{name}: use 'cut -d= -f2-' so '=' inside a key survives"); continue
    paths = re.findall(r"(/home/nish/[^\s'\"]+)", k)
    if not paths: bad.append(f"{name}: key command names no absolute path or helper: {k}"); continue
    if on_host:
        for q in paths:
            if not os.path.exists(q): bad.append(f"{name}: {q} does not exist on this host (points nowhere)"); continue
            if q.endswith(".env") and not re.search(r"^(export\s+)?[A-Za-z_][A-Za-z0-9_]*=\S", open(q).read(), flags=re.M):
                bad.append(f"{name}: {q} is empty / has no KEY=value line (a keyless seat is a lie — place the key or delete the provider)")
if bad: print("\n".join(bad)); sys.exit(1)
PY
}
seats_dir="${FLEET_SEATS_DIR:-/home/nish/.config/fleet-ops/seats}"
if [[ -d "$seats_dir" ]]; then
  check_models "$repo/config/pi-models.json" host || fail "config/pi-models.json key references"
else
  check_models "$repo/config/pi-models.json" "" || fail "config/pi-models.json key references"
  echo "SKIP: $seats_dir absent — on-host existence check not run here"
fi

# 3
for e in devin-provider cursor-provider; do
  f="$repo/template/extensions/$e/index.ts"
  grep -q 'from "./seat-env"' "$f" || fail "$e does not import ./seat-env"
  grep -q 'loadSeatEnv(' "$f" || fail "$e does not call loadSeatEnv"
  grep -q 'modelsFromModelsJson(' "$f" || fail "$e still carries its own models array"
  grep -qE "^template/extensions/seat-env\.ts /home/nish/\.pi/agent/extensions/$e/seat-env\.ts$" "$repo/MANIFEST" || fail "MANIFEST does not install seat-env.ts beside $e"
done

# 4 prove red
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
printf '{"providers":{"x":{"apiKey":"!cut -d= -f2 /home/nish/fleet2/etc/x.env"}}}\n' > "$tmp"
if check_models "$tmp" "" >/dev/null 2>&1; then fail "fixture with fleet2 path passed — gate is blind"; fi

echo "PASS: one seat-credential root; no dead paths; extensions + MANIFEST wired; gate proven red"
