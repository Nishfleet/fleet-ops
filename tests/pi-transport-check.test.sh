#!/usr/bin/env bash
# Regression test for bin/pi-transport-check size floor (fleet-ops#6209).
# pi 0.85.1 ships a slim 169-byte ESM cli.js loader; the old 300-byte floor
# (calibrated to the ~710-byte pre-0.85 loader) made the probe false-positive
# and looped pi-transport-self-heal into reinstalling pi under live workers.
# The floor must reject the 76-byte incident stub but accept the slim loader.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$REPO_ROOT/bin/pi-transport-check"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Fake pi bin: prints a bare semver for --version.
cat > "$TMP/pi" <<'EOF'
#!/usr/bin/env bash
echo 0.85.1
EOF
chmod +x "$TMP/pi"

mk_cli() { # $1=path $2=target byte size
  local path="$1" size="$2"
  printf '#!/usr/bin/env node\n' > "$path"
  # Pad with a comment line to the exact target size (shebang line is 20
  # bytes; the padding line adds '#' + (pad-1) filler + '\n' = pad+1 bytes).
  local pad=$(( size - 21 ))
  if (( pad > 0 )); then
    printf '#'; head -c "$(( pad - 1 ))" < /dev/zero | tr '\0' 'x'; printf '\n'
  fi >> "$path"
  chmod +x "$path"
  local actual
  actual="$(stat -c %s "$path")"
  [[ "$actual" == "$size" ]] || fail "fixture size $actual != $size"
}

# 1. Slim 169-byte loader (pi 0.85.1 shape) must PASS.
mk_cli "$TMP/cli-slim.js" 169
out="$(bash "$CHECK" "$TMP/cli-slim.js" "$TMP/pi" 2>&1)" || fail "169-byte slim loader rejected: $out"
[[ "$out" == PI-TRANSPORT-OK* ]] || fail "expected PI-TRANSPORT-OK, got: $out"

# 2. The 76-byte incident stub must still FAIL.
mk_cli "$TMP/cli-stub.js" 76
if out="$(bash "$CHECK" "$TMP/cli-stub.js" "$TMP/pi" 2>&1)"; then
  fail "76-byte incident stub accepted"
fi
[[ "$out" == *"PI-TRANSPORT-CORRUPT"* ]] || fail "stub failure missing CORRUPT marker: $out"

# 3. A 119-byte file (below floor) must FAIL; floor sits between stub and slim.
mk_cli "$TMP/cli-119.js" 119
if out="$(bash "$CHECK" "$TMP/cli-119.js" "$TMP/pi" 2>&1)"; then
  fail "119-byte file accepted"
fi

# 4. Missing file must FAIL.
if out="$(bash "$CHECK" "$TMP/does-not-exist.js" "$TMP/pi" 2>&1)"; then
  fail "missing cli.js accepted"
fi

echo "PASS: pi-transport-check size floor accepts 169-byte slim loader, rejects 76/119-byte stubs"
