#!/bin/bash
#
# bfs-spkgbuild-all.sh - build every port of the scratchpkg tree.
#
# Walks the collections listed in /etc/scratchpkg.repo (or a single collection
# with -c) and runs `pkgbuild` in each port directory, so the whole tree's
# packages land in /var/cache/scratchpkg/packages.  With --install it uses
# `scratch install <port>` instead, which resolves the `# depends` headers first.
#
# Examples:
#
#     sudo scripts/bfs-spkgbuild-all.sh                     # every collection
#     sudo scripts/bfs-spkgbuild-all.sh -c core             # base collection only
#     sudo scripts/bfs-spkgbuild-all.sh --dry-run           # list what would build
#     sudo scripts/bfs-spkgbuild-all.sh --force -j 4        # rebuild, 4 at a time
#     sudo scripts/bfs-spkgbuild-all.sh --install -c core   # build and install
#
# Exit status is 0 only when every port built (or was already up to date) and 1
# when at least one port failed; failures are listed at the end.

set -uo pipefail

PROGRAM=${0##*/}
ROOT=/usr/ports
REPO_FILE=/etc/scratchpkg.repo
COLLECTION=
JOBS=1
FORCE=no
DRY_RUN=no
INSTALL=no
LOG=
FAILED=()
BUILT=0
SKIPPED=0
UPTODATE=0

usage() {
	cat <<EOF
Usage: $PROGRAM [options]

Build the scratchpkg ports tree with pkgbuild.

Options:
  -r, --root DIR         ports tree root (default: $ROOT)
  -c, --collection NAME  build only this collection (default: all in $REPO_FILE)
  -j, --jobs N           ports to build in parallel (default: 1)
  -f, --force            rebuild even when a package already exists
      --install          install each port with \`scratch install\` (resolves deps)
      --dry-run          print the work list and exit
  -l, --log FILE         append a port/status/seconds line per port to FILE
  -h, --help             this help
EOF
}

die() {
	printf '%s: %s\n' "$PROGRAM" "$1" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case $1 in
		-r|--root) [ $# -ge 2 ] || die "$1 needs an argument"; ROOT=$2; shift 2 ;;
		-c|--collection) [ $# -ge 2 ] || die "$1 needs an argument"; COLLECTION=$2; shift 2 ;;
		-j|--jobs) [ $# -ge 2 ] || die "$1 needs an argument"; JOBS=$2; shift 2 ;;
		-f|--force) FORCE=yes; shift ;;
		--install) INSTALL=yes; shift ;;
		--dry-run) DRY_RUN=yes; shift ;;
		-l|--log) [ $# -ge 2 ] || die "$1 needs an argument"; LOG=$2; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1 (try --help)" ;;
	esac
done

case $JOBS in
	''|*[!0-9]*) die "invalid job count: $JOBS" ;;
esac

[ -d "$ROOT" ] || die "ports root not found: $ROOT"
if [ "$DRY_RUN" != yes ]; then
	command -v pkgbuild >/dev/null 2>&1 || die "pkgbuild not found; install the scratchpkg port first"
fi

collections() {
	if [ -n "$COLLECTION" ]; then
		printf '%s\n' "$COLLECTION"
		return 0
	fi
	if [ -r "$REPO_FILE" ]; then
		grep -Ev '^[[:space:]]*(#|$)' "$REPO_FILE" | awk '{print $1}' |
			while read -r repo_dir; do
				[ -d "$repo_dir" ] || continue
				basename "$repo_dir"
			done
		return 0
	fi
	# No repo file: fall back to the directories that exist under the root.
	find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

work_list() {
	for collection in $(collections); do
		[ -d "$ROOT/$collection" ] || continue
		for port_dir in "$ROOT/$collection"/*/; do
			[ -f "$port_dir/.spkgbuild" ] || continue
			printf '%s\n' "${port_dir%/}"
		done
	done
}

# Build one port, writing a status line so parallel output stays readable.
build_port() {
	local port_dir=$1
	local name=${port_dir##*/}
	local start end status logfile

	logfile=$(mktemp)
	start=$(date +%s)
	(
		cd "$port_dir" || exit 1
		if [ "$INSTALL" = yes ]; then
			scratch install "$name"
		elif [ "$FORCE" = yes ]; then
			pkgbuild -q -f
		else
			pkgbuild -q
		fi
	) >"$logfile" 2>&1
	status=$?
	end=$(date +%s)

	if grep -q 'Package is up-to-date' "$logfile" 2>/dev/null; then
		printf 'up-to-date %s\n' "$name"
	elif [ "$status" -eq 0 ]; then
		printf 'built      %s (%ss)\n' "$name" "$((end - start))"
	else
		printf 'FAILED     %s (%ss)\n' "$name" "$((end - start))"
		sed 's/^/    /' "$logfile" | tail -n 20
	fi
	rm -f "$logfile"
	return "$status"
}

if [ "$DRY_RUN" = yes ]; then
	printf '%s: would build these ports:\n' "$PROGRAM"
	work_list | sed 's|^|  |'
	exit 0
fi

[ -n "$LOG" ] && : >"$LOG"

total=$(work_list | wc -l)
printf '%s: building %s ports from %s (jobs=%s, install=%s)\n' \
	"$PROGRAM" "$total" "$ROOT" "$JOBS" "$INSTALL"

# pkgbuild takes a per-package lock, so parallel runs are safe as long as the
# same port is not started twice, which cannot happen here.
if [ "$JOBS" -gt 1 ]; then
	results=$(work_list | xargs -r -n1 -P"$JOBS" bash -c 'build_port "$@"' _ 2>&1)
else
	results=$(work_list | while read -r port_dir; do build_port "$port_dir"; done 2>&1)
fi
printf '%s\n' "$results"

BUILT=$(printf '%s\n' "$results" | grep -c '^built ' || true)
UPTODATE=$(printf '%s\n' "$results" | grep -c '^up-to-date ' || true)
while IFS= read -r line; do
	[ -n "$line" ] && FAILED+=("${line#FAILED     }")
done < <(printf '%s\n' "$results" | grep '^FAILED' || true)
SKIPPED=$((total - BUILT - UPTODATE - ${#FAILED[@]}))

printf '\n%s: %s built, %s already up to date, %s failed, %s not built\n' \
	"$PROGRAM" "$BUILT" "$UPTODATE" "${#FAILED[@]}" "$SKIPPED"
if [ "${#FAILED[@]}" -gt 0 ]; then
	printf '%s: failures:\n' "$PROGRAM"
	for entry in "${FAILED[@]}"; do
		printf '  %s\n' "$entry"
	done
	exit 1
fi
printf '%s: packages are in %s\n' "$PROGRAM" "${PACKAGE_DIR:-/var/cache/scratchpkg/packages}"
exit 0
