# Chapter 14: System Services

## Overview

This chapter covers configuring various system services with OpenRC. The service names below match the StormFS `openrc-init-scripts` port. Services that are D-Bus activated should have `dbus` enabled first; do not add every available service to a runlevel, only the services required by the installed system.

## StormFS OpenRC Service Matrix

| Function | Package | OpenRC service | Runlevel | Dependency notes |
|----------|---------|----------------|----------|------------------|
| Logging | `sysklogd` | `syslog` wrapper | `boot` | Requires `localmount` |
| Device management | `eudev` + `openrc-init-scripts` | `udev`, `udev-postmount` | `sysinit` | Start `udev-postmount` after `udev` |
| Message bus | `dbus` | `dbus` | `boot` | Required by most desktop daemons |
| DHCP | `dhcpcd` | `dhcpcd` | `default` | Coordinate with `networking` or NetworkManager |
| Wi-Fi | `iwd` | `iwd` | `default` | Uses D-Bus; do not run with conflicting Wi-Fi managers |
| Network manager | `networkmanager` | `networkmanager` | `default` | Requires `dbus`; use `session_tracking=none` |
| Time synchronization | `chrony` | `chronyd` | `boot` | Requires network |
| Cron jobs | `cronie` | `crond` | `boot` | Timers become cron entries |
| SSH server | `openssh` + scripts | `sshd` | `default` | Requires network and logger |
| Display manager | `lightdm`, `sddm`, `lxdm`, or `gdm` | matching name | `default` | Requires `dbus` and `xdm`; enable one only |
| Bluetooth | `bluez` + scripts | `bluez` | `default` | Requires `dbus` |
| Audio | `alsa-utils`, `pipewire`, or `pulseaudio` | matching script | `boot`/`default` | Prefer per-user audio for desktops |
| Storage | `udisks2` | `udisks2` | `default` | Requires `dbus` and PolicyKit |
| Authorization | `polkit` | `polkitd` | `default` | Requires `dbus` |
| Power policy | `upower` | `upowerd` | `default` | Requires `dbus` |
| ACPI events | `acpid` | `acpid` | `boot` | Requires local mounts and logger |
| Console mouse | `gpm` | `gpm` | `default` | Optional; uses `/dev/input/mice` |
| Disk health | `smartmontools` | `smartd` | `default` | Requires local mounts |
| mDNS | `avahi` | `avahi-daemon`, `avahi-dnsconfd` | `default` | Start Avahi before DNS configuration helper |
| Remote desktop | `rustdesk-bin`, `anydesk`, or `teamviewer` | matching name | `default` | Enable only the selected product |

Inspect the installed scripts before enabling a service:

```bash
ls -1 /etc/init.d/
rc-update show
rc-status --all
```

## Cron Service

### crond (Cronie)

Cronie provides cron functionality through the `crond` OpenRC service:

```bash
# Install cronie
bfsos install cronie

# Enable the service installed by the cronie port
sudo rc-update add crond boot

# Start crond
sudo rc-service crond start
```

### Adding Cron Jobs

```bash
# Edit user crontab
crontab -e

# Edit system crontab
sudo nano /etc/crontab
```

## Logging

### syslog (Sysklogd)

StormFS uses Sysklogd with the `syslog` OpenRC wrapper for the default logging path:

```bash
# Install the logger and its OpenRC wrapper
bfsos install sysklogd openrc-init-scripts
sudo rc-update add syslog boot

# Start syslog
sudo rc-service syslog start
```

An external `syslog-ng` port may be used instead, but do not run two syslog daemons at the same time:

```bash
bfsos install syslog-ng
sudo rc-update add syslog-ng boot
sudo rc-service syslog-ng start
```

### Configuration

Edit `/etc/syslog-ng/syslog-ng.conf`:

```bash
@version: 4.4

source s_sys {
    system();
    internal();
};

destination d_mesg { file("/var/log/messages"); };
destination d_auth { file("/var/log/auth.log"); };
destination d_syslog { file("/var/log/syslog"); };

log { source(s_sys); destination(d_mesg); };
log { source(s_sys); destination(d_auth); };
log { source(s_sys); destination(d_syslog); };
```

## SSH Server

### OpenSSH

```bash
# Install OpenSSH
bfsos install openssh

# Enable SSH
sudo rc-update add sshd default

# Start SSH
sudo rc-service sshd start
```

### Configuration

Edit `/etc/ssh/sshd_config`:

```bash
Port 22
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
```

## Power Management

### acpid

acpid handles power management events:

```bash
# Install acpid
bfsos install acpid

# Enable acpid
sudo rc-update add acpid boot

# Start acpid
sudo rc-service acpid start
```

### Configuration

Edit `/etc/acpi/actions/powerbtn.sh`:

```bash
#!/bin/bash
# Handle power button press
/sbin/poweroff
```

## Disk Monitoring

### smartd

smartd monitors disk health:

```bash
# Install smartmontools
bfsos install smartmontools

# Enable smartd
sudo rc-update add smartd default

# Start smartd
sudo rc-service smartd start
```

### Configuration

Edit `/etc/smartd.conf`:

```bash
# Monitor first disk
/dev/sda -a -o on -S on -n standby -s (S/../.././02|L/../../6/03) -m admin@example.com

# Monitor all disks
/dev/sd[a-z] -a -o on -S on -n standby -s (S/../.././02|L/../../6/03) -m admin@example.com
```

## Disk Management

### udisks2

udisks2 provides disk management:

```bash
# Install udisks2
bfsos install udisks2

# Enable udisks2
sudo rc-update add udisks2 default

# Start udisks2
sudo rc-service udisks2 start
```

## PolicyKit

### polkitd

polkitd provides authorization:

```bash
# Install polkit
bfsos install polkit

# Enable polkitd
sudo rc-update add polkitd default

# Start polkitd
sudo rc-service polkitd start
```

## Color Management

### colord

colord manages color profiles:

```bash
# Install colord
bfsos install colord

# Enable colord
sudo rc-update add colord default

# Start colord
sudo rc-service colord start
```

## Power Management

### upowerd

upowerd monitors power devices:

```bash
# Install upower
bfsos install upower

# Enable upowerd
sudo rc-update add upowerd default

# Start upowerd
sudo rc-service upowerd start
```

## Accounts Service

### accounts-daemon

accounts-daemon manages user accounts:

```bash
# Install AccountsService
bfsos install accountsservice openrc-init-scripts

# Enable accounts-daemon
sudo rc-update add accounts-daemon default

# Start accounts-daemon
sudo rc-service accounts-daemon start
```

## Avahi (mDNS)

### avahi-daemon

avahi-daemon provides mDNS/DNS-SD:

```bash
# Install Avahi and its OpenRC scripts
bfsos install avahi openrc-init-scripts

# Enable avahi
sudo rc-update add avahi-daemon default
sudo rc-update add avahi-dnsconfd default

# Start avahi
sudo rc-service avahi-daemon start
sudo rc-service avahi-dnsconfd start
```

## Next Steps

After system services configuration, proceed to [Chapter 15: Troubleshooting](chapters/15-troubleshooting.md) for common issues.
