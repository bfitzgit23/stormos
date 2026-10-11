# Chapter 17: XFCE Desktop

## Overview

XFCE is a lightweight desktop environment that is fast, lightweight, and easy to use. This chapter covers installing and configuring XFCE with OpenRC on StormFS Linux.

## Prerequisites

Before installing XFCE, ensure the following are configured:

- X Window System ([Chapter 10: Display Managers](chapters/10-display-managers.md))
- Audio configuration ([Chapter 11: Audio Configuration](chapters/11-audio.md))

## Installation

### Core Packages

```bash
bfsos install xfce4 xfce4-terminal thunar
```

### Recommended Additions

```bash
bfsos install xfce4-whiskermenu-plugin xfce4-clipman-plugin
bfsos install xfce4-screenshooter-plugin xfce4-taskmanager
bfsos install ristretto mousepad parole
```

### Notifications and Theming

```bash
bfsos install xfce4-notifyd xfce4-power-manager
bfsos install arc-icons arc-themes gtk-engine-murrine
```

## OpenRC Integration

OpenRC starts the system services required by XFCE. The display manager creates the user session; do not run `startxfce4` as a root-owned system daemon.

### System Services

```bash
# Enable the system bus and selected desktop services
sudo rc-update add dbus boot
sudo rc-update add polkitd default
sudo rc-update add upowerd default
sudo rc-update add lightdm default

# Start the display manager after its dependencies
sudo rc-service lightdm start
```

### User Session Autostart

Select the XFCE session in LightDM, or start it from the graphical user session:

```bash
# ~/.xinitrc or the desktop session launcher
exec startxfce4
```

Use `~/.config/autostart/*.desktop` for `xfce4-power-manager` and panel plugins. These processes need the logged-in user’s `DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`, and audio environment; placing them in a system runlevel is incorrect.

### Power Management Service

```bash
# System-level power policy
sudo rc-update add upowerd default
sudo rc-service upowerd status

# User-level XFCE power manager, launched by XFCE
xfce4-power-manager &
```

## Configuring XFCE

### Display Settings

```bash
# Configure display via xfce4-display-settings
xfce4-display-settings

# Or via command line
xrandr --output HDMI-1 --mode 1920x1080 --rate 60
```

### Panel Configuration

XFCE panels are configured through the GUI. To manage panels from the command line:

```bash
# Export current panel configuration
xfce4-panel --save

# Reset panels to default
xfce4-panel --reset

# Add a plugin to the panel
xfce4-panel --plugin-add=whiskermenu
```

Panel layout files are stored in `~/.config/xfce4/panel/`.

### Desktop Settings

```bash
# Set wallpaper
xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/workspace0/last-image \
    -s /path/to/wallpaper.jpg

# Set icon size
xfconf-query -c xfce4-desktop -p /icons/icon-size -s 48

# Show icons on desktop
xfconf-query -c xfce4-desktop -p /desktop-icons/style -s 2
```

### Window Manager

```bash
# Configure window manager settings
xfconf-query -c xfwm4 -p /general/title_font -s "Sans Bold 10"
xfconf-query -c xfwm4 -p /general/theme -s Arc-Dark
```

## Default Applications

### Setting Defaults

```bash
# Set default web browser
xfconf-query -c xfce4-mime-settings -p /default-web-browser -s firefox.desktop

# Set default file manager
xfconf-query -c xfce4-mime-settings -p /default-file-manager -s thunar.desktop

# Set default terminal emulator
xfconf-query -c xfce4-mime-settings -p /default-terminal-emulator -s xfce4-terminal.desktop
```

### MIME Type Management

```bash
# List available MIME types
xdg-mime query default text/html

# Set default for MIME type
xdg-mime default firefox.desktop text/html
```

## Power Management

### xfce4-power-manager

```bash
# Enable power management
# Launch xfce4-power-manager from the XFCE session autostart
xfce4-power-manager &

# Start power management
xfce4-power-manager &
```

### Configuration

```bash
# Configure power settings via xfconf
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/show-tray-icon -s 1
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -s 10
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off -s 15
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-sleep -s 20
```

### Laptop Settings

```bash
# Configure lid close action
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lid-action-on-battery -s 1

# Configure sleep on battery
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/hibernate-on-battery -s 1
```

## Tips

- Use `xfce4-settings-manager` to access all XFCE settings from one place.
- XFCE supports compositing for visual effects; enable it in Window Manager Tweaks.
- The whiskermenu plugin provides a modern application menu alternative.
- XFCE is highly customizable with themes and plugins from the XFCE Panel plugins repository.
- For autostart applications, place `.desktop` files in `~/.config/autostart/`.

## Troubleshooting

### XFCE Not Starting

1. Check that X is configured correctly:
   ```bash
   startx
   ```

2. Check session logs:
   ```bash
   cat ~/.xsession-errors
   ```

3. Ensure D-Bus is running:
   ```bash
   sudo rc-service dbus status
   ```

### Panel Issues

1. Reset the panel:
   ```bash
   xfce4-panel --reset
   ```

2. Kill and restart the panel:
   ```bash
   xfce4-panel -r &
   ```

## Next Steps

After XFCE configuration, proceed to [Chapter 18: KDE Plasma Desktop](chapters/18-kde.md) for KDE Plasma setup.
