#!/usr/bin/env bash
# tests/install-prometheus-rules-reload.test.sh
#
# fleet-ops#1307: install.sh --system copies config/fleet_rules.yml to
# /etc/prometheus/fleet_rules.yml but only daemon-reloads systemd.
# Prometheus loads that file via rule_files and re-reads it only on
# `systemctl reload prometheus` (ExecReload is kill -HUP), so a merged
# alert rule sat on disk until the next restart (ConsoleLying #1157,
# FleetGhCacheStale #1232). This test locks the fix:
#   A. a changed fleet_rules.yml triggers `sudo systemctl reload
#      prometheus` and every group in the installed file is proven present
#      in GET /api/v1/rules (install exits 0).
#   B. a byte-identical file skips the reload entirely (no HUP wasted).
#   C. a group that fails to load makes install.sh --system exit rc=1 with
#      a loud "rules proof failed" line — fail-closed, so a parse error
#      cannot silently drop a new alert group.
#
# The whole --system path is stubbed: a fake `sudo` on PATH absorbs the
# -n true / install / systemctl calls and redirects /etc/... destinations
# into a scratch tree, and PM_RULES_URL points the proof at a file:// stub
# of the rules API. No real /etc file, no real prometheus reload, no real
# sudo is ever exercised.
#
# Nested from tests/rule-enforcement.test.sh so CI covers it without a
# workflow edit this token cannot push.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
install_src="$repo_root/install.sh"
rules_src="$repo_root/config/fleet_rules.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$install_src" ]] || fail "not executable: $install_src"
[[ -f "$rules_src" ]] || fail "missing $rules_src"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

# --- 1. Static locks ---------------------------------------------------------
grep -q 'system_rules_changed' "$install_src" \
  || fail "install.sh must track whether fleet_rules.yml bytes changed before install"
grep -q 'reload prometheus' "$install_src" \
  || fail "install.sh must reload prometheus after a fleet_rules.yml change"
grep -q 'is-active --quiet prometheus' "$install_src" \
  || fail "install.sh must guard the reload on prometheus being active"
grep -q 'prove_rules_loaded' "$install_src" \
  || fail "install.sh must prove loaded groups against the rules API"
grep -q 'fleet-ops#1307' "$install_src" \
  || fail "install.sh must name fleet-ops#1307"
ok "install.sh carries the prometheus reload + rules-proof seam (fleet-ops#1307)"

# --- scratch environment ------------------------------------------------------
scratch="$(mktemp -d -t install-prom-rules.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

install="$scratch/install.sh"
cp -a "$install_src" "$install"
chmod +x "$install"
mkdir -p "$scratch/config" "$scratch/bin"
cp -a "$rules_src" "$scratch/config/fleet_rules.yml"

# System-scope MANIFEST entry: dest under /etc routes through --system.
# The fake sudo redirects the write into the scratch tree, so the real
# /etc/prometheus is never touched.
dest="/etc/prometheus/fleet-ops-1307-test/fleet_rules.yml"
cat >"$scratch/MANIFEST" <<MANIFEST
config/fleet_rules.yml $dest
MANIFEST

# Live path where the fake sudo actually lands the installed copy.
live_rules="$scratch/redir${dest}"

# Rules-API stub: the repo rules file's group names, all loaded.
rules_api="$scratch/rules-api.json"
mkdir -p "$scratch/redir"
python3 - "$rules_src" > "$rules_api" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
groups = sorted(set(g.strip(chr(34) + chr(39)) for g in re.findall(r"(?m)^\s*-\s*name:\s*(\S+)", text)))
print(json.dumps({"status": "success", "data": {"groups": [{"name": g, "rules": []} for g in groups]}}))
PY

# Fake sudo: absorbs `-n true`, `install`, and `systemctl` calls; redirects
# /etc/... install destinations into the scratch tree; logs every call so
# the test can assert reload fired (or did not).
sudo_log="$scratch/sudo.log"
: >"$sudo_log"
cat >"$scratch/bin/sudo" <<EOF
#!/usr/bin/env bash
log="$sudo_log"
redir="$scratch/redir"
echo "\$*" >> "\$log"
case "\$1" in
  -n) exit 0 ;;
  install)
    src="\${@: -2:1}"
    d="\${@: -1:1}"
    d="\$redir/\${d#/}"
    mkdir -p "\$(dirname "\$d")"
    cp "\$src" "\$d"
    exit 0
    ;;
  systemctl)
    exit 0   # is-active -> active, reload -> ok
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$scratch/bin/sudo"
export FLEET_OPS_ALLOW_NONCANONICAL=1

run_install() {
    # env-style caller: run_install KEY=VALUE... passes each through "$@"
    # untouched (assignments cannot survive word-splitting of a string).
    set +e
    out=$(env PATH="$scratch/bin:$PATH" "$@" "$install" --system 2>&1)
    rc=$?
    set -e
    printf '%s' "$out"
    return "$rc"
}

# --- Scenario A: changed file -> reload fires, proof passes ----------------
# First install: the live path is missing, so bytes differ -> must reload.
set +e
out_a=$(run_install PM_RULES_FILE="$live_rules" PM_RULES_URL="file://$rules_api")
rc_a=$?
set -e
[[ "$rc_a" -eq 0 ]] || fail "scenario A: changed fleet_rules.yml must exit 0, rc=$rc_a (out: $out_a)"
grep -q 'systemctl reload prometheus' "$sudo_log" \
  || fail "scenario A: reload did not fire for a changed fleet_rules.yml (log: $(cat "$sudo_log"))"
grep -q 'rules-proof:.*group(s) loaded' <<<"$out_a" \
  || fail "scenario A: proof did not report loaded groups (out: $out_a)"
[[ -f "$live_rules" ]] && cmp -s "$live_rules" "$rules_src" \
  || fail "scenario A: installed copy missing or not byte-equal to repo rules"
ok "scenario A: changed fleet_rules.yml reloads prometheus and the proof passes"

# --- Scenario B: byte-identical file -> NO reload ---------------------------
# Reset the live file to a byte-identical copy of the repo rules.
mkdir -p "$(dirname "$live_rules")"
cp -a "$rules_src" "$live_rules"
: >"$sudo_log"
set +e
out_b=$(run_install PM_RULES_FILE="$live_rules" PM_RULES_URL="file://$rules_api")
rc_b=$?
set -e
[[ "$rc_b" -eq 0 ]] || fail "scenario B: identical fleet_rules.yml must exit 0, rc=$rc_b (out: $out_b)"
if grep -q 'systemctl reload prometheus' "$sudo_log"; then
  fail "scenario B: reload fired although fleet_rules.yml bytes did not change (log: $(cat "$sudo_log"))"
fi
ok "scenario B: byte-identical fleet_rules.yml skips the prometheus reload"

# --- Scenario C: a group fails to load -> install exits rc=1 loudly --------
# Parse-error shape: the live file differs from repo (so reload fires), but
# the API stub is missing one of the groups the installed file defines —
# Prometheus keeps serving the old rules and that group never loads.
cp -a "$rules_src" "$live_rules"
printf '\n# bytes differ so the reload fires\n' >> "$live_rules"
rules_api_missing="$scratch/rules-api-missing.json"
python3 - "$rules_src" > "$rules_api_missing" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
groups = sorted(set(g.strip(chr(34) + chr(39)) for g in re.findall(r"(?m)^\s*-\s*name:\s*(\S+)", text)))
missing = groups[1:] if len(groups) > 1 else []
print(json.dumps({"status": "success", "data": {"groups": [{"name": g, "rules": []} for g in missing]}}))
PY
: >"$sudo_log"
set +e
out_c=$(run_install PM_RULES_FILE="$live_rules" PM_RULES_URL="file://$rules_api_missing")
rc_c=$?
set -e
[[ "$rc_c" -eq 1 ]] || fail "scenario C: unloaded group must fail install (rc=1), got rc=$rc_c (out: $out_c)"
grep -q 'rules proof failed' <<<"$out_c" \
  || fail "scenario C: install.sh must print the loud rules-proof failure (out: $out_c)"
grep -q 'systemctl reload prometheus' "$sudo_log" \
  || fail "scenario C: reload must have fired before the proof (log: $(cat "$sudo_log"))"
ok "scenario C: an unloaded group fails install.sh --system loudly"

echo "OK: install.sh --system reloads prometheus and proves fleet_rules.yml groups (fleet-ops#1307)"