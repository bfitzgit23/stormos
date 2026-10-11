# BFSOS

**BFSOS** is a do-it-yourself Linux operating system: you build it from source code on your own machine, so every package is compiled for *your* hardware. It uses an LFS/MLFS-style bootstrap, CRUX `pkgutils`/ports for package builds, and `prt-get` for dependency-aware package management, with a choice of **systemd**, **OpenRC**, or **SysVinit** as the init system.

BFSOS is an x86_64 source-built Linux distribution maintained by Brian Madonna. It uses an LFS/MLFS-style bootstrap, CRUX `pkgutils`/ports for package builds, `prt-get` for dependency-aware package management, systemd, Dracut, GRUB, and a Dialog-based installer that supports both straightforward and layered storage layouts.

> **Current release:** 0.9.0. BFSOS is usable for development and testing, but the 1.0 release line is still under active validation. Keep backups when testing installer/storage changes on important systems.

---

## New to Linux? Start here

If you have never used Linux before — or you are coming from **Windows** or **macOS** — this section is for you. Read it once and the rest of this document will make much more sense.

### What is a "source-built" distribution?

Most Linux distros (Ubuntu, Fedora, Mint…) hand you pre-built programs that someone else compiled for a generic computer. BFSOS is different: you run one script, it downloads the *source code* (the human-readable instructions) for every package, and your CPU compiles each one. Think of it like cooking from fresh ingredients instead of buying frozen dinners.

**Why bother?**

- Your programs are optimized for exactly your machine.
- You decide exactly what is installed — no bloat, no telemetry, no surprises.
- You learn how Linux actually works, piece by piece.

**The trade-off:** building takes time (hours on the first run, much less afterwards for single packages). A fast desktop can build the base system in under an hour; an older laptop may take several.

### Your glossary — Windows/macOS terms translated

| On Windows/macOS you know… | On BFSOS it is… | What it does |
|---|---|---|
| Programs ("installed apps") | **Packages** | A package is one program plus its files, tracked so it can be updated or removed cleanly. |
| The Microsoft Store / Mac App Store | **gnome-software** (installed as the `gnome-software` port) | A graphical store. It shows **Flathub** apps (see below) *and* BFSOS native packages in one place. |
| `.exe` / `.msi` / `.dmg` installers | **Ports** | There is no "installer download". A *port* is a small recipe file (`Pkgfile`) that says where to fetch the source and how to build it. You never run random installers from the internet. |
| Windows Update / Software Update | `bfsos sync` + `bfsos upgrade` | Two commands update *everything* on the system. (The store's "Updates" button does the same thing graphically.) |
| The Terminal (macOS) / PowerShell | **a terminal** | The black window where you type commands. On Linux it is the *fast, precise* way to do things — and for BFSOS administration it is the normal way. Give it a chance; it is easier than it looks. |
| Services (`services.msc` / launchd) | **init system + services** | Background programs that start at boot (networking, Bluetooth, sound…). BFSOS lets you choose *which* init system manages them: **systemd**, **OpenRC**, or **SysVinit**. |
| C: drive / Macintosh HD | `/` (the root filesystem) | Linux mounts everything under one tree starting at `/`. Your second disk might "live" at `/mnt/windows`, for example. |
| Program Files | `/usr` | Installed software lives under `/usr` (and `/usr/local`). |
| Documents and Settings / Users | `/home/yourname` | Your personal files. Each user has a folder under `/home`. |
| Control Panel / System Settings | **GNOME Settings** or `rc-*` commands | Desktop settings are in the Settings app; system services are managed by your init system (see the init section below). |
| Task Manager | `htop` (terminal) or **System Monitor** (graphical) | See what is using your CPU and memory. |
| Device Manager | built into the kernel | Almost all hardware "just works" — drivers are part of Linux itself. No driver CDs/downloads ever. |

### Installing software: the two ways

**Way 1 — the store (easiest).** Open **Software** from the applications menu. It looks and feels like the app stores you already know:

- **Flathub apps** run in a security *sandbox* (see below) and work on any Linux distro. This is the closest experience to the macOS App Store.
- **Native BFSOS packages** are built from source on your machine. The store lists them through a local AppStream catalog that BFSOS generates from the ports tree with `prt-get`/`pkgutils` (see *How gnome-software sees native packages* below).

**Way 2 — the terminal (faster, more precise).** Three commands cover 95% of daily use:

```sh
bfsos sync              # refresh the ports tree + pacman repositories
bfsos install gimp      # install GIMP and everything it depends on, built from source
bfsos upgrade           # update every installed package
```

To remove: `bfsos remove gimp`. To search: `bfsos search photo`. BFSOS packages are pacman packages, just built from source in your local repository rather than pulled from Arch.

```sh
# The classic pkgutils commands remain available and are what the base
# system bootstrap itself uses:
ports -u                 # refresh the ports tree
prt-get depinst gimp     # install GIMP and everything it depends on
prt-get sysup            # update every installed package
```

To remove with prt-get: `prt-get rm gimp`. To search: `prt-get search photo`. To see what an update would do before doing it: `prt-get diff`.

### What is Flatpak and Flathub?

**Flatpak** is a way of packaging desktop applications so they carry their own libraries and run in a *sandbox* — a security fence that limits what the app can touch. **Flathub** is the huge public store for Flatpak apps (Spotify, Discord, Steam, Blender, OBS, LibreOffice, Zoom…).

BFSOS ships this out of the box:

- the **`flatpak`** port — the runtime and `flatpak` command;
- the **`flathub`** port — enables the Flathub repository automatically at install time, including its signing key;
- **`xdg-desktop-portal`** and friends — lets sandboxed apps open files, take screenshots, and use portals correctly;
- the **Flatpak plugin in gnome-software** — browse and install Flathub apps from the store.

Prefer the terminal?

```sh
flatpak search spotify          # find an app
flatpak install flathub com.spotify.Client
flatpak update                  # update all Flatpak apps
flatpak uninstall com.spotify.Client
```

**Native packages vs Flatpaks — which do I use?** Rule of thumb: big third-party desktop apps (Spotify, Discord, Steam) → Flatpak, because they update themselves from Flathub and never fight with your system libraries. System tools, CLI tools, and anything you want tuned for your machine → native BFSOS packages, because they are compiled from source with your settings.

### Switching from Windows specifically?

- **No antivirus needed** in the way you are used to. Linux software is installed from signed, curated repositories — not random `.exe` downloads — and Flatpaks are sandboxed. Keep the system updated (`prt-get sysup`) and you are covered.
- **NTFS and dual-boot work.** BFSOS reads and writes Windows NTFS drives, so your second SSD with Windows 11 is visible from Linux and your BFSOS disk is visible from Windows (with a WSL2 or ext4 driver). Install each OS on its own drive and let the boot menu (GRUB) pick between them.
- **Office files:** LibreOffice (Flatpak or native) opens Word/Excel/PowerPoint files. OnlyOffice from Flathub is closest to the Microsoft look.
- **Games:** Steam is available on Flathub; Proton runs most Windows games.

### Switching from macOS specifically?

- **Trackpad and gestures** work well on GNOME; you can enable *natural scrolling* in Settings.
- **Time Machine ≈ Déjà Dup or Timeshift** (Flatpak) for backups; BFSOS's installer can also set up Btrfs snapshots.
- **Spotlight ≈** press `Super` (the ⌘-position key) and just start typing.
- **DMG apps ≈** Flathub apps. The sandbox model will feel familiar.
- The `Super` key is your ⌘/Windows key. `Ctrl+C`/`Ctrl+V` work as copy/paste in terminals the way you'd hope (and `Ctrl+Shift+C/V` too).

### Your first hour on BFSOS

1. **Update everything** — `bfsos sync && bfsos upgrade`.
2. **Open the store** — install a couple of apps from Flathub and watch them appear in the menu.
3. **Learn the lay of the land** — your files are in `/home/you`; system files are under `/etc` (settings) and `/usr` (software).
4. **Don't fear breakage** — worst case you reinstall from the installer ISO; keep personal files in `/home` and they survive reinstalls.
5. **When stuck, read the man page** — `man bfsos`, `man pacman`, `man flatpak`. Every command's manual is one command away.

### Choosing your init system (systemd, OpenRC, or SysVinit)

The **init system** is the first program that starts when you power on; it starts every service (network, Bluetooth, sound) in the right order. BFSOS supports all three major ones and builds whichever you select:

| | **systemd** (default) | **OpenRC** | **SysVinit** |
|---|---|---|---|
| Feel | Modern, all-in-one | Classic, light, fast | Minimalist, old-school Unix |
| Enable a service | `systemctl enable foo` | `rc-update add foo default` | edit `/etc/rc.conf` + symlinks |
| Start/stop now | `systemctl start foo` | `rc-service foo start` | `/etc/rc.d/foo start` |
| View logs | `journalctl` | plain logs in `/var/log` | plain logs in `/var/log` |
| Good for | Desktops, snap-in features | Servers, minimalists, LFS purists | Learning, tiny systems |

Pick it at bootstrap time (interactive prompt) or non-interactively:

```sh
scripts/select-init-profile.sh openrc    # or systemd | sysvinit
./bootstrap.sh 2
# or without the helper:
BFS_INIT_SYSTEM=sysvinit ./bootstrap.sh 2
```

Each profile pulls in the matching service packages and dependency set automatically (see `profiles/init/`), and the selected profile is applied to the ports tree during bootstrap — non-selected init integration is simply not installed.

---

## Core design
---

## New to Linux? Start here

If you have never used Linux before — or you are coming from **Windows** or **macOS** — this section is for you. Read it once and the rest of this document will make much more sense.

### What is a "source-built" distribution?

Most Linux distros (Ubuntu, Fedora, Mint…) hand you pre-built programs that someone else compiled for a generic computer. BFSOS is different: you run one script, it downloads the *source code* (the human-readable instructions) for every package, and your CPU compiles each one. Think of it like cooking from fresh ingredients instead of buying frozen dinners.

**Why bother?**

- Your programs are optimized for exactly your machine.
- You decide exactly what is installed — no bloat, no telemetry, no surprises.
- You learn how Linux actually works, piece by piece.

**The trade-off:** building takes time (hours on the first run, much less afterwards for single packages). A fast desktop can build the base system in under an hour; an older laptop may take several.

### Your glossary — Windows/macOS terms translated

| On Windows/macOS you know… | On BFSOS it is… | What it does |
|---|---|---|
| Programs ("installed apps") | **Packages** | A package is one program plus its files, tracked so it can be updated or removed cleanly. |
| The Microsoft Store / Mac App Store | **gnome-software** (installed as the `gnome-software` port) | A graphical store. It shows **Flathub** apps (see below) *and* BFSOS native packages in one place. |
| `.exe` / `.msi` / `.dmg` installers | **Ports** | There is no "installer download". A *port* is a small recipe file (`Pkgfile`) that says where to fetch the source and how to build it. You never run random installers from the internet. |
| Windows Update / Software Update | `bfsos sync` + `bfsos upgrade` | Two commands update *everything* on the system. (The store's "Updates" button does the same thing graphically.) |
| The Terminal (macOS) / PowerShell | **a terminal** | The black window where you type commands. On Linux it is the *fast, precise* way to do things — and for BFSOS administration it is the normal way. Give it a chance; it is easier than it looks. |
| Services (`services.msc` / launchd) | **init system + services** | Background programs that start at boot (networking, Bluetooth, sound…). BFSOS lets you choose *which* init system manages them: **systemd**, **OpenRC**, or **SysVinit**. |
| C: drive / Macintosh HD | `/` (the root filesystem) | Linux mounts everything under one tree starting at `/`. Your second disk might "live" at `/mnt/windows`, for example. |
| Program Files | `/usr` | Installed software lives under `/usr` (and `/usr/local`). |
| Documents and Settings / Users | `/home/yourname` | Your personal files. Each user has a folder under `/home`. |
| Control Panel / System Settings | **GNOME Settings** or `rc-*` commands | Desktop settings are in the Settings app; system services are managed by your init system (see the init section below). |
| Task Manager | `htop` (terminal) or **System Monitor** (graphical) | See what is using your CPU and memory. |
| Device Manager | built into the kernel | Almost all hardware "just works" — drivers are part of Linux itself. No driver CDs/downloads ever. |

### Installing software: the two ways

**Way 1 — the store (easiest).** Open **Software** from the applications menu. It looks and feels like the app stores you already know:

- **Flathub apps** run in a security *sandbox* (see below) and work on any Linux distro. This is the closest experience to the macOS App Store.
- **Native BFSOS packages** are built from source on your machine. The store lists them through a local AppStream catalog that BFSOS generates from the ports tree with `prt-get`/`pkgutils` (see *How gnome-software sees native packages* below).

**Way 2 — the terminal (faster, more precise).** Three commands cover 95% of daily use:

```sh
bfsos sync              # refresh the ports tree + pacman repositories
bfsos install gimp      # install GIMP and everything it depends on, built from source
bfsos upgrade           # update every installed package
```

To remove: `bfsos remove gimp`. To search: `bfsos search photo`. BFSOS packages are pacman packages, just built from source in your local repository rather than pulled from Arch.

```sh
# The classic pkgutils commands remain available and are what the base
# system bootstrap itself uses:
ports -u                 # refresh the ports tree
prt-get depinst gimp     # install GIMP and everything it depends on
prt-get sysup            # update every installed package
```

To remove with prt-get: `prt-get rm gimp`. To search: `prt-get search photo`. To see what an update would do before doing it: `prt-get diff`.

### What is Flatpak and Flathub?

**Flatpak** is a way of packaging desktop applications so they carry their own libraries and run in a *sandbox* — a security fence that limits what the app can touch. **Flathub** is the huge public store for Flatpak apps (Spotify, Discord, Steam, Blender, OBS, LibreOffice, Zoom…).

BFSOS ships this out of the box:

- the **`flatpak`** port — the runtime and `flatpak` command;
- the **`flathub`** port — enables the Flathub repository automatically at install time, including its signing key;
- **`xdg-desktop-portal`** and friends — lets sandboxed apps open files, take screenshots, and use portals correctly;
- the **Flatpak plugin in gnome-software** — browse and install Flathub apps from the store.

Prefer the terminal?

```sh
flatpak search spotify          # find an app
flatpak install flathub com.spotify.Client
flatpak update                  # update all Flatpak apps
flatpak uninstall com.spotify.Client
```

**Native packages vs Flatpaks — which do I use?** Rule of thumb: big third-party desktop apps (Spotify, Discord, Steam) → Flatpak, because they update themselves from Flathub and never fight with your system libraries. System tools, CLI tools, and anything you want tuned for your machine → native BFSOS packages, because they are compiled from source with your settings.

### Switching from Windows specifically?

- **No antivirus needed** in the way you are used to. Linux software is installed from signed, curated repositories — not random `.exe` downloads — and Flatpaks are sandboxed. Keep the system updated (`prt-get sysup`) and you are covered.
- **NTFS and dual-boot work.** BFSOS reads and writes Windows NTFS drives, so your second SSD with Windows 11 is visible from Linux and your BFSOS disk is visible from Windows (with a WSL2 or ext4 driver). Install each OS on its own drive and let the boot menu (GRUB) pick between them.
- **Office files:** LibreOffice (Flatpak or native) opens Word/Excel/PowerPoint files. OnlyOffice from Flathub is closest to the Microsoft look.
- **Games:** Steam is available on Flathub; Proton runs most Windows games.

### Switching from macOS specifically?

- **Trackpad and gestures** work well on GNOME; you can enable *natural scrolling* in Settings.
- **Time Machine ≈ Déjà Dup or Timeshift** (Flatpak) for backups; BFSOS's installer can also set up Btrfs snapshots.
- **Spotlight ≈** press `Super` (the ⌘-position key) and just start typing.
- **DMG apps ≈** Flathub apps. The sandbox model will feel familiar.
- The `Super` key is your ⌘/Windows key. `Ctrl+C`/`Ctrl+V` work as copy/paste in terminals the way you'd hope (and `Ctrl+Shift+C/V` too).

### Your first hour on BFSOS

1. **Update everything** — `bfsos sync && bfsos upgrade`.
2. **Open the store** — install a couple of apps from Flathub and watch them appear in the menu.
3. **Learn the lay of the land** — your files are in `/home/you`; system files are under `/etc` (settings) and `/usr` (software).
4. **Don't fear breakage** — worst case you reinstall from the installer ISO; keep personal files in `/home` and they survive reinstalls.
5. **When stuck, read the man page** — `man bfsos`, `man pacman`, `man flatpak`. Every command's manual is one command away.

### Choosing your init system (systemd, OpenRC, or SysVinit)

The **init system** is the first program that starts when you power on; it starts every service (network, Bluetooth, sound) in the right order. BFSOS supports all three major ones and builds whichever you select:

| | **systemd** (default) | **OpenRC** | **SysVinit** |
|---|---|---|---|
| Feel | Modern, all-in-one | Classic, light, fast | Minimalist, old-school Unix |
| Enable a service | `systemctl enable foo` | `rc-update add foo default` | edit `/etc/rc.conf` + symlinks |
| Start/stop now | `systemctl start foo` | `rc-service foo start` | `/etc/rc.d/foo start` |
| View logs | `journalctl` | plain logs in `/var/log` | plain logs in `/var/log` |
| Good for | Desktops, snap-in features | Servers, minimalists, LFS purists | Learning, tiny systems |

Pick it at bootstrap time (interactive prompt) or non-interactively:

```sh
scripts/select-init-profile.sh openrc    # or systemd | sysvinit
./bootstrap.sh 2
# or without the helper:
BFS_INIT_SYSTEM=sysvinit ./bootstrap.sh 2
```

Each profile pulls in the matching service packages and dependency set automatically (see `profiles/init/`), and the selected profile is applied to the ports tree during bootstrap — non-selected init integration is simply not installed.

---

## Core design
## Highlights

- Source-built temporary toolchain and base system.
- Optional final-toolchain rebuild to verify that the base can rebuild itself.
- CRUX-style ports and `pkgutils`, extended for BFSOS build conventions.
- `prt-get` dependency management and Git-backed ports synchronization.
- Post-install **pacman-format pipeline** (`bfs-build`, `bfs-deps`, `bfsos`, `pacman`): the same source-built ports emit pacman-compatible packages into a local repository, and `bfsos install/upgrade` is the supported day-to-day front end.
- x86_64 multilib support with 32-bit libraries under `/usr/lib32`.
- Init-system choice per build: **systemd** (default), **OpenRC**, or **SysVinit**.
- Dracut initramfs generation and GRUB bootloader support.
- UEFI and legacy BIOS installation paths.
- Installer support for Btrfs subvolumes/snapshots, LUKS, LVM, md RAID (linear/JBOD, RAID0, RAID1, RAID10, RAID4/5/6), and combinations of those layers.
- Kernel selection between the current BFSOS kernel and a broad-support Linux 6.12 LTS flavor carrying the Debian 6.12 patch series.
- Optional installer-managed ZRAM swap with explicit enable/disable and configurable sizing.
- Flatpak/Flathub support in the ports tree, integrated with gnome-software.

## Repository layout

- `bootstrap.sh` — authoritative BFSOS bootstrap menu and build stages.
- `ports/` — package recipes. `ports/core` is the release-critical base collection; other collections are broader and may receive cleanup independently of the 1.0 core release.
- `profiles/init/` — per-init-system package manifests, audit data, and generated ports overlays.
- `scripts/install-bfs-menu-*.sh` — installer revisions; use the newest validated revision.
- `scripts/` — maintenance, migration, ports, and repository helpers.
- `archives/` — generated toolchain/base archives (normally excluded from Git).
- `logs/` — bootstrap/installer logs (normally excluded from release source archives).
- Init-system choice per build: **systemd** (default), **OpenRC**, or **SysVinit**.
- Dracut initramfs generation and GRUB bootloader support.
- UEFI and legacy BIOS installation paths.
- Installer support for Btrfs subvolumes/snapshots, LUKS, LVM, md RAID (linear/JBOD, RAID0, RAID1, RAID10, RAID4/5/6), and combinations of those layers.
- Kernel selection between the current BFSOS kernel and a broad-support Linux 6.12 LTS flavor carrying the Debian 6.12 patch series.
- Optional installer-managed ZRAM swap with explicit enable/disable and configurable sizing.
- Flatpak/Flathub support in the ports tree, integrated with gnome-software.

## Repository layout

- `bootstrap.sh` — authoritative BFSOS bootstrap menu and build stages.
- `ports/` — package recipes. `ports/core` is the release-critical base collection; other collections are broader and may receive cleanup independently of the 1.0 core release.
- `profiles/init/` — per-init-system package manifests, audit data, and generated ports overlays.
- `scripts/install-bfs-menu-*.sh` — installer revisions; use the newest validated revision.
- `scripts/` — maintenance, migration, ports, and repository helpers.
- `archives/` — generated toolchain/base archives (normally excluded from Git).
- `logs/` — bootstrap/installer logs (normally excluded from release source archives).
- systemd with an explicit BFSOS service preset policy.
- Dracut initramfs generation and GRUB bootloader support.
- UEFI and legacy BIOS installation paths.
- Installer support for Btrfs subvolumes/snapshots, LUKS, LVM, md RAID, and layered combinations.
- Kernel selection between the default Linux **6.18.54 LTS** package and the optional **7.2.8** current kernel.
- Optional installer-managed ZRAM swap.
- Console-font choices on live media and the installed system for improved readability.
- SourceForge-hosted release/base artifacts with versioned checksums.

## Repository and releases

The authoritative source repository is:

```text
https://github.com/bmadonnaster/BFSOS
```

Issues and support:

```text
https://github.com/bmadonnaster/BFSOS/issues
```

Large base archives and public ISO releases are hosted through the BFSOS SourceForge project. SourceForge remains the release-artifact host; GitHub is the source-control host.

## Repository layout

- `bootstrap.sh` — authoritative bootstrap menu, direct stage commands, full bootstrap, and ISO/installer handoff.
- `ports/` — maintained package recipes and desktop/compatibility collections.
- `scripts/install-bfs-menu-current.sh` — canonical installer.
- `scripts/bfs-build-iso.sh` — canonical live ISO builder.
- `scripts/bfs-publish-sourceforge.sh` — canonical SourceForge publisher.
- `scripts/tests/` — source/regression checks.
- `docs/` — installation, audit, tracker, and maintenance documentation.
- `files/` — shared BFSOS build/runtime support files.
- `archives/` — generated toolchain/base archives when present locally (normally not tracked).
- `logs/` — local build/install logs (normally not part of release source archives).

Historical tracker documents are kept under `docs/`; Git history is the rollback mechanism for obsolete script revisions.

## Getting started

```sh
git clone https://github.com/bfitzgit23/StormFS-Linux.git
cd StormFS-Linux
git clone https://github.com/bfitzgit23/StormFS-Linux.git
cd StormFS-Linux
git clone https://github.com/bmadonnaster/BFSOS.git
cd BFSOS
./bootstrap.sh
```

The no-argument command opens the interactive bootstrap menu. A full automated bootstrap can be started directly with:

```sh
./bootstrap.sh full
```

Individual stages can also be invoked directly:

```sh
./bootstrap.sh 1
./bootstrap.sh 2
./bootstrap.sh 3
./bootstrap.sh 4
./bootstrap.sh 5
```

See `docs/COMMAND-LINE.md` for the maintained script entry points and `docs/INSTALL.md` for the installer workflow.

> **Upstream note:** BFSOS's packaging baseline is imported from Brian Madonna's BFSOS at <https://codeberg.org/bmadonnaster/BFSOS>. This repository carries that baseline plus the StormFS-specific ports, init-selection layer, and documentation.

## Bootstrap stages

The normal build path is:

1. **Build temporary toolchain** — required.
2. **Build base system with temporary toolchain** — required.
3. **Rebuild base with the final toolchain** — optional validation stage.
4. **Verify completed base system** — required before archiving.
5. **Create/compress and verify the base rootfs archive** — required for installer/ISO reuse.
6. Restore the newest base rootfs archive.
7. Restore the newest temporary-toolchain archive.
8. Chroot into the built/restored BFSOS rootfs.
9. Launch the BFSOS installer.

Generated bootstrap archives use zstd compression and carry BFSOS version/build identity.

## Installer and storage

The installer can build simple layouts or layered storage such as:

```text
md RAID -> LUKS -> LVM -> Btrfs subvolumes
```

It supports filesystem/mount-point assignment, ZRAM, users/groups, networking, console/font settings, kernel selection, sudo policy, GRUB/UEFI configuration, a complete pre-install review, and a post-install choice to enter the target through chroot or finish/unmount cleanly.

Storage operations can destroy data. Review the filesystem plan and final installation review before starting an install. Test unfamiliar RAID/LUKS/LVM combinations in a VM first.

## Package management

Update ports and installed packages with:

```sh
ports -u
prt-get sysup
```

Install a package and its dependencies with:

```sh
prt-get depinst <package>
```

Build a single port manually the way pkgutils does it:

```sh
cd /usr/ports/opt/flatpak && pkgmk -d && pkgadd flatpak#*.pkg.tar.zst
```

BFSOS uses `python3` as the Python 3 package name; Python module ports use the `python3-*` naming convention.

### Package-management roles

- `pkgutils` provides low-level package tools including `pkgmk` and `pkgadd`.
- `ports` provides `ports -u` synchronization and repository drivers.
- `prt-get` is the dependency-aware frontend used for `depinst`, `sysup`, and related operations.
- `prt-utils` provides maintenance helpers such as `revdep`.

BFSOS-maintained collections use the Git-backed monorepo definition `/etc/ports/bfsos.git`.
### Software stores and Flathub

- Install **`gnome-software`** (`prt-get depinst gnome-software`) for a graphical store covering both native BFSOS packages and Flatpak applications.
- The **`flathub`** port registers the Flathub remote automatically (`flatpak remote-add --if-not-exists`); it is idempotent and safe across upgrades.
- After installing native packages that ship desktop apps, refresh the store's native catalog with `bfsos-appstream` (installed by the `gnome-software` port).

## Init profiles

Init-system selection is described in the newbie section above; the technical reference follows.

The bootstrap supports one selected init system per build:

- `systemd` — the upstream default;
- `openrc` — OpenRC plus SysVinit compatibility and BFSOS OpenRC service scripts;
- `sysvinit` — SysVinit plus the LFS boot scripts.

Select interactively or non-interactively before building:

```sh
scripts/select-init-profile.sh
scripts/select-init-profile.sh openrc
BFS_INIT_SYSTEM=openrc ./bootstrap.sh 2
```

The selection is stored in `.bfs-init-profile` and is consumed by the bootstrap's base package transaction. Profile package manifests live under `profiles/init/`; audit data is recorded in `profiles/init/systemd-audit.tsv`, and generated per-profile port overlays live under `profiles/init/overlays/<profile>/`.

All three init packages are kept as separate ports. Service implementations are not removed from packages merely because another profile is selected; profile-specific service packages install only the selected init integration, and the bootstrap applies the selected overlay after copying the ports tree into the target rootfs.
### Package-management roles

- `pkgutils` provides low-level package tools including `pkgmk` and `pkgadd`.
- `ports` provides `ports -u` synchronization and repository drivers.
- `prt-get` is the dependency-aware frontend used for `depinst`, `sysup`, and related operations.
- `prt-utils` provides maintenance helpers such as `revdep`.

BFSOS-maintained collections use the Git-backed monorepo definition `/etc/ports/bfsos.git`.

## Logs and bug reports

Bootstrap logs are written under the project's `logs/` hierarchy when enabled. Installer logs are copied into the installed system under `/var/log/bfs/installer/`.

When reporting a problem, include the failing stage/package, relevant log, storage topology where applicable, kernel/initramfs version, and whether the problem occurred in a VM or on bare metal.

## Current limitations

- Not every hardware/storage combination has been validated.
- Non-core ports can lag or need repair independently of the release-critical base.
- Reusable installer profiles intentionally do not persist passwords or LUKS passphrases.
- GRUB is the currently validated bootloader path; alternative bootloaders remain future work.

## License

See `LICENSE` and the licenses of the individual upstream packages/sources.
Issues and support: open an issue in this repository's tracker.

## Current limitations

- BFSOS remains under active 1.0 RC validation; not every hardware/storage combination has been tested.
- The non-core ports collection may contain stale or broken recipes even when the core system is release-ready.
- Installer configuration-profile support is partial; secrets such as passwords and LUKS passphrases are never stored.
- Alternative bootloaders such as Limine are a future enhancement; GRUB is the currently validated bootloader path.
- The gnome-software native-package integration is catalog-based (AppStream XML generated from the ports tree); deep PackageKit-style transactional native package management from the GUI is future work.
When reporting a problem, include the failing stage/package, relevant log, storage topology where applicable, kernel/initramfs version, and whether the problem occurred in a VM or on bare metal.

## Current limitations

- Not every hardware/storage combination has been validated.
- Non-core ports can lag or need repair independently of the release-critical base.
- Reusable installer profiles intentionally do not persist passwords or LUKS passphrases.
- GRUB is the currently validated bootloader path; alternative bootloaders remain future work.

## License

See `LICENSE` and the licenses of the individual upstream packages/sources.
