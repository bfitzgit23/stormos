# Chapter 18: KDE Plasma Desktop

## Overview

KDE Plasma is a feature-rich desktop environment known for its configurability and modern interface. This chapter covers installing and configuring KDE Plasma with OpenRC on StormFS Linux.

## Prerequisites

Before installing KDE Plasma, ensure the following are configured:

- X Window System or Wayland ([Chapter 10: Display Managers](chapters/10-display-managers.md))
- Audio configuration ([Chapter 11: Audio Configuration](chapters/11-audio.md))

## Installation

### Core Packages

```bash
bfsos install plasma-meta plasma-desktop kde-cli-tools
```

### KDE Applications

```bash
bfsos install konsole dolphin kate ark gwenview
bfsos install spectacle kcalc okular
```

### Recommended Additions

```bash
bfsos install plasma-nm plasma-pa sddm
bfsos install kde-plasma-desktop systemsettings
```

## SDDM vs LightDM Integration

### SDDM (Recommended for KDE)

SDDM is the recommended display manager for KDE Plasma.

```bash
# Install SDDM
bfsos install sddm

# Enable SDDM
sudo rc-update add sddm default

# Start SDDM
sudo rc-service sddm start
```

Configure `/etc/sddm.conf`:

```ini
[Autologin]
User=stormfs
Session=plasma

[General]
DisplayServer=wayland

[Theme]
Current=breeze

[Users]
MaximumUid=60000
MinimumUid=1000
```

### LightDM

LightDM can also be used with KDE Plasma.

```bash
# Install LightDM
bfsos install lightdm lightdm-gtk-greeter

# Enable LightDM
sudo rc-update add lightdm default

# Start LightDM
sudo rc-service lightdm start
```

Configure `/etc/lightdm/lightdm.conf`:

```ini
[Seat:*]
autologin-user=stormfs
autologin-user-timeout=0
user-session=plasma
greeter-session=lightdm-gtk-greeter
```

## OpenRC Services for KDE

### Essential Services

```bash
# Enable core KDE services
sudo rc-update add dbus boot
sudo rc-update add sddm default
sudo rc-update add polkitd default
sudo rc-update add upowerd default
sudo rc-update add accounts-daemon default
```

### Session Services

KDE Plasma components such as `plasmashell`, KWin, and PowerDevil belong to the logged-in user session. Do not create a root-owned OpenRC service for them. SDDM starts the selected Plasma session with the correct `DISPLAY`, D-Bus session bus, and user environment.

Use KDE's session configuration for user services:

```bash
# Open the KDE autostart settings
kcmshell6 kcm_autostart 2>/dev/null || kcmshell5 kcm_autostart

# Inspect the user session processes
pgrep -a 'plasmashell|kwin|powerdevil'
```

### Service Dependencies

```bash
# Check service dependencies
rc-depend -v sddm
rc-depend -v polkitd

# List all KDE-related services
ls /etc/init.d/ | grep -E "(sddm|kde|plasma|power)"
```

## Configuring KDE

### System Settings

```bash
# Launch System Settings
systemsettings

# Or via command line
kcmshell5 kcm_users
```

### Display Configuration

```bash
# Configure display
kcmshell5 kcm_kscreen

# Or via xrandr
xrandr --output HDMI-1 --mode 1920x1080 --rate 60
```

### Appearance

```bash
# Set global theme
plasma-apply-desktoptheme breeze-dark

# Set icon theme
plasma-apply-icontheme breeze-dark

# Set cursor theme
plasma-apply-cursortheme breeze_cursors

# Set wallpaper
plasma-apply-wallpaperimage /path/to/wallpaper.jpg
```

### Panel Configuration

```bash
# Add widgets to panel
plasmashell --add-widget org.kde.plasma.systemtray

# Configure panel
plasmashell --configure-panel

# Export panel layout
plasmashell --dump-layout > panel-layout.json
```

### Window Management

```bash
# Configure window behavior
kcmshell5 kcm_kwin_options

# Configure window decorations
kcmshell5 kcm_kwin_decoration

# Configure desktop effects
kcmshell5 kcm_kwin_effects
```

## System Settings

### Network Configuration

```bash
# Network Manager applet
kcmshell5 kcm_networkmanagement

# Configure VPN
kcmshell5 kcm_plasmovpn
```

### Audio Configuration

```bash
# Audio settings
kcmshell5 kcm_audio
```

### User Management

```bash
# User settings
kcmshell5 kcm_users
```

### Startup and Shutdown

```bash
# Configure autostart
kcmshell5 kcm_autostart

# Configure shutdown
kcmshell5 kcm_smserver
```

## Tips

- Use `Alt+F2` to open the Run Command dialog.
- Use `Alt+Space` for KRunner (system-wide search).
- KDE supports Wayland natively; select "Plasma (Wayland)" at the login screen.
- Use `kwriteconfig5` for scripted configuration changes.
- KDE Connect provides seamless phone integration.

## Troubleshooting

### KDE Not Starting

1. Check Plasma shell:
   ```bash
   plasmashell --version
   ```

2. Check Qt configuration:
   ```bash
   qdbus org.kde.KWin /KWin reconfigure
   ```

3. Reset Plasma configuration:
   ```bash
   rm -rf ~/.config/plasma*
   rm -rf ~/.local/share/plasma*
   ```

### Display Issues

1. Check KScreen configuration:
   ```bash
   kcmshell5 kcm_kscreen
   ```

2. Force X11 mode:
   ```bash
   echo "export KDE_FULL_SESSION=true" >> ~/.xinitrc
   ```

## Next Steps

After KDE Plasma configuration, proceed to [Chapter 19: GNOME Desktop](chapters/19-gnome.md) for GNOME setup.
