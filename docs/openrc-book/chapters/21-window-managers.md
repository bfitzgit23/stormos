# Chapter 21: Window Managers

## Overview

Window managers provide minimalist desktop environments focused on window management. This chapter covers popular window managers with OpenRC on StormFS Linux.

## Prerequisites

Before installing window managers, ensure the following are configured:

- X Window System ([Chapter 10: Display Managers](chapters/10-display-managers.md))

## i3 Window Manager

### Installation

```bash
bfsos install i3 i3status i3lock i3blocks
```

### Configuration

```bash
# Create configuration directory
mkdir -p ~/.config/i3

# Copy default config
cp /etc/i3/config ~/.config/i3/config
```

Edit `~/.config/i3/config`:

```
# Set Mod key to Super
set $mod Mod4

# Terminal
bindsym $mod+Return exec i3-sensible-terminal

# Kill focused window
bindsym $mod+Shift+q kill

# Change focus
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right

# Move windows
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right

# Split orientation
bindsym $mod+b split h
bindsym $mod+v split v

# Fullscreen
bindsym $mod+f fullscreen toggle

# Layout
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split

# Restart i3
bindsym $mod+Shift+r restart

# Exit i3
bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'Exit i3?' -B 'Yes' 'i3-msg exit'"
```

### Status Bar

```bash
# i3blocks configuration
cat > ~/.config/i3blocks/config <<'EOF'
separator_block_width=15
markup=pango

[hostname]
command=hostname
interval=0

[disk]
command=df -h / | tail -1 | awk '{print $5}'
interval=30

[mem]
command=free -h | awk '/^Mem:/ {print $3"/"$2}'
interval=10

[cpu]
command=mpstat 1 1 | awk '/Average/ {printf "%.0f%%", 100-$NF}'
interval=10

[volume]
command=pactl get-sink-volume @DEFAULT_SINK@ | awk '{print $5}'
interval=once
signal=10

[date]
command=date '+%Y-%m-%d %H:%M'
interval=1
EOF
```

### Autostart

```bash
# Create autostart file
cat > ~/.config/i3/autostart.sh <<'EOF'
#!/bin/bash
# Start compositor
picom &

# Set wallpaper
feh --bg-scale /path/to/wallpaper.jpg &

# Start notification daemon
dunst &

# Start network manager applet
nm-applet &

# Start volume control
pasystray &
EOF

chmod +x ~/.config/i3/autostart.sh
```

## Openbox

### Installation

```bash
bfsos install openbox obconf lxappearance
```

### Configuration

```bash
# Create configuration directory
mkdir -p ~/.config/openbox

# Copy default config
cp /etc/xdg/openbox/rc.xml ~/.config/openbox/rc.xml
cp /etc/xdg/openbox/menu.xml ~/.config/openbox/menu.xml
cp /etc/xdg/openbox/autostart ~/.config/openbox/autostart
```

Edit `~/.config/openbox/rc.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <keyboard>
    <!-- Terminal -->
    <keybind key="A-F2">
      <action name="Execute">
        <command>x-terminal-emulator</command>
      </action>
    </keybind>
    
    <!-- Close window -->
    <keybind key="A-F4">
      <action name="Close"/>
    </keybind>
    
    <!-- Toggle maximized -->
    <keybind key="A-F9">
      <action name="ToggleMaximize"/>
    </keybind>
    
    <!-- Show desktop -->
    <keybind key="A-d">
      <action name="ToggleShowDesktop"/>
    </keybind>
  </keyboard>
</openbox_config>
```

### Autostart

```bash
# Configure autostart
cat > ~/.config/openbox/autostart <<'EOF'
# Start compositor
picom &

# Set wallpaper
feh --bg-scale /path/to/wallpaper.jpg &

# Start panel
tint2 &

# Start notification daemon
dunst &

# Start network manager applet
nm-applet &
EOF

chmod +x ~/.config/openbox/autostart
```

## Sway (Wayland Compositor)

### Installation

```bash
bfsos install sway swaybg swaylock swayidle
```

### Configuration

```bash
# Create configuration directory
mkdir -p ~/.config/sway

# Copy default config
cp /etc/sway/config ~/.config/sway/config
```

Edit `~/.config/sway/config`:

```
# Set Mod key
set $mod Mod4

# Terminal
set $term foot

# Launch terminal
bindsym $mod+Return exec $term

# Kill focused window
bindsym $mod+Shift+q kill

# Change focus
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right

# Move windows
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right

# Layout
bindsym $mod+b splith
bindsym $mod+v splitv

# Fullscreen
bindsym $mod+f fullscreen toggle

# Floating
bindsym $mod+Shift+space togglefloating

# Restart sway
bindsym $mod+Shift+c reload

# Exit sway
bindsym $mod+Shift+e exec swaymsg exit

# Wallpaper
exec swaybg -i /path/to/wallpaper.jpg -m fill -f
```

### Status Bar (Waybar)

```bash
# Install waybar
bfsos install waybar

# Configure waybar
cat > ~/.config/waybar/config.json <<'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "modules-left": ["sway/workspaces", "sway/mode"],
    "modules-center": ["sway/window"],
    "modules-right": ["pulseaudio", "network", "clock"],
    "sway/workspaces": {
        "format": "{name}"
    },
    "pulseaudio": {
        "format": "{volume}%"
    },
    "network": {
        "format-wifi": "{essid}"
    },
    "clock": {
        "format": "{:%H:%M}"
    }
}
EOF
```

## Hyprland (Wayland Compositor)

### Installation

```bash
bfsos install hyprland hyprpaper hyprlock
```

### Configuration

```bash
# Create configuration directory
mkdir -p ~/.config/hypr

# Create config file
cat > ~/.config/hypr/hyprland.conf <<'EOF'
# Monitor configuration
monitor=,1920x1080@60,0x0,1

# Input configuration
input {
    kb_layout = us
    follow_mouse = 1
    sensitivity = 0
}

# General configuration
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

# Decoration
decoration {
    rounding = 10
    blur {
        enabled = true
        size = 3
        passes = 1
    }
    shadow {
        enabled = true
        range = 4
        render_power = 3
        color = rgba(1a1a1aee)
    }
}

# Keybindings
$mainMod = SUPER

bind = $mainMod, Return, exec, foot
bind = $mainMod, Q, killactive
bind = $mainMod, M, exit
bind = $mainMod, V, togglefloating
bind = $mainMod, F, fullscreen
bind = $mainMod, H, movefocus, l
bind = $mainMod, J, movefocus, d
bind = $mainMod, K, movefocus, u
bind = $mainMod, L, movefocus, r

# Autostart
exec-once = hyprpaper
exec-once = waybar
EOF
```

## Other Window Managers

### bspwm

```bash
# Install bspwm and sxhkd
bfsos install bspwm sxhkd

# Configuration
mkdir -p ~/.config/bspwm
cat > ~/.config/bspwm/bspwmrc <<'EOF'
#!/bin/bash
# Start compositor
picom &

# Set wallpaper
feh --bg-scale /path/to/wallpaper.jpg &

# Start panel
polybar &

# Start sxhkd
sxhkd &
EOF

chmod +x ~/.config/bspwm/bspwmrc
```

### dwm

```bash
# Install dwm (requires compilation)
bfsos install dwm

# Configuration requires editing config.def.h and recompiling
# Consider using dwm-flexipatch for easier configuration
```

### awesome

```bash
# Install awesome
bfsos install awesome

# Configuration
mkdir -p ~/.config/awesome
cp /etc/xdg/awesome/rc.lua ~/.config/awesome/rc.lua
```

## Status Bars

### Polybar

```bash
# Install polybar
bfsos install polybar

# Configuration
mkdir -p ~/.config/polybar
cat > ~/.config/polybar/config <<'EOF'
[bar/main]
width = 100%
height = 30pt
radius = 0
modules-left = i3
modules-right = pulseaudio memory cpu date

[module/i3]
type = internal/i3
label-active = %name%
label-active-background = #555555
label-active-underline = #fba922

[module/pulseaudio]
type = internal/pulseaudio
label-volume = %percentage%

[module/memory]
type = internal/memory
label = %percentage_used:2%%

[module/cpu]
type = internal/cpu
label = %percentage:2%%

[module/date]
type = internal/date
date = %Y-%m-%d %H:%M
EOF

# Start polybar
polybar main &
```

### waybar (Wayland)

```bash
# waybar is the recommended status bar for Wayland compositors
# See Sway section above for configuration
```

### i3blocks

```bash
# i3blocks is i3's default status bar
# See i3 section above for configuration
```

## Tips

- Window managers are highly customizable; start with defaults and modify gradually.
- Use `sxhkd` or `dunst` for keybindings and notifications in non-desktop environments.
- Compositors (picom, sway, hyprpaper) provide visual effects and transparency.
- Status bars can be customized with scripts for system monitoring.
- Consider using a display manager for easier session management.

## Troubleshooting

### Window Manager Not Starting

1. Check X configuration:
   ```bash
   startx
   ```

2. Check window manager installation:
   ```bash
   which i3
   which openbox
   ```

3. Check autostart scripts:
   ```bash
   ls -la ~/.config/i3/autostart.sh
   ```

### No Compositing Effects

1. Install and configure picom:
   ```bash
   bfsos install picom
   picom &
   ```

2. Check picom configuration:
   ```bash
   cat ~/.config/picom/picom.conf
   ```

## Next Steps

After window manager configuration, proceed to [Chapter 22: Web Browsers](chapters/22-browsers.md) for web browser setup.
