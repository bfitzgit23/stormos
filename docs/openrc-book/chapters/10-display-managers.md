# Chapter 10: Display Managers

## Overview

Display managers provide graphical login interfaces. This chapter covers configuring display managers with OpenRC.

## LightDM

LightDM is a lightweight display manager.

### Installation

```bash
bfsos install lightdm
```

### Configuration

```bash
# Enable LightDM
sudo rc-update add lightdm default

# Start LightDM
sudo rc-service lightdm start
```

### Configuration File

Edit `/etc/lightdm/lightdm.conf`:

```ini
[Seat:*]
autologin-user=stormfs
autologin-user-timeout=0
user-session=xfce
greeter-session=lightdm-gtk-greeter

[Greeter]
user-list=false
```

## SDDM

SDDM is the display manager for KDE Plasma.

### Installation

```bash
bfsos install sddm
```

### Configuration

```bash
# Enable SDDM
sudo rc-update add sddm default

# Start SDDM
sudo rc-service sddm start
```

### Configuration File

Edit `/etc/sddm.conf`:

```ini
[Autologin]
User=stormfs
Session=plasma

[General]
DisplayServer=wayland

[Theme]
Current=breeze
```

## LXDM

LXDM is the display manager for LXDE.

### Installation

```bash
bfsos install lxdm
```

### Configuration

```bash
# Enable LXDM
sudo rc-update add lxdm default

# Start LXDM
sudo rc-service lxdm start
```

## GDM

GDM is the GNOME Display Manager.

### Installation

```bash
bfsos install gdm
```

### Configuration

```bash
# Enable GDM
sudo rc-update add gdm default

# Start GDM
sudo rc-service gdm start
```

## Display Manager Selection

### Switching Display Managers

To switch display managers:

1. Stop the current display manager:
   ```bash
   sudo rc-service lightdm stop
   ```

2. Disable the current display manager:
   ```bash
   sudo rc-update delete lightdm default
   ```

3. Enable the new display manager:
   ```bash
   sudo rc-update add sddm default
   ```

4. Start the new display manager:
   ```bash
   sudo rc-service sddm start
   ```

### Using rc-update

```bash
# List available display managers
ls /etc/init.d/*dm*

# Check which display manager is enabled
ls /etc/runlevels/default/ | grep -E "(lightdm|sddm|lxdm|gdm)"
```

## Manual X Start

For debugging, you can start X manually:

```bash
# Start X without display manager
startx

# Or with specific display manager
xinit /usr/bin/lightdm
```

## Troubleshooting

### Display Manager Not Starting

1. Check dependencies:
   ```bash
   rc-depend -v lightdm
   ```

2. Check logs:
   ```bash
   sudo tail -f /var/log/Xorg.0.log
   ```

3. Check permissions:
   ```bash
   sudo chmod +x /usr/bin/lightdm
   ```

### Black Screen After Login

1. Check X configuration:
   ```bash
   sudo nvidia-settings  # For NVIDIA
   ```

2. Check session configuration:
   ```bash
   ls /usr/share/xsessions/
   ```

## Next Steps

After display manager configuration, proceed to [Chapter 11: Audio Configuration](chapters/11-audio.md) to configure audio.
