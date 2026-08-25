#!/usr/bin/env bash
# hand-written because no platform feature installs from an explicit manifest; GNU stow rejected: directory-sweep semantics conflict with the allowlist requirement.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; rc=0
while read -r src dest; do
  [ -z "$src" ] && continue
  # Skip comment lines (# P14 tests ...) and empty lines.
  [[ "$src" == \#* ]] && continue
  repo=$(readlink -f "$here/$src")
  if [ "${1:-}" = "--check" ]; then
    link=$(readlink -f "$dest" 2>/dev/null || true)
    [ "$link" = "$repo" ] && cmp -s "$dest" "$repo" 2>/dev/null && continue
    echo "DIFF: $dest -> ${link:-<missing>} (want $repo)"; rc=1
  else ln -sfn "$repo" "$dest"; fi
done < "$here/MANIFEST"
[ "${1:-}" = "--check" ] || systemctl --user daemon-reload
exit "$rc"
