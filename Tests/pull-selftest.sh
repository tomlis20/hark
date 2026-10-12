#!/usr/bin/env bash
# Find the newest Hark SavedVariables file across every Forever install and run the reader on it.
#   Tests/pull-selftest.sh            report
#   Tests/pull-selftest.sh --raw      print the file path only
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
newest=""
while IFS= read -r f; do
	if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
done < <(find /mnt/content/Games "$HOME/Games" -maxdepth 12 -type f -path "*_classic_beta_/WTF/Account/*/SavedVariables/Hark.lua" 2>/dev/null)
if [ -z "$newest" ]; then
	echo "No Hark.lua SavedVariables file found. In game: /hark selftest, then /reload." >&2
	exit 1
fi
if [ "${1:-}" = "--raw" ]; then echo "$newest"; exit 0; fi
echo "file: $newest"
echo "written: $(date -r "$newest" '+%Y-%m-%d %H:%M:%S')"
echo
lua=lua5.1; command -v "$lua" >/dev/null || lua=luajit
exec "$lua" "$HERE/readselftest.lua" "$newest"
