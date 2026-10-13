#!/bin/sh
#
# BFSOS scratchpkg build conventions
# ----------------------------------
#
# This tree's recipes were written for the CRUX `pkgmk` extension that BFSOS
# ships, which
#
#   * cd's into the extracted source directory before running the recipe,
#   * applies every *.patch / *.diff listed in `source` automatically,
#   * fills in a default build for recipes that define no build function,
#     using BFSOS layout defaults (prefix=/usr, sysconfdir=/etc, ...), and
#   * runs the recipe's pre_build/post_build hooks around the build.
#
# scratchpkg's `pkgbuild` does none of that: it runs build() from $SRC (the
# extraction root) and calls only what the recipe defines.  This library
# restores those conventions so every converted `.spkgbuild` in the tree
# behaves the way it did under pkgmk.
#
# Generated recipes source it as:
#
#     . /usr/libexec/bfs/spkgbuild-lib.sh
#
# The library only ever reads/writes under $SRC and $PKG.  It is POSIX sh so
# it works whichever shell `pkgbuild` runs under; the one bash-only path
# (array-valued `build_opt`) is reached through `eval` and is skipped when the
# shell has no `declare`.

BFS_PKG_LIBDIR=${BFS_PKG_LIBDIR:-/usr/lib}
BFS_PKG_LIBDIR_NAME=${BFS_PKG_LIBDIR_NAME:-${BFS_PKG_LIBDIR##*/}}
BFS_AUTO_PATCH=${BFS_AUTO_PATCH:-yes}
export BFS_PKG_LIBDIR BFS_PKG_LIBDIR_NAME BFS_AUTO_PATCH

# compat-32 recipes call this to assert the pkgmk extension API level.  Under
# scratchpkg the same guarantee (32-bit compiler flags, lib32 paths) comes from
# the preamble the port converter emits, so it is a no-op here.
_bfs_require_compat32_extension() {
	return 0
}

# Make the BFSOS non-/usr Qt6 and KF6 prefixes visible to every package build,
# the way pkgmk's extension does.  Skipped for 32-bit builds, which must not
# pick up 64-bit /opt libraries.
_bfs_prepend_env_path() {
	_bfs_var=$1
	_bfs_dir=$2
	eval "_bfs_current=\${$_bfs_var:-}"

	if [ -d "$_bfs_dir" ]; then
		case ":$_bfs_current:" in
			*":$_bfs_dir:"*) ;;
			*)
				if [ -n "$_bfs_current" ]; then
					eval "export $_bfs_var=\"$_bfs_dir:$_bfs_current\""
				else
					eval "export $_bfs_var=\"$_bfs_dir\""
				fi
				;;
		esac
	fi
	unset _bfs_var _bfs_dir _bfs_current
}

_bfs_setup_prefix_env() {
	[ "$BFS_PKG_LIBDIR_NAME" != lib32 ] || return 0

	_bfs_qt6_prefix=${QT6DIR:-/opt/qt6}
	if [ -d "$_bfs_qt6_prefix" ]; then
		export QT6DIR="$_bfs_qt6_prefix"
		_bfs_prepend_env_path CMAKE_PREFIX_PATH "$_bfs_qt6_prefix"
		_bfs_prepend_env_path CPLUS_INCLUDE_PATH "$_bfs_qt6_prefix/include"
		_bfs_prepend_env_path LIBRARY_PATH "$_bfs_qt6_prefix/lib"
		_bfs_prepend_env_path PKG_CONFIG_PATH "$_bfs_qt6_prefix/lib/pkgconfig"
	fi

	_bfs_kf6_prefix=${KF6_PREFIX:-/opt/kf6}
	if [ -d "$_bfs_kf6_prefix" ]; then
		export KF6_PREFIX="$_bfs_kf6_prefix"
		_bfs_prepend_env_path CMAKE_PREFIX_PATH "$_bfs_kf6_prefix"
		_bfs_prepend_env_path CPLUS_INCLUDE_PATH "$_bfs_kf6_prefix/include"
		_bfs_prepend_env_path LIBRARY_PATH "$_bfs_kf6_prefix/lib"
		_bfs_prepend_env_path PKG_CONFIG_PATH "$_bfs_kf6_prefix/lib/pkgconfig"
	fi
	unset _bfs_qt6_prefix _bfs_kf6_prefix
}

_bfs_setup_prefix_env

bfs_msg() {
	printf ' -> %s\n' "$1"
}

bfs_warn() {
	printf 'spkgbuild: warning: %s\n' "$1" >&2
}

bfs_die() {
	printf 'spkgbuild: error: %s\n' "$1" >&2
	return 1
}

# Collect the recipe's `build_opt` into BFS_BUILD_OPTS.
#
# Scalar build_opt is whitespace-separated (newlines separate arguments too);
# an array-valued build_opt keeps embedded whitespace intact and needs bash,
# which is what BFSOS ships as /bin/sh.
bfs_build_opts() {
	BFS_BUILD_OPTS=
	case "$(declare -p build_opt 2>/dev/null || true)" in
		"declare -a "*|"declare -A "*)
			eval 'BFS_BUILD_OPTS=("${build_opt[@]}")'
			;;
		*)
			if [ -n "${build_opt:-}" ]; then
				BFS_BUILD_OPTS=$(printf '%s' "$build_opt" | tr '\n' ' ')
			fi
			;;
	esac
}

# True when `build_opt` already carries the given option (exactly, or as a
# -DKEY=value prefix).
bfs_build_opt_has() {
	_bfs_needle=$1
	set -- "${BFS_BUILD_OPTS[@]}"
	for _bfs_opt in "$@"; do
		case $_bfs_opt in
			"$_bfs_needle"|"$_bfs_needle"=*) return 0 ;;
		esac
	done
	return 1
}

bfs_jobs() {
	if [ -z "${JOBS:-}" ]; then
		JOBS=$(nproc 2>/dev/null || echo 1)
	fi
	printf '%s' "$JOBS"
}

# ---------------------------------------------------------------------------
# Source-tree entry and automatic patch application
# ---------------------------------------------------------------------------

# scratchpkg runs build() from $SRC; CRUX ran the recipe from inside the
# extracted source directory.  Mirror the pkgmk extension's rule exactly:
# prefer $name-$version, else the single directory present, else stay put.
bfs_enter_srcdir() {
	if [ -d "$SRC/$name-$version" ]; then
		cd "$SRC/$name-$version" || return 1
		return 0
	fi

	_bfs_count=0
	_bfs_only=
	for _bfs_dir in "$SRC"/*/; do
		[ -d "$_bfs_dir" ] || continue
		_bfs_count=$((_bfs_count + 1))
		_bfs_only=$_bfs_dir
	done
	if [ "$_bfs_count" -eq 1 ]; then
		cd "$_bfs_only" || return 1
	elif [ "$_bfs_count" -gt 1 ]; then
		bfs_warn "several source directories in $SRC; staying in $SRC (recipes that need one must cd themselves)"
	fi
	unset _bfs_dir _bfs_count _bfs_only
	return 0
}

# Apply the patch sources the recipe lists, the way pkgmk's extension did:
# try -p1, fall back to -p0, and never abort on an already-applied patch.
bfs_apply_patches() {
	[ "$BFS_AUTO_PATCH" = yes ] || return 0

	for _bfs_patch in \
		"$SRC"/*.patch "$SRC"/*.patch.gz "$SRC"/*.patch.xz "$SRC"/*.patch.bz2 \
		"$SRC"/*.diff "$SRC"/*.diff.gz "$SRC"/*.diff.xz "$SRC"/*.diff.bz2
	do
		[ -f "$_bfs_patch" ] || continue
		case $_bfs_patch in
			*.gz)  _bfs_decompress="gzip -dc" ;;
			*.xz)  _bfs_decompress="xz -dc" ;;
			*.bz2) _bfs_decompress="bzip2 -dc" ;;
			*)     _bfs_decompress= ;;
		esac

		if [ -n "$_bfs_decompress" ]; then
			if $_bfs_decompress "$_bfs_patch" | patch -t -N --dry-run ${patch_opt:--p1} >/dev/null 2>&1; then
				$_bfs_decompress "$_bfs_patch" | patch -t ${patch_opt:--p1} || return 1
			else
				$_bfs_decompress "$_bfs_patch" | patch -t ${patch_opt:--p0} || return 1
			fi
		else
			if patch -t -N --dry-run ${patch_opt:--p1} -i "$_bfs_patch" >/dev/null 2>&1; then
				patch -t ${patch_opt:--p1} -i "$_bfs_patch" || return 1
			else
				patch -t ${patch_opt:--p0} -i "$_bfs_patch" || return 1
			fi
		fi
		bfs_msg "applied $(basename "$_bfs_patch")"
	done
	unset _bfs_patch _bfs_decompress
	return 0
}

# ---------------------------------------------------------------------------
# Build-system detection and default builds
# ---------------------------------------------------------------------------

# Sets BFS_BUILD_TYPE to one of: meson configure cmake python3 perlmodule
# makefile.  Same order of checks as the pkgmk extension.
bfs_detect_buildtype() {
	if [ -f meson.build ]; then
		BFS_BUILD_TYPE=meson
	elif [ -f configure ]; then
		BFS_BUILD_TYPE=configure
	elif [ -f CMakeLists.txt ]; then
		BFS_BUILD_TYPE=cmake
	elif [ -f setup.py ]; then
		BFS_BUILD_TYPE=python3
	elif [ -f Makefile.PL ]; then
		BFS_BUILD_TYPE=perlmodule
	elif [ -f Makefile ] || [ -f makefile ]; then
		BFS_BUILD_TYPE=makefile
	else
		bfs_die "failed to detect a build system in $PWD"
		return 1
	fi
	return 0
}

bfs_makefile_build() {
	make "${BFS_BUILD_OPTS[@]}" || return 1
	make \
		PREFIX=/usr prefix=/usr \
		SYSCONFDIR=/etc sysconfdir=/etc \
		MANDIR=/usr/share/man mandir=/usr/share/man \
		LIBDIR="$BFS_PKG_LIBDIR" libdir="$BFS_PKG_LIBDIR" \
		PKGCONFIGDIR="$BFS_PKG_LIBDIR/pkgconfig" \
		"${BFS_BUILD_OPTS[@]}" \
		DESTDIR="$PKG" install || return 1
}

bfs_perlmodule_build() {
	perl Makefile.PL || return 1
	make || return 1
	make DESTDIR="$PKG" install || return 1
}

bfs_python3_build() {
	python3 setup.py build || return 1
	python3 setup.py install --prefix=/usr --root="$PKG" --optimize=1 --skip-build || return 1
}

bfs_configure_build() {
	# Test suites are off unless the recipe asks for them, matching pkgmk.
	_bfs_configure_test_args=
	case "${run_tests:-no}" in
		yes) ;;
		*)
			_bfs_configure_help=$(./configure --help 2>/dev/null || true)
			for _bfs_opt in --disable-tests --disable-test --disable-checks --disable-check; do
				case $_bfs_configure_help in
					*"$_bfs_opt"*) _bfs_configure_test_args="$_bfs_opt"; break ;;
				esac
			done
			;;
	esac

	_bfs_configure_host_args=
	if [ "$BFS_PKG_LIBDIR_NAME" = lib32 ]; then
		_bfs_configure_host_args="--host=${BFS_MULTILIB_HOST:-i686-pc-linux-gnu}"
	fi

	_bfs_configure_cmd=./configure
	if [ "${configure_out_of_tree:-no}" = yes ]; then
		_bfs_configure_src=$PWD
		mkdir -p "${configure_build_dir:-_configure_build}" || return 1
		cd "${configure_build_dir:-_configure_build}" || return 1
		_bfs_configure_cmd="$_bfs_configure_src/configure"
	fi

	# shellcheck disable=SC2086
	"$_bfs_configure_cmd" \
		--prefix=/usr \
		--sysconfdir=/etc \
		--libexecdir=/usr/lib \
		--localstatedir=/var \
		--mandir=/usr/share/man \
		--libdir="$BFS_PKG_LIBDIR" \
		$_bfs_configure_host_args \
		$_bfs_configure_test_args \
		"${BFS_BUILD_OPTS[@]}" || return 1

	_bfs_jobs=$(bfs_jobs)
	case "${configure_build_tool:-make}" in
		ninja)
			ninja -j"$_bfs_jobs" || return 1
			DESTDIR="$PKG" ninja install || return 1
			;;
		make)
			make -j"$_bfs_jobs" || return 1
			make DESTDIR="$PKG" install || return 1
			;;
		*)
			bfs_die "unsupported configure_build_tool: ${configure_build_tool}"
			return 1
			;;
	esac
	unset _bfs_configure_test_args _bfs_configure_host_args _bfs_configure_cmd \
		_bfs_configure_help _bfs_opt _bfs_jobs
	return 0
}

bfs_cmake_build() {
	_bfs_cmake_policy_args=
	# CMake 4 rejects projects that ask for a pre-3.5 policy version; BFSOS
	# supplies the compatibility floor unless the recipe sets its own.
	if [ "$(cmake --version 2>/dev/null | awk 'NR==1 {split($3,v,"."); print v[1]+0}')" -ge 4 ] 2>/dev/null; then
		bfs_build_opt_has -DCMAKE_POLICY_VERSION_MINIMUM || \
			_bfs_cmake_policy_args="-DCMAKE_POLICY_VERSION_MINIMUM=${BFS_CMAKE_POLICY_VERSION_MINIMUM:-3.5}"
	fi

	_bfs_cmake_test_args=
	case "${run_tests:-no}" in
		yes) ;;
		*)
			for _bfs_opt in BUILD_TESTING BUILD_TESTS ENABLE_TESTS; do
				bfs_build_opt_has "-D$_bfs_opt" && continue
				if [ "$_bfs_opt" = BUILD_TESTING ] && grep -Eq 'include[[:space:]]*\([[:space:]]*CTest' ../CMakeLists.txt 2>/dev/null; then
					_bfs_cmake_test_args="$_bfs_cmake_test_args -D$_bfs_opt=OFF"
				elif grep -Eq "(option[[:space:]]*\\([[:space:]]*$_bfs_opt([[:space:]]|\\)))" ../CMakeLists.txt 2>/dev/null; then
					_bfs_cmake_test_args="$_bfs_cmake_test_args -D$_bfs_opt=OFF"
				fi
			done
			;;
	esac

	_bfs_generator=
	command -v ninja >/dev/null 2>&1 && _bfs_generator="-G Ninja"

	mkdir -p cmakebuild || return 1
	cd cmakebuild || return 1
	# shellcheck disable=SC2086
	cmake -DCMAKE_INSTALL_PREFIX=/usr \
		-DCMAKE_INSTALL_SYSCONFDIR=/etc \
		-DCMAKE_INSTALL_LIBDIR="$BFS_PKG_LIBDIR_NAME" \
		-DCMAKE_INSTALL_LIBEXECDIR="$BFS_PKG_LIBDIR_NAME" \
		-DCMAKE_BUILD_TYPE=Release \
		-DFETCHCONTENT_FULLY_DISCONNECTED=ON \
		-DCMAKE_C_FLAGS_RELEASE="${CFLAGS:--O2}" \
		-DCMAKE_CXX_FLAGS_RELEASE="${CXXFLAGS:-${CFLAGS:--O2}}" \
		$_bfs_cmake_policy_args \
		$_bfs_cmake_test_args \
		"${BFS_BUILD_OPTS[@]}" \
		$_bfs_generator .. || return 1
	cmake --build . --parallel "$(bfs_jobs)" || return 1
	DESTDIR="$PKG" cmake --install . || return 1
	unset _bfs_cmake_policy_args _bfs_cmake_test_args _bfs_generator _bfs_opt
	return 0
}

bfs_meson_build() {
	_bfs_meson_arch_args=
	if [ "$BFS_PKG_LIBDIR_NAME" = lib32 ]; then
		# Meson takes the host machine from a cross description rather than
		# from -m32, so supply one instead of shipping a cross file per port.
		cat > .bfsos-compat32.cross <<-EOF || return 1
		[binaries]
		c = '${CC:-gcc}'
		cpp = '${CXX:-g++}'
		ar = 'ar'
		strip = 'strip'
		pkg-config = 'pkg-config'

		[properties]
		needs_exe_wrapper = false

		[host_machine]
		system = 'linux'
		cpu_family = 'x86'
		cpu = 'i686'
		endian = 'little'
		EOF
		_bfs_meson_arch_args="--cross-file .bfsos-compat32.cross"
	fi

	# shellcheck disable=SC2086
	meson setup _meson_build \
		--prefix=/usr \
		--libdir="$BFS_PKG_LIBDIR" \
		--libexecdir="$BFS_PKG_LIBDIR" \
		--includedir=/usr/include \
		--datadir=/usr/share \
		--mandir=/usr/share/man \
		--infodir=/usr/share/info \
		--localedir=/usr/share/locale \
		--sysconfdir=/etc \
		--localstatedir=/var \
		--sharedstatedir=/var/lib \
		--buildtype=plain \
		--auto-features=auto \
		--wrap-mode=nodownload \
		-Db_lto=true \
		-Db_pie=true \
		$_bfs_meson_arch_args \
		"${BFS_BUILD_OPTS[@]}" || return 1

	case "${run_tests:-no}" in
		yes)
			meson compile -C _meson_build -j "$(bfs_jobs)" || return 1
			meson test -C _meson_build --print-errorlogs || return 1
			;;
		*)
			# Wrap-dependent test suites break offline builds, so switch off the
			# options a project actually exposes rather than guessing.
			_bfs_meson_cfg=$(meson configure _meson_build 2>/dev/null || true)
			for _bfs_opt in tests test build_tests build-tests enable_tests enable-tests; do
				bfs_build_opt_has "-D$_bfs_opt" && continue
				printf '%s\n' "$_bfs_meson_cfg" | grep -Eq "^[[:space:]]*$_bfs_opt[[:space:]]" || continue
				if meson configure _meson_build "-D$_bfs_opt=disabled" >/dev/null 2>&1; then
					bfs_msg "disabled Meson test option $_bfs_opt"
				elif meson configure _meson_build "-D$_bfs_opt=false" >/dev/null 2>&1; then
					bfs_msg "disabled Meson test option $_bfs_opt"
				else
					bfs_warn "Meson exposes '$_bfs_opt' but it could not be disabled"
				fi
			done
			meson compile -C _meson_build -j "$(bfs_jobs)" || return 1
			;;
	esac

	DESTDIR="$PKG" meson install --no-rebuild -C _meson_build || return 1
	unset _bfs_meson_arch_args _bfs_meson_cfg _bfs_opt
	return 0
}

# Run the default build for the recipe's source tree.
bfs_standard_build() {
	bfs_build_opts

	# A recipe may name its build system explicitly, using the pkgmk
	# extension's spelling (configure_build, meson_build, ...).
	if [ -z "${BFS_BUILD_TYPE:-}" ] && [ -n "${build_type:-}" ]; then
		case $build_type in
			configure_build)  BFS_BUILD_TYPE=configure ;;
			meson_build)      BFS_BUILD_TYPE=meson ;;
			cmake_build)      BFS_BUILD_TYPE=cmake ;;
			python3_build)    BFS_BUILD_TYPE=python3 ;;
			perlmodule_build) BFS_BUILD_TYPE=perlmodule ;;
			makefile_build)   BFS_BUILD_TYPE=makefile ;;
			*)                BFS_BUILD_TYPE=$build_type ;;
		esac
	fi

	if [ -z "${BFS_BUILD_TYPE:-}" ]; then
		bfs_detect_buildtype || return 1
	fi
	bfs_msg "build type: $BFS_BUILD_TYPE"
	case $BFS_BUILD_TYPE in
		configure)  bfs_configure_build ;;
		meson)      bfs_meson_build ;;
		cmake)      bfs_cmake_build ;;
		python3)    bfs_python3_build ;;
		perlmodule) bfs_perlmodule_build ;;
		makefile)   bfs_makefile_build ;;
		*) bfs_die "unsupported build type: $BFS_BUILD_TYPE"; return 1 ;;
	esac
}
