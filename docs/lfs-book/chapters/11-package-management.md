# Chapter 11: Package Management (pkgutils + pacman pipeline)

StormFS Linux ships **two cooperating package layers**: the traditional
CRUX **pkgutils/ports** recipes (`Pkgfile`, `pkgmk`, `pkgadd`, `prt-get`)
that the bootstrap uses to build the base system, and the newer
**pacman-format pipeline** (`bfs-build`, `bfs-deps`, `bfsos`, `pacman`)
that is the supported front end for post-install package management.
This chapter covers both, and when to use which.

## 11.1 pkgutils Overview

pkgutils is a lightweight, source-based package management toolkit. Packages are built from **ports** (build recipes) using `pkgmk`, installed with `pkgadd`, and queried with `pkginfo`.

### Core Commands

| Command | Purpose |
|---------|---------|
| `pkgmk` | Build a package from a port (Pkgfile) |
| `pkgadd` | Install a built package (.pkg.tar.zst) |
| `pkginfo` | Query installed or built packages |
| `pkgutil` | Upgrade, remove, and manage packages |
| `prt-get` | Dependency-aware front-end to pkgutils |

### Installing pkgutils from Source

```bash
cd /sources
tar -xf pkgutils-21.07.20230724.tar.xz
cd pkgutils-21.07.20230724

# Patch for musl/libc compatibility if needed
# patch -Np1 -i ../pkgutils-musl.patch

./configure --prefix=/usr \
            --bindir=/usr/bin \
            --libdir=/usr/lib/pkgutils
make
make install
```

## 11.2 Building Packages with pkgmk

### Basic Usage

```bash
cd /path/to/port/
pkgmk -d
```

The `-d` flag builds the package in the current directory. `pkgmk` reads the `Pkgfile` in the port directory and:

1. Downloads source tarballs (as specified in the `source` array)
2. Executes the `build()` function to compile
3. Packages the result into `/var/spool/pkg/` as a `.pkg.tar.zst` file

### Common pkgmk Flags

| Flag | Purpose |
|------|---------|
| `-d` | Build in current directory |
| `-c` | Clean before building (remove previous build artifacts) |
| `-rf` | Force rebuild even if package exists |
| `-ui` | Update and install (requires `prt-get`) |
| `-P /path` | Specify alternate prefix directory |

### Build Output

Packages are placed in `/var/spool/pkg/` by default:

```bash
ls /var/spool/pkg/
# example: nano-9.1-1.pkg.tar.zst
```

### Incremental Builds

pkgmk caches the extracted sources in `/var/spool/pkg/sources/`. To force a fresh source download:

```bash
pkgmk -c -d
```

## 11.3 Installing Packages with pkgadd

```bash
# Install a package from the spool
pkgadd /var/spool/pkg/nano-9.1-1.pkg.tar.zst

# Install from a URL
pkgadd https://pkg StormFS.org/repo/pkgs/nano-9.1-1.pkg.tar.zst
```

### What pkgadd Does

1. Extracts the package to `/`
2. Runs `post_install()` if defined in the port's Pkgfile
3. Registers the package in `/var/lib/pkg/`

### Package Database

Installed packages are tracked in:

```
/var/lib/pkg/
├── nano/
│   ├──.desc
│   ├── footprint
│   └── pkgfile
```

## 11.4 Querying Packages with pkginfo

```bash
# List all installed packages
pkginfo -i

# Show files in an installed package
pkginfo -l nano

# Show package description
pkginfo -d nano

# Show a specific installed package's Pkgfile
pkginfo -R nano

# List files provided by a package
pkginfo -a nano
```

### Querying Built Packages

```bash
# List packages in the spool
pkginfo -t

# Show info about a built (not installed) package
pkginfo -i /var/spool/pkg/nano-9.1-1.pkg.tar.zst
```

## 11.5 Removing Packages with pkgutil

```bash
# Remove a package
pkgutil -r nano

# Remove a package and its unused dependencies
pkgutil -ry nano

# Upgrade a single package (reinstall over existing)
pkgutil -i /var/spool/pkg/nano-9.1-1.pkg.tar.zst

# Upgrade all installed packages from spool
pkgutil -u
```

### pkgutil Flags

| Flag | Purpose |
|------|---------|
| `-i <pkg>` | Install a package |
| `-r <pkg>` | Remove a package |
| `-ry <pkg>` | Remove package and orphaned dependencies |
| `-u` | Upgrade all installed packages from spool |
| `-ui` | Upgrade and install (interactive, integrates with prt-get) |
| `-l` | List installed packages |

## 11.6 prt-get — Dependency Resolution

`prt-get` is a higher-level front-end that adds dependency resolution, repository management, and easier upgrades.

### Installing prt-get

```bash
cd /sources
tar -xf prt-get-5.37.1.tar.xz
cd prt-get-5.37.1

./configure --prefix=/usr \
            --sysconfdir=/etc
make
make install
```

### Repository Configuration

Edit `/etc/prt-get.conf`:

```bash
# /etc/prt-get.conf

# Repositories in order of priority (first match wins)
PRTPATH=/usr/ports:/usr/local/ports

# Verbosity: 0=quiet, 1=normal, 2=verbose
VERBOSE=1

# Build directory
PKGDIR=/var/spool/pkg

# Dependency handling
# Options: warn, yes, no
DEPENDENCY_CHECK=yes

# When a package has multiple providers, use the first one
AVOID = "package-a package-b"
```

### Using prt-get

```bash
# Install a package with dependencies
prt-get install nano

# Install a package and rebuild it if already installed
prt-get install --force nano

# Remove a package and unused dependencies
prt-get remove nano

# Remove orphaned dependencies
prt-getorphans

# Upgrade all installed packages
prt-get sysup

# Upgrade a specific package
prt-get diff nano

# Search for a package in repositories
prt-get search nano

# Show package info
prt-get info nano

# Show dependency tree
prt-get depstree nano

# List outdated packages
prt-get list-orphans
prt-get list-non-python2-orphans

# Rebuild a package
prt-get rebuild nano
```

### Handling Dependency Conflicts

If two packages provide the same virtual dependency, prt-get will ask or follow the `AVOID` list:

```bash
# /etc/prt-get.conf
AVOID = "openssl-compat"
```

## 11.7 Port Structure — Pkgfile Format

A **port** is a directory containing at minimum a `Pkgfile` and a `signature` file (for integrity).

### Example Pkgfile

```bash
# stormfs ports — nano
# Maintainer: StormFS Development Team <dev@stormfs.org>

# Dependency note: nano requires ncurses for terminal support

nano() {
    # Package metadata
    name=nano
    version=8.1
    release=1
    source=($name.org/Files/nano-$version.tar.xz)

    # Build options
    CFLAGS="$CFLAGS -O2"
    CXXFLAGS="$CXXFLAGS -O2"

    build() {
        cd $name-$version

        ./configure \
            --prefix=/usr \
            --sysconfdir=/etc \
            --enable-color \
            --enable-nls \
            --enable-utf8 \
            --docdir=/usr/share/doc/$name-$version

        make
        make install DESTDIR=$PKG

        # Install documentation
        mkdir -p $PKG/usr/share/doc/$name-$version
        install -m644 doc/nano.html $PKG/usr/share/doc/$name-$version/

        # Install locale files
        make install DESTDIR=$PKG
    }

    post_install() {
        echo "nano installed. Set as default editor with:"
        echo "  update-alternatives --set editor /usr/bin/nano"
    }
}
```

### Pkgfile Variables

| Variable | Description |
|----------|-------------|
| `name` | Package name |
| `version` | Package version |
| `release` | Package release number (bump on rebuild) |
| `source` | Array of source URLs |
| `CFLAGS` | Compiler flags (inherited or custom) |
| `CXXFLAGS` | C++ compiler flags |
| `build()` | Function that compiles and installs into `$PKG` |
| `pre_install()` | Runs before installation |
| `post_install()` | Runs after installation |
| `pre_remove()` | Runs before removal |
| `post_remove()` | Runs after removal |

### Special Variables

| Variable | Value |
|----------|-------|
| `$PKG` | Temporary install root (e.g., `/var/spool/pkg/name-version/`) |
| `$name` | Package name |
| `$version` | Package version |
| `$source` | Array of downloaded sources |

### Signature File

Each port should have a `signature` file with checksums:

```bash
# stormfs ports — nano
# Generated: 2026-08-17

md5sums=(skip)
sha256sums=("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
```

To generate checksums:

```bash
updpkgsums
```

## 11.8 Creating Custom Ports

### Step-by-Step Example: Creating a Port for `jq`

**1. Create the port directory:**

```bash
mkdir -p /usr/ports/contrib/jq
cd /usr/ports/contrib/jq
```

**2. Download and identify the source:**

```bash
# Find the download URL
# https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1.tar.gz
```

**3. Create the Pkgfile:**

```bash
cat > Pkgfile << 'PKGFILE'
# stormfs ports — jq
# Maintainer: Your Name <you@stormfs.org>

jq() {
    name=jq
    version=1.7.1
    release=1
    source=($name-$version.tar.gz)

    build() {
        cd $name-$version

        ./configure \
            --prefix=/usr \
            --sysconfdir=/etc \
            --with-oniguruma=builtin \
            --disable-docs

        make -j$(nproc)
        make install DESTDIR=$PKG
    }

    post_install() {
        echo "jq $version installed successfully."
    }
}
PKGFILE
```

**4. Generate the signature file:**

```bash
updpkgsums
```

**5. Build and test:**

```bash
pkgmk -d
pkgadd /var/spool/pkg/jq-1.7.1-1.pkg.tar.zst
```

**6. Verify installation:**

```bash
which jq
jq --version
pkginfo -l jq
```

### Testing Your Port

Always test in a clean environment or container before contributing:

```bash
# Build with debug output
pkgmk -d -v

# Install to a test prefix
make install DESTDIR=/tmp/test-install
```

## 11.9 Repository Management (REPO Files)

### Repository Configuration

Repositories are defined by their directory on the filesystem. Each repository is a directory tree of ports:

```
/usr/ports/
├── core/
│   ├── bash/
│   │   └── Pkgfile
│   ├── coreutils/
│   │   └── Pkgfile
│   ├── gcc/
│   │   └── Pkgfile
│   └── ...
├── contrib/
│   ├── nano/
│   │   └── Pkgfile
│   ├── vim/
│   │   └── Pkgfile
│   └── ...
└── opt/
    ├── firefox/
    │   └── Pkgfile
    └── ...
```

### Repository Sources in prt-get

```bash
# /etc/prt-get.conf
PRTPATH=/usr/ports:/usr/local/ports
```

### Creating a Custom Repository

```bash
# Create repository directory
mkdir -p /usr/local/ports/custom/{myapp1,myapp2}

# Add to prt-get.conf
PRTPATH=/usr/ports:/usr/local/ports

# Build and install
cd /usr/local/ports/custom/myapp1
pkgmk -d
pkgadd /var/spool/pkg/myapp1-1.0-1.pkg.tar.zst
```

### Repository Mirrors

To mirror the StormFS repository:

```bash
# Using rsync
rsync -av --delete \
    rsync://mirror.stormfs.org/stormfs-ports/ \
    /usr/ports/

# Using wget (full mirror)
wget -r -np -nH --cut-dirs=1 \
    http://mirror.stormfs.org/stormfs-ports/ \
    -P /usr/ports/
```

## 11.10 Using the Port Manager GUI

StormFS includes a graphical port management interface for desktop users.

### Launching the Port Manager

```bash
stormfs-portmanager &
```

Or from the application menu: **System → Port Manager**

### Features

- **Search ports** across all configured repositories
- **View port details** including dependencies, description, and changelog
- **Build and install** packages with one click
- **Upgrade outdated** packages
- **View build logs** for troubleshooting
- **Manage repositories** (add/remove/reorder)

### Configuration

The GUI reads its configuration from `/etc/prt-get.conf` and stores user preferences in `~/.config/stormfs/portmanager.conf`.

### Terminal Integration

All operations in the GUI run the same CLI commands under the hood. You can always inspect what the GUI did:

```bash
# Check recent package operations
grep -r "pkgadd\|pkgutil" /var/log/stormfs-portmanager.log
```

## 11.11 Advanced Topics

### Cross-Compilation

To build packages for a different architecture:

```bash
ARCH=aarch64 pkgmk -d
```

### Using Alternate Prefixes

```bash
# Build for a custom prefix
PKGDIR=/tmp/staging pkgmk -d
```

### Package Signing

Sign your packages for integrity verification:

```bash
# Generate a signing key
gpg --gen-key

# Sign a package
gpg --armor --detach-sign /var/spool/pkg/nano-9.1-1.pkg.tar.zst

# Verify a package
gpg --verify /var/spool/pkg/nano-9.1-1.pkg.tar.zst.sig
```

## 11.12 References

- [CRUX Package Management](https://crux.nu/Handbook#packagemanagement)
- [pkgutils Man Page](https://crux.nu/man/pkgmk)
- [prt-get Man Page](https://crux.nu/man/prt-get)
- [Chapter 12: System Initialization](chapter-12-system-initialization.md)
- [Chapter 09: Linux Kernel](chapter-09-linux-kernel.md)

## 11.13 The pacman Pipeline (bfs-build / bfs-deps / bfsos / pacman)

Alongside pkgutils, BFSOS ships a **pacman-format package pipeline**.
Packages are still built **from source** against the BFSOS toolchain, but
the artifact, the install database, and the CLI are pacman's: the user
experience is `pacman` (`bfsos install`, `bfsos upgrade`, `pacman -U`
for one-off packages), and installed packages are tracked under
`/var/lib/pacman/` so standard pacman tooling (hooks, `-Ql`, `-Qms`,
dropped dep resolution) works unchanged.

This pipeline is what the **post-install layer** uses. The bootstrap
(Chapter 3–5) and the core system build still use pkgmk/pkgadd because
those must run before pacman itself exists.

### Why pacman, and what it does *not* mean

BFSOS **does not consume Arch's repositories.** Arch packages are built
against Arch's glibc, systemd wiring, and library ABI; mixing them with
BFSOS source builds risks subtle runtime breakage with no support path.
The pipeline brings pacman the **format and tooling**, not Arch's repo.

- Packages are qemitted as `.pkg.tar.zst` with pacman-compatible
  `.PKGINFO` and `.MTREE` members.
- The local repository (`bfsos`) lives at `/var/cache/repo/bfsos/` and is
  signed with `repo-add` + `pacman-key` the same way any local repo is.
- The `# Depends on:` headers in existing Pkgfiles carry over — they are
  the dependency contract between both layers.

### bfs-build — pacman-format package builder

`bfs-build` is the drop-in replacement for `pkgmk` in the pacman
pipeline. It reads the same `Pkgfile` you already know, sources the same
BFSOS extension shim (multilib env, `pre_build`/`pkg_build`/`post_build`
hooks, `keep_*` cleanup, KF6 unit relocation), and emits:

```
<name>-<version>-<release>-<arch>.pkg.tar.zst
```

with `.PKGINFO` and `.MTREE` members suitable for `pacman -U` and
`repo-add`. Usage:

```bash
cd /usr/ports/core/bzip2
bfs-build -d
# -> /var/cache/repo/packages/bzip2-1.0.8-1-x86_64.pkg.tar.zst
# -> published into /var/cache/repo/bfsos/ (when repo-add is present)
```

Key flags (a subset of the `pkgmk` interface so existing muscle memory
works): `-d` download sources, `-i` install after building, `-cf FILE`
read a pkgmk.conf-style config. Environment knobs:

| Variable | Default | Purpose |
|----------|---------|---------|
| `BFS_PKG_BUILD_WORK` | `tmpfs` | tmpfs or disk-backed work dir |
| `BFS_PACKAGE_DIR` | `/var/cache/repo/packages` | where built archives land |
| `BFS_BUILD_REPONAME` | `bfsos` | destination repository name |
| `BFS_BUILD_REPODIR` | `/var/cache/repo/$BFS_BUILD_REPONAME` | repository path |
| `BFS_BUILD_ADD_TO_REPO` | `yes` | run `repo-add` after building |

### bfs-deps — dependency closure / install order

`bfs-deps` replaces `prt-get depinst` / `quickdep` for the pacman
pipeline. It reads `# Depends on:` headers from Pkgfiles and runs on any
freshly-installed system before a repository sync has happened (this is
the same offline property `prt-get` had):

```bash
bfs-deps quickdep firefox      # full dependency closure
bfs-deps order firefox         # topological install order
bfs-deps missing firefox       # closure minus installed — what depinst did
bfs-deps isinst firefox glib   # installed / not installed
bfs-deps deps firefox          # direct deps of one port
```

Repositories are searched in `BFS_DEPS_COLLECTIONS` order (defaults:
`core opt xorg xfce gnome plasma lxqt compiz contrib compat-32 iso`),
mirroring `prt-get.conf`'s `prtdir` priority semantics.

### bfsos — the pacman front door

`bfsos` is the day-to-day CLI on BFSOS; it wraps pacman plus the source
build pipeline so "install a package" still works from source without
separately invoking bfs-deps and bfs-build:

```bash
bfsos sync                 # ports -u + pacman -Sy
bfsos install firefox      # resolve missing deps, build each, pacman -U
bfsos upgrade              # pacman -Su over the local repo (sysup equivalent)
bfsos remove vim           # pacman -R
bfsos search editor        # pacman -Ss
bfsos build nano           # just build a port into the local repo
bfsos native -Rsc nano     # run pacman verbatim for anything else
```

### bfs-repo-add — a repo database builder that works before pacman exists

`repo-add` ships with pacman, but on a fresh BFSOS system the repository
has to exist before pacman can be used. `bfs-repo-add` writes the same
`<repo>.db` tarball in the exact layout repo-add produces (one
`<pkgname>-<pkgver>/desc` and `files` entry per package), so the
bootstrap/installer can build the initial `bfsos` repository from
already-built packages and both `pacman` and `repo-add` consume it
unchanged afterwards. Entries for the same pkgname/pkgver are replaced,
so repo-add and bfs-repo-add can be intermixed when maintaining the
repository.

### bfs-build-all — batch builds for CI and mirrors

`bfs-build-all` walks a set of collections, builds every port whose
recipe invokes no compiler (BFSOS_SKIP_COMPILER=yes), publishes the
archives with `bfs-build`, and refreshes the `bfsos.db` with
`bfs-repo-add`. This is what the CI workflow in
`.github/workflows/build-repo.yml` uses to keep this repository's
`packages/` directory (and its `bfsos.db`) refreshed; nothing stops you
from running it locally with the full BFSOS toolchain.

### pacman itself

The `core/pacman` port builds pacman against BFSOS `libarchive`,
`curl`, and `gpgme` and installs the `bfsos`-only repo configuration.
The BFSOS installer builds and installs it automatically (`BFS_INSTALL_PACMAN=yes`, now the default) and then seeds the `bfsos`
repository with bfs-repo-add so `bfsos install/upgrade` works on first
boot.

```bash
# /etc/pacman.conf
[bfsos]
SigLevel = Optional TrustAll
Include = /etc/pacman.d/mirrorlist
# mirrorlist: Server = file:///var/cache/repo/bfsos
```

To serve the repo over the network (so several BFSOS machines share one
build host), publish `/var/cache/repo/bfsos/` with any web server and
point the mirrorlist at it. **Do not add an [arch]/[extra] section**
unless you accept the ABI-mixing risk described in "Why pacman, and
what it does not mean" above.

### When to use which layer

| Situation | Layer |
|-----------|-------|
| Bootstrap stages 1–5 (toolchain, base system, archive) | pkgutils (pkgmk/pkgadd) |
| Post-install daily package management (`install/remove/upgrade`) | pacman pipeline (bfsos) |
| Port maintenance, ABI-sensitive rebuilds, `compat-32` | either — Pkgfiles are shared |
| README/documentation references to "prt-get depinst" | read as `bfs-deps missing` + `bfsos install` |

### Relationship to the existing prt-get/pkgutils path

The two layers interoperate:

- Pkgfiles are unchanged — the same `# Depends on:`, `pre_build`,
  `pkg_build`, `post_build`, and `keep_*` semantics both layers honor.
- `bfs-deps missing` = `prt-get depinst` with the target pkgs.
- `prt-get quickdiff` + `prt-get sysup` = `bfsos upgrade`.
- Any port can be built by either `pkgmk -d` (for pkgadd) or
  `bfs-build -d` (for repo-add/pacman). Build both when switching.

### Bootstrapping pacman onto an existing BFSOS system

Once the base system exists and you have the `core/pacman` port synced,
`pacman` is just another pkgutils-built package:

```bash
# Build/install pacman itself with the legacy layer.
cd /usr/ports/core/pacman
pkgmk -d && pkgadd root/usr/ports/core/pacman/pacman-6.1.0-1-x86_64.pkg.tar.zst

# From here the pacman layer is alive.
bfsos sync
bfsos install <anything>
```

On fresh installs the BFSOS installer can set up the pacman pipeline
alongside (or instead of) the prt-get tooling during the package
transaction stage.

## 11.14 The scratchpkg Variant (.spkgbuild)

A third packaging front end exists as a **separate copy of the ports tree**,
adapted for **scratchpkg** — the package manager from Venom Linux (`scratch`,
`pkgbuild`, `pkgadd`, `pkgdel`, `portsync`). It lives on the `scratchpkg`
branch of this repository; the base-system bootstrap and the installer remain
on the pkgutils line there, and scratchpkg owns the ports tree.

### What changed in the copy

| | pkgutils / CRUX | scratchpkg copy |
|---|---|---|
| recipe file | `Pkgfile` | `.spkgbuild` |
| variables | CRUX arrays (`source=(a b)`) | scalar shell (`source="a b"`) |
| where `build()` runs | after `cd` into the extracted source dir | from `$SRC`; recipes call `bfs_enter_srcdir` |
| patches | applied automatically | recipes call `bfs_apply_patches` |
| no custom build steps | extension detects autotools/meson/cmake/make | recipes call `bfs_standard_build` |
| port names | any spelling (`libX11`) | lowercase, directory must equal `name` |

The CRUX build conventions live in one shared library,
`/usr/libexec/bfs/spkgbuild-lib.sh`, installed by the `scratchpkg` port; every
converted recipe sources it. `pre_build`, `post_build` and `bootstrap_build`
hooks are preserved, and `$PKG` still means the staging root, so the build steps
inside the recipes are unchanged.

### Why the recipes are named `.spkgbuild`

Upstream `pkgbuild` reads the recipe name from the shell variable
`PKGBUILD_BSCRIPT`, which it takes from `/etc/scratchpkg.conf` *after* its own
defaults. The `scratchpkg` port therefore ships a config that sets
`PKGBUILD_BSCRIPT=".spkgbuild"`, and the tree keeps the dotted name. Change that
one variable back to `spkgbuild` if you want upstream-style names.

### Using it

```bash
# build and install a port with its dependencies
cd /usr/ports/core/bzip2 && pkgbuild -i
scratch install gimp
scratch search compress
scratch sysup
portsync

# build a whole collection (or the whole tree)
sudo scripts/bfs-spkgbuild-all.sh -c core -j4
```

Packages are written to `/var/cache/scratchpkg/packages` as
`<name>-<version>-<release>.spkg.tar.zst` and tracked in
`/var/lib/scratchpkg/db`. `/etc/scratchpkg.repo` lists the collections that make
up the repositories — on this tree, one line per `ports/*` collection.

### Converting and validating this copy

The conversion is scripted so the copy can be re-derived from a CRUX tree at
any time:

```bash
python3 scripts/bfs-ports-to-spkgbuild.py --write              # Pkgfile -> .spkgbuild
python3 scripts/bfs-ports-to-spkgbuild.py --lowercase-names --write
python3 scripts/bfs-ports-to-spkgbuild.py --fix-deps --write
python3 scripts/bfs-ports-to-spkgbuild.py --check              # validate
find ports -name '.spkgbuild' -print0 | xargs -0 -n1 sh -n     # shell syntax
```

`--check` enforces the same rules `pkgbuild` does — directory equals `name`,
lowercase names, a numeric `release` between 1 and 99, a `version` without `-`,
a non-empty description, a `build()` function — plus the tree's own conventions.
See `docs/SCRATCHPKG-VARIANT.md` for the full reference, including the known
gaps (a few `# depends` entries that are not ports, and `post_install()`
functions that scratchpkg does not call).
