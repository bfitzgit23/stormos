#!/bin/bash
#
# bfs-mkstage3.sh - pack a BFSOS root filesystem into a stage3 tar archive.
#
# A "stage3" is the plain contents of a working BFSOS root filesystem
# (/usr, /etc, /var, /boot, ...) packed into one compressed archive that can
# be extracted onto a fresh partition to get the same system without
# rebuilding every package.  The default output is zstd-compressed:
#
#     bfs-stage3-<version>-<YYYYmmdd>-<arch>.tar.zst
#
# (The bootstrap's own stage 5 archive is bfs-rootfs-<version>-<date>.tar.zst;
# this tool emits the same kind of archive on demand, with the date and host
# architecture in the name so several stage3 builds can coexist.)
#
# Typical use (pack the running system):
#
#     sudo scripts/bfs-mkstage3.sh -o /var/tmp/bfs-stage3.tar.zst
#
# Pack an alternative root (an installed target mounted at /mnt/stormfs, or a
# rootfs built by bootstrap.sh / the ports tree):
#
#     sudo scripts/bfs-mkstage3.sh -r /mnt/stormfs -o bfs-stage3.tar.zst
#
# Restore it:
#
#     sudo tar --numeric-owner -xpf bfs-stage3.tar.zst -C /mnt/stormfs
#
# The script never modifies the source root: it only reads it, and it always
# excludes the pseudo-filesystems and caches that must not be captured.

set -euo pipefail

PROGRAM=${0##*/}

ROOT=/
OUTPUT=
LEVEL=
LEVEL_GIVEN=no
THREADS=
COMPRESSOR=
EXCLUDES=()
DRY_RUN=no
NUMERIC_OWNER=yes
VERIFY=yes

usage() {
	cat <<EOF
Usage: $PROGRAM [options]

Pack a BFSOS root filesystem into a stage3 archive (default: zstd).

Options:
  -r, --root DIR         root filesystem to archive (default: /)
  -o, --output FILE      output archive path
                         (default: bfs-stage3-<version>-<today>-<arch>.tar.zst)
  -C, --compressor NAME  zstd (default), xz, gzip, or none
  -l, --level N          compression level (default: 19 for zstd, 9 for xz/gzip)
  -T, --threads N        compressor threads (default: all CPUs)
  -x, --exclude PATTERN  extra tar exclude pattern, relative to the root
                         (repeatable, e.g. -x ./opt/*/src)
      --no-verify        skip re-reading the archive after writing it
      --no-numeric-owner do not force numeric owners (not recommended)
      --dry-run          print the tar command and the excluded paths, write nothing
  -h, --help             this help

Environment:
  BFS_STAGE3_COMPRESSOR  default compressor when -C is not given
  BFS_STAGE3_OUTPUT_DIR  directory for the default output name (default: .)

Examples:
  sudo $PROGRAM                       # / -> ./bfs-stage3-<dated>.tar.zst
  sudo $PROGRAM -r /mnt/stormfs -o /var/tmp/stage3.tar.zst
  sudo $PROGRAM -C xz -l 6 -x './var/cache/*'
EOF
}

die() {
	printf '%s: %s\n' "$PROGRAM" "$1" >&2
	exit "${2:-1}"
}

# Paths that are never captured.  Pseudo-filesystems are mounted state; the
# caches and logs are regenerated; lost+found belongs to the filesystem.
BASE_EXCLUDES=(
	./proc
	./sys
	./dev
	./run
	./tmp
	./var/tmp
	./var/run
	./var/lock
	./mnt
	./media
	./lost+found
	./var/cache/pkgmk
	./var/cache/ccache
	./var/cache/scratchpkg/work
	./var/cache/scratchpkg/sources
	./var/lib/ports
)

while [ $# -gt 0 ]; do
	case $1 in
		-r|--root) [ $# -ge 2 ] || die "$1 needs an argument"; ROOT=$2; shift 2 ;;
		-o|--output) [ $# -ge 2 ] || die "$1 needs an argument"; OUTPUT=$2; shift 2 ;;
		-C|--compressor) [ $# -ge 2 ] || die "$1 needs an argument"; COMPRESSOR=$2; shift 2 ;;
		-l|--level) [ $# -ge 2 ] || die "$1 needs an argument"; LEVEL=$2; LEVEL_GIVEN=yes; shift 2 ;;
		-T|--threads) [ $# -ge 2 ] || die "$1 needs an argument"; THREADS=$2; shift 2 ;;
		-x|--exclude) [ $# -ge 2 ] || die "$1 needs an argument"; EXCLUDES+=("$2"); shift 2 ;;
		--no-verify) VERIFY=no; shift ;;
		--no-numeric-owner) NUMERIC_OWNER=no; shift ;;
		--dry-run) DRY_RUN=yes; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1 (try --help)" ;;
	esac
done

if [ "$LEVEL_GIVEN" = yes ]; then
	case $LEVEL in
		''|*[!0-9]*) die "invalid compression level: $LEVEL" ;;
	esac
fi

[ -d "$ROOT" ] || die "root filesystem not found: $ROOT"
ROOT=$(cd "$ROOT" && pwd -P)

# Resolve the compressor and its flags.
COMPRESSOR=${COMPRESSOR:-${BFS_STAGE3_COMPRESSOR:-zstd}}
case $COMPRESSOR in
	zstd|zst)
		COMPRESSOR=zstd
		command -v zstd >/dev/null 2>&1 || die "zstd not found; install it or use -C xz/-C gzip"
		[ "$LEVEL_GIVEN" = yes ] || LEVEL=19
		THREADS=${THREADS:-0}
		COMPRESS_CMD="zstd -T$THREADS -$LEVEL"
		EXT=zst
		;;
	xz)
		command -v xz >/dev/null 2>&1 || die "xz not found"
		[ "$LEVEL_GIVEN" = yes ] || LEVEL=6
		THREADS_ARG=""; [ -n "$THREADS" ] && THREADS_ARG=" -T$THREADS"
		COMPRESS_CMD="xz -$LEVEL$THREADS_ARG"
		EXT=xz
		;;
	gzip|gz)
		COMPRESSOR=gzip
		command -v gzip >/dev/null 2>&1 || die "gzip not found"
		[ "$LEVEL_GIVEN" = yes ] || LEVEL=9
		COMPRESS_CMD="gzip -$LEVEL"
		EXT=gz
		;;
	none|tar)
		COMPRESSOR=none
		COMPRESS_CMD=
		EXT=tar
		;;
	*) die "unknown compressor: $COMPRESSOR" ;;
esac

if [ -z "$OUTPUT" ]; then
	version=BFSOS
	if [ -r "$ROOT/etc/bfs-release" ]; then
		# shellcheck disable=SC1090
		version=$(sed -n 's/^[[:space:]]*\(BFS_VERSION\|VERSION\)[[:space:]]*=[[:space:]]*//p' "$ROOT/etc/bfs-release" | head -n1 | tr -d '"'"'")
		[ -n "$version" ] || version=BFSOS
	elif [ -r "$ROOT/etc/os-release" ]; then
		version=$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT/etc/os-release" | head -n1)
		[ -n "$version" ] || version=BFSOS
	fi
	arch=$(uname -m)
	OUTPUT="${BFS_STAGE3_OUTPUT_DIR:-.}/bfs-stage3-${version}-$(date +%Y%m%d)-${arch}.tar.${EXT}"
fi

# Never write the archive inside the tree we are archiving.
case $OUTPUT in
	/*) OUTPUT_ABS=$OUTPUT ;;
	*) OUTPUT_ABS=$PWD/${OUTPUT#./} ;;
esac
case $OUTPUT_ABS in
	"$ROOT"/*) die "output path is inside the root being archived: $OUTPUT_ABS" ;;
esac

TAR_EXCLUDES=()
for pattern in "${BASE_EXCLUDES[@]}" "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do
	TAR_EXCLUDES+=(--exclude="$pattern")
done

TAR_OPTS=(
	--one-file-system
	"${TAR_EXCLUDES[@]}"
	--warning=no-file-changed
	--warning=no-file-removed
	--ignore-failed-read
	-C "$ROOT"
)
[ "$NUMERIC_OWNER" = yes ] && TAR_OPTS+=(--numeric-owner)

if [ -n "$COMPRESS_CMD" ]; then
	COMPRESS_OPTS=(-I "$COMPRESS_CMD")
else
	COMPRESS_OPTS=()
fi

if [ "$DRY_RUN" = yes ]; then
	printf '%s: would run (from %s):\n' "$PROGRAM" "$ROOT"
	printf '  tar %s %s -cf %s .\n' \
		"${COMPRESS_OPTS[*]:-(no compression)}" "${TAR_OPTS[*]}" "$OUTPUT_ABS"
	printf '%s: excluded paths:\n' "$PROGRAM"
	for pattern in "${BASE_EXCLUDES[@]}" "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do
		printf '  %s\n' "$pattern"
	done
	exit 0
fi

command -v tar >/dev/null 2>&1 || die "tar not found"

umask 022
output_dir=$(dirname "$OUTPUT_ABS")
[ -d "$output_dir" ] || die "output directory does not exist: $output_dir"
[ -w "$output_dir" ] || die "output directory is not writable: $output_dir (run with sudo?)"

tmp_output="$OUTPUT_ABS.partial.$$"
trap 'rm -f -- "$tmp_output"' EXIT INT TERM

printf '%s: archiving %s -> %s (%s)\n' "$PROGRAM" "$ROOT" "$OUTPUT_ABS" "$COMPRESSOR"

start=$(date +%s)
status=0
tar "${COMPRESS_OPTS[@]}" "${TAR_OPTS[@]}" -cpf "$tmp_output" . || status=$?

if [ "$status" -ne 0 ]; then
	rm -f -- "$tmp_output"
	# tar returns 1 for "some files changed while reading"; that is normal on a
	# live root filesystem, and --ignore-failed-read already covers busy files.
	if [ "$status" -eq 1 ]; then
		printf '%s: warning: tar reported changed files while reading %s (exit 1); archive kept\n' "$PROGRAM" "$ROOT" >&2
	else
		die "tar failed with status $status; no archive written" "$status"
	fi
fi

[ -s "$tmp_output" ] || { rm -f -- "$tmp_output"; die "archive is empty: nothing was captured"; }

mv -f -- "$tmp_output" "$OUTPUT_ABS"
trap - EXIT INT TERM

if [ "$VERIFY" = yes ]; then
	printf '%s: verifying archive...\n' "$PROGRAM"
	if ! tar -tf "$OUTPUT_ABS" >/dev/null; then
		die "archive verification failed (truncated or corrupt): $OUTPUT_ABS"
	fi
fi

elapsed=$(( $(date +%s) - start ))
size=$(du -h "$OUTPUT_ABS" 2>/dev/null | cut -f1)
count=$(tar -tf "$OUTPUT_ABS" 2>/dev/null | wc -l)

printf '%s: wrote %s (%s, %s entries, %ss)\n' "$PROGRAM" "$OUTPUT_ABS" "${size:-?}" "$count" "$elapsed"
printf '%s: restore with: sudo tar --numeric-owner -xpf %s -C <target>\n' "$PROGRAM" "$OUTPUT_ABS"
