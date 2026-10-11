# Chapter 29: BLFS Package Mappings

## Scope

This chapter maps the service-bearing BLFS packages in the StormFS ports tree to their OpenRC integration. OpenRC is the default service path. Existing systemd units and migration procedures remain available as compatibility reference, but they are not required for the OpenRC profile.

Status values mean:

- **Ready:** the port and the shared `openrc-init-scripts` package provide the OpenRC path.
- **Flag required:** build the port with the listed OpenRC option before installing it.
- **Recipe work:** the port still declares or enables systemd integration and should be adjusted before it is considered OpenRC-native.
- **User session:** do not add the application to a system runlevel; start it from the logged-in desktop session.

## Base Services

| BLFS package | Port | OpenRC service or activation | OpenRC mapping | Status |
|--------------|------|------------------------------|----------------|--------|
| OpenRC | `openrc` | `openrc-init` and runlevels | Install the runtime and create `sysinit`, `boot`, `default`, `single`, and `nonetwork` runlevels. | Ready |
| StormFS service wrappers | `openrc-init-scripts` | `/etc/init.d/*` | Installs the shared service scripts listed in Chapter 14. | Ready |
| D-Bus | `dbus` | `dbus` | Enable in `boot`; desktop daemons use the system bus. | Ready |
| eudev | `eudev` | `udev`, `udev-postmount` | Enable both in `sysinit`, in that order. | Ready |
| ConsoleKit2 | `consolekit2` | D-Bus activation | Provides session and seat tracking without a systemd unit. Do not add it to a runlevel. | Ready |
| Sysklogd | `sysklogd` | `syslog` | Install the wrapper and enable `syslog` in `boot`. Do not run two syslog daemons. | Ready |
| Cronie | `cronie` | `crond` | Use the wrapper supplied by `openrc-init-scripts`; timers become cron entries. | Ready |

## Networking and Security

| BLFS package | Port | OpenRC service | OpenRC build or configuration | Status |
|--------------|------|----------------|------------------------------|--------|
| NetworkManager | `networkmanager` | `networkmanager` | Build with `-D session_tracking=none`, `-D systemdsystemunitdir=no`, and `-D systemd_journal=false`; enable only this network manager for interfaces it controls. | Ready |
| dhcpcd | `dhcpcd` | `dhcpcd` | The port uses the shared OpenRC wrapper; do not run it against the same interface as NetworkManager. | Ready |
| iwd | `iwd` | `iwd` | Build with `--disable-systemd-service`; choose it instead of `wpa_supplicant` for Wi-Fi authentication. | Ready |
| wpa_supplicant | `wpa_supplicant` | `wpa_supplicant` | The port installs D-Bus integration and `/etc/wpa_supplicant/wpa_supplicant.conf`; the OpenRC wrapper supplies the service. Enable only one Wi-Fi manager. | Ready |
| ACPID | `acpid` | `acpid` | The port installs ACPI event rules and uses the shared foreground OpenRC wrapper. | Ready |
| GPM | `gpm` | `gpm` | The port installs console mouse support and relies on the shared OpenRC wrapper; no init-system unit is generated. | Ready |
| openresolv | `openresolv` | resolver integration | Use `/run/resolvconf/resolv.conf`; it is not a daemon and has no `rc-update` entry. | Ready |
| nftables | `nftables` | `nftables` | Install `/etc/nftables.nft` and enable the service in `boot`, before normal network services. | Ready |
| OpenSSH | `openssh` | `sshd` | The port can retain its systemd unit; the OpenRC wrapper runs `sshd -D` under OpenRC supervision. | Ready |
| OpenVPN | `openvpn` | site-specific | Build with `--disable-systemd`; create one OpenRC instance per configured tunnel if persistent tunnels are required. | Flag required |

## Desktop Services

| BLFS package | Port | OpenRC service or activation | OpenRC mapping | Status |
|--------------|------|------------------------------|----------------|--------|
| LightDM | `lightdm` | `lightdm` | Provides the `xdm` virtual; enable one display manager in `default`. | Ready |
| SDDM | `sddm` | `sddm` | Provides the `xdm` virtual; enable it instead of LightDM, LXDM, or GDM. | Ready |
| LXDM | `lxdm` | `lxdm` | Build with `--with-systemdsystemunitdir=no`; provides the `xdm` virtual. | Flag required |
| GDM | `gdm` | `gdm` | Enable after `dbus`; GDM starts the user session and is not a replacement for session services. | Ready |
| PolicyKit | `polkit` | `polkitd` | Build with `-D session_tracking=ConsoleKit` and `-D systemdsystemunitdir=no`; the shared wrapper starts the D-Bus daemon. | Ready |
| AccountsService | `accountsservice` | `accounts-daemon` | It is D-Bus activated; the OpenRC variant removes the hard `systemd` dependency and installs the daemon under `/usr/lib`. | Ready |
| UPower | `upower` | `upowerd` | D-Bus service used by desktop power tools; enable the wrapper only when a system daemon is needed. | Ready |
| UDisks2 | `udisks2` | `udisks2` | Requires D-Bus and PolicyKit; enable in `default` when desktop disk management is used. | Ready |
| colord | `colord` | `colord` | Build with `-D systemd=false` and use the D-Bus service with the OpenRC wrapper. | Ready |
| Avahi | `avahi` | `avahi-daemon`, `avahi-dnsconfd` | Enable the daemon first; enable the DNS configuration helper only when it is needed. | Ready |

## Audio and Desktop Sessions

| BLFS package | Port | OpenRC service or activation | OpenRC mapping | Status |
|--------------|------|------------------------------|----------------|--------|
| ALSA utilities | `alsa-utils` | `alsa` | Restore in `boot` and save at shutdown. | Ready |
| PulseAudio | `pulseaudio` | `pulseaudio` | The wrapper is system-wide. Desktops should prefer per-user PulseAudio or PipeWire. | Ready |
| PipeWire | `pipewire` | `pipewire` | Build with `-D session-managers=[]` and `-D systemd=disabled`; use the system wrapper only for an explicitly system-wide daemon, otherwise launch it per user. | Ready |
| WirePlumber | `wireplumber` | user session | Build with `-D systemd=disabled`, `-D elogind=disabled`, and both systemd service options disabled. Start it from each user’s PipeWire session, not a root runlevel. | Ready / User session |
| libinput | `libinput` | udev rules | Build against eudev; the OpenRC port no longer has a hard `systemd` dependency. | Ready |
| GNOME session | `gnome-session` | GDM plus user session | The OpenRC port no longer has a hard `systemd` dependency; GDM starts GNOME Shell in the user session. | User session |
| GVfs | `gvfs` | D-Bus activation | The port no longer has a hard `systemd` dependency; use D-Bus, UDisks2, Avahi, and desktop session services as needed. | Ready |
| XFCE, KDE Plasma, LXQt components | `xfce`, `plasma`, `lxqt` ports | user session | Do not create root-owned OpenRC services for panels, shells, PowerDevil, Tracker, or session managers. Use the display manager and desktop autostart. | User session |

## Storage, Monitoring, and Remote Access

| BLFS package | Port | OpenRC service | OpenRC mapping | Status |
|--------------|------|----------------|----------------|--------|
| LVM2 | `lvm2` | `lvm2-monitor` | Build with `--disable-systemd`; the OpenRC wrapper runs `vgchange --monitor y` and disables monitoring on stop. | Ready |
| smartmontools | `smartmontools` | `smartd` | Enable in `default`; configure `/etc/smartd.conf` before starting. | Ready |
| rsync | `rsync` | `rsyncd` | Use `/etc/rsyncd.conf`; the OpenRC wrapper supervises `rsync --daemon --no-detach`. | Ready |
| RustDesk | `rustdesk-bin` | `rustdesk` | Enable only when unattended remote access is required. | Ready |
| AnyDesk | local or external package | `anydesk` | Install the vendor daemon and enable the wrapper only when its binary is present. | Recipe work |
| TeamViewer | local or external package | `teamviewer` | Verify `/opt/teamviewer/tv_bin/teamviewerd` exists before enabling. | Recipe work |
| VNC server | `tigervnc` | site-specific | Create a per-user OpenRC instance or use the desktop session; never run a graphical VNC session as root. | User session |

## OpenRC Build Checklist

Before installing a package in an OpenRC system:

```bash
# Check the port metadata and build options
bfsos info <package>

# Inspect systemd references in a recipe
grep -Rni systemd ports/<repo>/<package>

# Check the installed service names
ls -1 /etc/init.d/
rc-update show

# Check dependency ordering before starting a service
rc-depend -v <service>
```

For a desktop profile, install and enable the common base first:

```bash
bfsos install openrc openrc-init-scripts dbus eudev consolekit2 sysklogd
rc-update add udev sysinit
rc-update add udev-postmount sysinit
rc-update add dbus boot
rc-update add syslog boot
```

Then choose one network manager, one display manager, and one audio session model. Do not enable mutually exclusive alternatives together.

## Recipe Status Summary

The OpenRC service layer is ready for the core service packages and the adapted desktop, networking, storage, authorization, and multimedia recipes in this checkout. `lvm2`, `polkit`, `wireplumber`, `wpa_supplicant`, NetworkManager, GPM, ACPID, BlueZ, dhcpcd, iwd, and PipeWire now have OpenRC-specific recipe or service integration. WirePlumber remains a user-session component rather than a root-owned runlevel service. Systemd references remain documented where upstream compatibility material is retained.

## Next Steps

After mapping package integration, use [Chapter 14: System Services](chapters/14-system-services.md) for service commands and [Chapter 15: Troubleshooting](chapters/15-troubleshooting.md) when validating the running system.
