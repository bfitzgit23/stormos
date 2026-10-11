# Chapter 2: Installation

## Installing OpenRC

### Using the StormFS Port

OpenRC is available as a port in the StormFS Linux repository:

```bash
# Install OpenRC (recommended: the pacman-style front end)
bfsos install openrc

# Equivalent classic pkgutils invocation
bfsos install openrc

# Install init scripts for common services
bfsos install openrc-init-scripts
```

### Building from Source

To build OpenRC from source, following the MLFS OpenRC book:

```bash
# Download the latest stable version and the lock patch
wget https://github.com/OpenRC/openrc/archive/refs/tags/0.63.tar.gz
wget https://www.linuxfromscratch.org/glfs/view/dev/download/openrc/openrc-0.63-lock-1.patch
tar xf 0.63.tar.gz
cd openrc-0.63

# Make the group which manages /run/lock configurable
patch -Np1 -i ../openrc-0.63-lock-1.patch

# Fix a script to allow a normal installation
sed -i '/set -u/d' tools/meson_final.sh

# Prepare OpenRC for compilation
mkdir build
cd    build

meson setup --prefix=/usr       \
            --sysconfdir=/etc   \
            --buildtype=release \
            -D uucp_group=root  \
            -D pam=false ..

ninja
sudo ninja install
```

The meaning of the meson options:

- `-D uucp_group=root`: changes who owns and manages `/run/lock`, as OpenRC
  will try to use the `uucp` group to manage it. Many distributions today use
  the `lock` group, but LFS uses `root` instead.
- `-D pam=false`: disables needing Linux-PAM for the build.

### Post-Installation Setup

After installing OpenRC, you need to:

1. Move `rc-update` into `/usr/bin` so normal users can run it
2. Create the shorthand symlinks for `init` and `shutdown`
3. Create the `poweroff` and `reboot` wrappers
4. Add services to runlevels (see [Chapter 4: Runlevels](chapters/04-runlevels.md))

```bash
# rc-update is meant to be runnable by normal users as well
mv -v /sbin/rc-update /usr/bin/rc-update

# OpenRC provides init and other programs of its own; create the shorthands
for i in init shutdown; do
  ln -svf openrc-$i /sbin/$i
done

cat > /sbin/poweroff << "EOF"
#!/bin/sh
/sbin/shutdown --poweroff now
EOF

cat > /sbin/reboot << "EOF"
#!/bin/sh
/sbin/shutdown --reboot now
EOF

chmod 755 /sbin/poweroff /sbin/reboot
```

## Directory Structure

After installation, the following directories should exist:

```
/etc/
├── init.d/              # Service scripts
├── conf.d/              # Service configuration
├── runlevels/           # Runlevel directories
├── local.d/             # Local boot scripts
└── sysctl.d/            # Sysctl configuration snippets

/usr/
├── libexec/rc/          # OpenRC core files
│   ├── bin/             # OpenRC binaries
│   ├── sh/              # OpenRC shell functions
│   └── scripts/         # OpenRC scripts
└── share/openrc/        # OpenRC data files
```

## Verifying Installation

Check that OpenRC is installed correctly:

```bash
# Check OpenRC version
openrc --version

# Check available services
ls /etc/init.d/

# Check runlevels
ls /etc/runlevels/

# Confirm the package is known to pacman (BFSOS installs packages as
# pacman-compatible archives when using the bfsos pipeline)
bfsos native -Qi openrc
```

## Pacman and the bfsos pipeline

StormFS packages are *pacman packages built from source*. The `core/pacman`
port installs the pacman package manager together with a local `bfsos`
repository configuration (`/etc/pacman.conf` + `/etc/pacman.d/mirrorlist`
pointing at `file:///var/cache/repo/bfsos` by default). Day-to-day you use
the `bfsos` wrapper, which resolves dependencies from the ports tree with
`bfs-deps`, builds missing ports with `bfs-build`, and installs the
resulting archives through pacman:

```bash
bfsos sync                # ports -u + pacman -Sy
bfsos install openrc      # resolve, build from source, install via pacman
bfsos upgrade             # pacman -Su over the local repository
```

Prefer pacman directly? Everything pacman does works: `pacman -U` a
hand-built `*.pkg.tar.*`, `pacman -Qi`/`-Ql` to inspect, `repo-add` to
publish rebuilt packages for other machines. The only difference from
Arch: the archives come from *your* source builds in your local repo, not
from Arch's binary repositories (mixing Arch's ABI with BFSOS source
builds is unsupported — see the LFS book, chapter 11, § 11.13).

## Next Steps

After installation, proceed to [Chapter 3: Configuration](chapters/03-configuration.md) to configure OpenRC for your system.
