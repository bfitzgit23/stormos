# Chapter 8: Migration from Systemd

## Overview

This chapter covers migrating a system from systemd to OpenRC. The systemd commands below are retained as discovery and rollback tools; the replacement configuration uses OpenRC services and runlevels.

## OpenRC Replacement Matrix

| systemd service or feature | OpenRC replacement | Configuration or command |
|----------------------------|--------------------|--------------------------|
| `systemd-journald` | `sysklogd` or `syslog-ng` | `/var/log/messages`, `tail -f`, `logrotate` |
| `systemd-logind` | `consolekit2` (or external elogind) | D-Bus session and seat provider |
| `systemd-networkd` | `networking` + `dhcpcd`, or NetworkManager | `/etc/conf.d/net`, `rc-update` |
| `systemd-resolved` | `openresolv` | `/run/resolvconf/resolv.conf` |
| `systemd-udevd` | `eudev` + `udev` scripts | `sysinit` runlevel |
| `systemd-timesyncd` | `chronyd` | `boot` runlevel |
| `systemd-tmpfiles` | `local.d` and package post-install setup | `/etc/local.d/*.start` |
| `.timer` units | `cronie` | `/etc/cron.d/` or `/etc/cron.daily/` |
| `.socket` units | daemon-native socket or `socat` | OpenRC service dependency |
| `multi-user.target` | `default` | `rc default` |
| `graphical.target` | `default` + display manager | `rc-update add lightdm default` |
| `getty@.service` | `agetty` in `/etc/inittab` | `respawn` entries |

### Install the OpenRC Runtime

```bash
bfsos install openrc openrc-init-scripts eudev dbus sysklogd chrony openresolv consolekit2
mkdir -p /etc/runlevels/{sysinit,boot,default,nonetwork,shutdown}

rc-update add udev sysinit
rc-update add udev-postmount sysinit
rc-update add dbus boot
rc-update add chronyd boot
rc-update add syslog boot
rc-update add networking boot
```

The `syslog`, `crond`, and other service names above refer to the scripts supplied by the StormFS OpenRC profile. `consolekit2` is D-Bus activated and is not added as an OpenRC runlevel service. Check `/etc/init.d/` and use the exact installed name before enabling a service.

### Journald to Syslog

```bash
install -d -m 0755 /var/log
cat > /etc/init.d/syslog << 'EOF'
#!/sbin/openrc-run
description="System logger"
command="/usr/sbin/syslogd"
command_args="-F"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
depend() { need localmount; }
EOF
chmod 755 /etc/init.d/syslog
rc-update add syslog boot
rc-service syslog start
tail -f /var/log/messages
```

### Timers and Sockets

OpenRC does not implement systemd timer units. Convert `OnCalendar=daily` jobs to cron files:

```bash
bfsos install cronie
rc-update add crond boot 2>/dev/null || true
cat > /etc/cron.d/stormfs-cleanup << 'EOF'
17 3 * * * root /usr/local/bin/stormfs-cleanup.sh
EOF
chmod 644 /etc/cron.d/stormfs-cleanup
```

For socket activation, configure the application to create and listen on its own socket, then manage it as a normal OpenRC service. If a separate listener is unavoidable, supervise `socat` and declare the application service with `need socket-listener`.

## Pre-Migration Checklist

Before migrating:

1. **Backup your system**
2. **Document current services**
3. **Check for systemd-specific dependencies**
4. **Test in a chroot first**

### Document Current Services

```bash
# List enabled services
systemctl list-unit-files --state=enabled

# List running services
systemctl list-units --type=service --state=running
```

## Migration Steps

### Step 1: Install OpenRC

```bash
# Install OpenRC
bfsos install openrc

# Install init scripts
bfsos install openrc-init-scripts
```

### Step 2: Create Runlevel Directories

```bash
sudo mkdir -p /etc/runlevels/{sysinit,boot,default,nonetwork,single}
```

### Step 3: Map Systemd Services to OpenRC

| Systemd Service | OpenRC Service | Notes |
|-----------------|----------------|-------|
| systemd-networkd | networking / networkmanager | Use `/etc/conf.d/net` with `dhcpcd`, or NetworkManager |
| systemd-resolved | openresolv | Use `/run/resolvconf/resolv.conf` for generated DNS |
| systemd-journald | syslog | Use `sysklogd` or syslog-ng with `/var/log` files |
| systemd-logind | consolekit2 / external elogind | Install a compatible D-Bus session provider |
| systemd-udevd | udev | Use eudev with the OpenRC `udev` scripts |
| systemd-timesyncd | chronyd | Enable `chronyd` in `boot` |
| systemd-tmpfiles | local.d | Use `/etc/local.d/*.start` for site-specific paths |
| systemd timers | crond | Use `/etc/cron.d/` or `/etc/cron.daily/` |
| systemd sockets | native listener / socat | Manage the listener and daemon as OpenRC services |

### Step 4: Enable Services

Enable only the services selected for this installation. The following is a typical laptop/desktop profile using the service names shipped by StormFS:

```bash
# Core boot services
sudo rc-update add dbus boot
sudo rc-update add syslog boot
sudo rc-update add udev sysinit
sudo rc-update add udev-postmount sysinit
sudo rc-update add crond boot
sudo rc-update add chronyd boot
sudo rc-update add acpid boot

# Choose one network path: NetworkManager, or dhcpcd plus iwd/wpa_supplicant
sudo rc-update add networkmanager default
# sudo rc-update add dhcpcd default
# sudo rc-update add iwd default

# Choose one display manager
sudo rc-update add lightdm default
# sudo rc-update add sddm default
# sudo rc-update add lxdm default
# sudo rc-update add gdm default

# Optional hardware and access services
sudo rc-update add alsa boot
sudo rc-update add bluez default
sudo rc-update add sshd default
```

`dbus` must be available before `bluez`, display managers, PolicyKit, UDisks2, AccountsService, UPower, and PipeWire. `networkmanager` and `dhcpcd` should not both manage the same interface.

### Step 5: Remove Systemd

**WARNING**: Only do this after confirming OpenRC works!

```bash
# Remove systemd (careful!)
bfsos remove systemd

# Remove systemd-related packages
bfsos remove systemd-libs
```

## Common Issues

### Issue 1: Missing Dependencies

Some packages may depend on systemd. Check with:

```bash
bfsos native -Qi <package>    # pacman metadata + depends of an installed port
bfs-deps deps <package>       # its declared Pkgfile dependencies
```

### Issue 2: D-Bus Services

D-Bus services may need a session/seat provider but do not require systemd. Use the ConsoleKit2 port in this repository:

```bash
bfsos install consolekit2
# ConsoleKit2 is activated through the D-Bus system bus.
rc-update add dbus boot 2>/dev/null || true
```

### Issue 3: Logging

Systemd uses journald. Switch to syslog:

```bash
bfsos install sysklogd openrc-init-scripts
sudo rc-update add syslog boot
```

## Testing Migration

### Test in Chroot

```bash
# Create chroot environment
mkdir /tmp/test-system
# ... setup chroot ...

# Install OpenRC in chroot
chroot /tmp/test-system bfsos install openrc

# Test services
chroot /tmp/test-system rc-update add networkmanager default
```

### Test Boot

1. Keep systemd as fallback
2. Install OpenRC alongside systemd
3. Test boot with OpenRC
4. Remove systemd only after confirming everything works

## Rollback Plan

If migration fails:

1. Boot from live media
2. Reinstall systemd
3. Restore service configuration

## Next Steps

After migration, proceed to [Chapter 9: Networking](chapters/09-networking.md) to configure networking.
