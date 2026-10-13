# BFSOS maintained command-line entry points

The interactive menus remain the default user interface, but Bootstrap and the ISO builder also provide direct command-line entry points for repeatable maintainer workflows.

## Bootstrap

```text
./bootstrap.sh                     interactive menu
./bootstrap.sh 1                   build temporary toolchain
./bootstrap.sh 2                   build base with temporary toolchain
./bootstrap.sh 3                   rebuild base with final toolchain
./bootstrap.sh 4                   verify base
./bootstrap.sh 5                   create/compress base archive
./bootstrap.sh 6                   restore newest base archive
./bootstrap.sh 7                   restore newest toolchain archive
./bootstrap.sh 8                   chroot into BFSOS root
./bootstrap.sh 9                   launch installer
./bootstrap.sh full                run complete automated build through Stage 5
./bootstrap.sh resume-full         resume at first incomplete stage
./bootstrap.sh iso [ISO options]   launch ISO builder
./bootstrap.sh --help              full maintained usage
```

Invalid arguments fail instead of silently opening the menu.

## ISO builder

```text
scripts/bfs-build-iso.sh
scripts/bfs-build-iso.sh --local-base /path/to/BFSOS-base-0.9.0-x86_64.tar.zst
scripts/bfs-build-iso.sh --sourceforge-base
scripts/bfs-build-iso.sh --refresh-base
scripts/bfs-build-iso.sh --git-ref main
```

By default the builder prefers a verified current-release base from the maintained local archive area. Explicit SourceForge mode is useful for release-mirror validation. `--refresh-base` forces a new remote download.

## Rootfs archives (stage3)

The bootstrap creates `bfs-rootfs-<version>-<date>.tar.zst` during stage 5. To produce the same kind of archive on demand from an existing root filesystem — a snapshot before an upgrade, a clone of a tuned system, or a rootfs built by any other means:

```text
scripts/bfs-mkstage3.sh                          pack / -> ./bfs-stage3-<version>-<date>-<arch>.tar.zst
scripts/bfs-mkstage3.sh -o /var/tmp/bfs-stage3.tar.zst
scripts/bfs-mkstage3.sh -r /mnt/stormfs          pack a mounted target or chroot
scripts/bfs-mkstage3.sh -C xz -l 6                xz instead of zstd
scripts/bfs-mkstage3.sh -x './opt/*/src'          extra exclude, repeatable
scripts/bfs-mkstage3.sh --dry-run                 print the tar command, write nothing
```

Pseudo-filesystems (`/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/mnt`, `/media`), package caches, and ports work directories are always excluded; the finished archive is re-read to verify it, and the source root is never modified. Restore with `sudo tar --numeric-owner -xpf <archive> -C <target>`.

## Installer

```text
scripts/install-bfs-menu-current.sh
scripts/install-bfs-menu-current.sh --console-font 20
scripts/install-bfs-menu-current.sh --no-log
scripts/install-bfs-menu-current.sh --log-file /path/to/log
```

The installer currently remains menu-driven for destructive/storage decisions. Reusable non-secret configuration profiles can be saved/loaded from Installer Settings. A future fully non-interactive installation mode must require explicit storage/account policy rather than guessing destructive defaults.
