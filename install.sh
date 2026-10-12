#!/usr/bin/env bash
# Hark installer.
#
# Links this repository into every WoW Forever (_classic_beta_) AddOns folder
# found on this machine, so that editing the source here is immediately live
# in game after a /reload.
#
#   ./install.sh           link into every Forever install found
#   ./install.sh --copy    copy instead of linking (use if Wine ignores links)
#   ./install.sh --force   replace an existing real Hark directory
#   ./install.sh --status  show what is currently installed, change nothing
#
# A real (non-symlink) Hark directory is never replaced without --force.

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_NAME="Hark"

MODE="link"
FORCE=0
STATUS_ONLY=0

for arg in "$@"; do
	case "$arg" in
		--copy)   MODE="copy" ;;
		--force)  FORCE=1 ;;
		--status) STATUS_ONLY=1 ;;
		-h|--help)
			sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "unknown option: $arg" >&2
			exit 2
			;;
	esac
done

# Search roots. Add more here if the game lives somewhere else.
SEARCH_ROOTS=(
	"/mnt/content/Games"
	"$HOME/Games"
	"$HOME/.wine/drive_c/Program Files (x86)"
)

echo "source: $SRC"
echo

mapfile -t TARGETS < <(
	for root in "${SEARCH_ROOTS[@]}"; do
		[ -d "$root" ] || continue
		find "$root" -maxdepth 8 -type d -path "*_classic_beta_/Interface/AddOns" 2>/dev/null
	done | sort -u
)

if [ "${#TARGETS[@]}" -eq 0 ]; then
	echo "No WoW Forever (_classic_beta_) AddOns folder found." >&2
	echo "Edit SEARCH_ROOTS in this script to point at your install." >&2
	exit 1
fi

# Collapse targets that are the same directory reached by different paths.
declare -A SEEN
UNIQUE=()
for t in "${TARGETS[@]}"; do
	key="$(stat -c '%d:%i' "$t" 2>/dev/null || echo "$t")"
	if [ -z "${SEEN[$key]+x}" ]; then
		SEEN[$key]=1
		UNIQUE+=("$t")
	else
		echo "skip (same directory as one already listed): $t"
	fi
done

installed=0
skipped=0

for addons in "${UNIQUE[@]}"; do
	dest="$addons/$ADDON_NAME"
	echo "target: $dest"

	if [ "$STATUS_ONLY" -eq 1 ]; then
		if [ -L "$dest" ]; then
			echo "  linked -> $(readlink "$dest")"
		elif [ -d "$dest" ]; then
			echo "  real directory ($(find "$dest" -maxdepth 1 -name '*.lua' | wc -l) lua files)"
		else
			echo "  not installed"
		fi
		continue
	fi

	if [ -L "$dest" ]; then
		echo "  replacing existing link -> $(readlink "$dest")"
		rm "$dest"
	elif [ -d "$dest" ]; then
		if [ "$FORCE" -eq 1 ]; then
			echo "  replacing existing directory (--force)"
			rm -rf "$dest"
		else
			echo "  SKIPPED: a real directory is already there. Re-run with --force to replace it."
			skipped=$((skipped + 1))
			continue
		fi
	fi

	if [ "$MODE" = "copy" ]; then
		mkdir -p "$dest"
		# Ship only what the game needs.
		cp -r "$SRC"/*.lua "$SRC"/*.toc "$dest"/ 2>/dev/null
		[ -d "$SRC/Media" ] && cp -r "$SRC/Media" "$dest"/
		[ -d "$SRC/Locales" ] && cp -r "$SRC/Locales" "$dest"/
		echo "  copied"
	else
		ln -s "$SRC" "$dest"
		echo "  linked"
	fi
	installed=$((installed + 1))
done

if [ "$STATUS_ONLY" -eq 1 ]; then
	exit 0
fi

echo
echo "installed into $installed location(s); $skipped skipped."
if [ "$MODE" = "link" ] && [ "$installed" -gt 0 ]; then
	echo "Edits to the source are live. Type /reload in game to pick them up."
	echo "If the game does not see the addon, re-run with --copy (some Wine setups ignore links)."
fi
