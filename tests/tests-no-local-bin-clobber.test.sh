#!/usr/bin/env bash
# tests/tests-no-local-bin-clobber.test.sh
#
# fleet-ops#3111: a test must NEVER install/cp/ln/mv/tee/redirect a file into
# the real ~/.local/bin (or ~/.local/lib/node_modules, ~/.pi). The 2026-09-03
# incident was a worker stubbing binaries for a test via
#   sudo install -D -m 0755 /dev/null /home/nish/.local/bin/pi
# which clobbered the pi symlink and starved the fleet for 33h. Tests that
# need a fake bin override HOME to a scratch dir and write there — that is the
# safe pattern and this lint allows it.
#
# This lint scans every file under tests/ for shell commands that write into
# the LITERAL real path (/home/nish/.local/bin, /home/nish/.local/lib/
# node_modules, /home/nish/.pi) and rejects them outright. It ALSO rejects
# $HOME/.local/bin writes in files that do NOT override HOME to a scratch/tmp
# dir (a test writing to $HOME without overriding it IS the clobber).
#
# Quoted-string fixtures (the spawn-guard sudo-write test's JS arrays) are
# skipped: lines whose first non-whitespace char is a quote or `#` are not
# commands. The spawn-guard test's block-matrix lines start with `'` and are
# test data, not executed commands.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Real, literal transport paths — a write here is ALWAYS a clobber attempt.
# Anchored to a path-start boundary (whitespace, quote, =, :, or start of
# line) so `$scratch/home/nish/.local/bin` (a scratch subdir that merely
# CONTAINS the real path as a substring) does NOT match — only the literal
# real path does.
real_paths_re='(^|[[:space:]"'\'':=])/home/nish/\.local/bin|(^|[[:space:]"'\'':=])/home/nish/\.local/lib/node_modules|(^|[[:space:]"'\'':=])/home/nish/\.pi([^/a-zA-Z]|$)'

# Commands that write a file. Anchored so we match the command position
# (start of line, or after ; & | ` && ||), not a word inside a path. Allows
# an optional `sudo` / `command` / `env` prefix (the 2026-09-03 clobber was
# `sudo install ...`).
write_cmd_re='(^|[;|&`][[:space:]]+)(sudo[[:space:]]+)?(install|cp|ln|mv|tee|dd|cat)\b'

violations=()
while IFS= read -r -d '' f; do
	[[ "$f" == *".test.sh" ]] || continue
	# Does this file override HOME to a scratch/tmp dir? If so, $HOME writes
	# are safe (they land in scratch). We still check the LITERAL real path.
	local_home_overridden=0
	if grep -qE '(^|[[:space:]])export[[:space:]]+HOME="[^\$]*/(tmp|scratch|mktemp)|HOME="[^\$]*\$\{?(scratch|tmp|TMPDIR)' "$f" 2>/dev/null; then
		local_home_overridden=1
	fi
	while IFS=: read -r lineno line; do
		# Trim leading whitespace; skip comments and quoted-string fixtures.
		trimmed="${line#"${line%%[![:space:]]*}"}"
		[[ -z "$trimmed" ]] && continue
		[[ "$trimmed" == \#* ]] && continue
		[[ "$trimmed" == \'* ]] && continue   # JS string-literal fixture
		[[ "$trimmed" == \"* ]] && continue    # double-quoted fixture
		# 1. LITERAL real path — always a violation.
		if [[ "$line" =~ $real_paths_re ]]; then
			if [[ "$line" =~ $write_cmd_re ]]; then
				violations+=("$f:$lineno: writes into real transport path: $line")
				continue
			fi
			# Redirect into the real path: `> /home/nish/.local/bin/x` or
			# `>"/home/nish/.local/bin/x`. Does NOT match `>"$stub/home/nish/...`
			# (the path starts with `$stub`, not the literal `/home/nish`).
			if printf '%s' "$line" | grep -qE '>>?[[:space:]]*"?(/home/nish/\.local/bin|/home/nish/\.local/lib/node_modules|/home/nish/\.pi)([^/]|$)'; then
				violations+=("$f:$lineno: redirects into real transport path: $line")
				continue
			fi
		fi
		# 2. $HOME/.local/bin write in a file that does NOT override HOME.
		if (( ! local_home_overridden )); then
			if [[ "$line" =~ \$\{?HOME\}?[[:space:]]*/[[:space:]]*\.local/bin ]]; then
				if [[ "$line" =~ $write_cmd_re ]]; then
					violations+=("$f:$lineno: writes into \$HOME/.local/bin without overriding HOME to scratch: $line")
					continue
				fi
				if printf '%s' "$line" | grep -qE '>>?[[:space:]]*[^[:space:]]*\$\{?HOME\}?[[:space:]]*/[[:space:]]*\.local/bin'; then
					violations+=("$f:$lineno: redirects into \$HOME/.local/bin without overriding HOME to scratch: $line")
				fi
			fi
		fi
	done < <(grep -n '' "$f" 2>/dev/null || true)
done < <(find "$repo_root/tests" -maxdepth 1 -type f -print0 2>/dev/null)

if (( ${#violations[@]} > 0 )); then
	printf '%s\n' "${violations[@]}" >&2
	fail "${#violations[@]} test(s) write into the real transport path — use a scratch HOME override (see tests/fleet-ops-deploy.test.sh for the safe pattern)"
fi
ok "no test writes into the real ~/.local/bin / ~/.local/lib/node_modules / ~/.pi"
