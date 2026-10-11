# Chapter 27: System Utilities

## Overview

System utilities provide file management, archiving, disk utilities, process monitoring, and terminal emulation. This chapter covers installing and configuring system utilities on StormFS Linux.

## Prerequisites

Before installing system utilities, ensure the following are configured:

- Desktop environment or window manager ([Chapters 17-21](chapters/17-xfce.md))

## File Managers

### Thunar (XFCE)

```bash
# Install Thunar
bfsos install thunar thunar-archive-plugin thunar-volman

# Launch Thunar
thunar

# Set as default file manager
xdg-mime default thunar.desktop inode/directory
```

### Configuration

```bash
# Thunar configuration directory
~/.config/Thunar/

# Custom actions
~/.config/Thunar/uca.xml

# Bulk rename
~/.config/Thunar/uca.xml
```

### Dolphin (KDE)

```bash
# Install Dolphin
bfsos install dolphin dolphin-plugins

# Launch Dolphin
dolphin

# Set as default
xdg-mime default dolphin.desktop inode/directory
```

### Nautilus (GNOME)

```bash
# Install Nautilus
bfsos install nautilus nautilus-sendto

# Launch Nautilus
nautilus

# Set as default
xdg-mime default org.gnome.Nautilus.desktop inode/directory
```

### PCManFM (LXQt)

```bash
# Install PCManFM
bfsos install pcmanfm pcmanfm-qt

# Launch PCManFM
pcmanfm

# Set as default
xdg-mime default pcmanfm-qt.desktop inode/directory
```

### Double Commander (Dual Pane)

```bash
# Install Double Commander
bfsos install doublecmd-gtk2

# Launch Double Commander
doublecmd
```

## Archivers

### file-roller (GNOME)

```bash
# Install file-roller
bfsos install file-roller

# Launch file-roller
file-roller

# Extract archive
file-roller --extract-here /path/to/archive.tar.gz
```

### Xarchiver

```bash
# Install Xarchiver
bfsos install xarchiver

# Launch Xarchiver
xarchiver

# Extract archive
xarchiver --extract /path/to/archive.tar.gz
```

### Ark (KDE)

```bash
# Install Ark
bfsos install ark

# Launch Ark
ark

# Extract archive
ark --extract /path/to/archive.tar.gz
```

### Command-Line Archivers

```bash
# tar
tar -xvf archive.tar.gz
tar -cvf archive.tar.gz /path/to/directory

# zip/unzip
zip -r archive.zip /path/to/directory
unzip archive.zip

# 7zip
7z x archive.7z
7z a archive.7z /path/to/directory
```

## Disk Utilities

### GParted

```bash
# Install GParted
bfsos install gparted

# Launch GParted (requires root)
sudo gparted
```

### GNOME Disk Utility

```bash
# Install GNOME Disk Utility
bfsos install gnome-disk-utility

# Launch GNOME Disk Utility
gnome-disks
```

### GSmartControl

```bash
# Install GSmartControl
bfsos install gsmartcontrol

# Launch GSmartControl
sudo gsmartcontrol
```

### Command-Line Disk Tools

```bash
# List disks
lsblk

# Check disk space
df -h

# Check disk usage
du -sh /path/to/directory

# Check disk health
sudo smartctl -a /dev/sda

# Partition disk
sudo fdisk /dev/sda

# Format partition
sudo mkfs.ext4 /dev/sda1
```

## Process Monitors

### htop

```bash
# Install htop
bfsos install htop

# Launch htop
htop

# Filter by user
htop -u username

# Tree view
htop -t
```

### btop

```bash
# Install btop
bfsos install btop

# Launch btop
btop
```

### glances

```bash
# Install glances
bfsos install glances

# Launch glances
glances

# Web interface
glances -w
```

### Bashtop

```bash
# Install bashtop
bfsos install bashtop

# Launch bashtop
bashtop
```

### Command-Line Process Tools

```bash
# List processes
ps aux

# Find process by name
pgrep -l process_name

# Kill process
kill PID

# Force kill
kill -9 PID

# Process tree
pstree
```

## Terminal Emulators

### kitty

```bash
# Install kitty
bfsos install kitty

# Launch kitty
kitty

# Set as default terminal
xdg-mime default kitty.desktop x-scheme-handler/terminal
```

### Configuration

```bash
# kitty configuration directory
~/.config/kitty/

# Configuration file
cat > ~/.config/kitty/kitty.conf <<'EOF'
# Font
font_family JetBrains Mono
font_size 12.0

# Cursor
cursor_shape beam
cursor_blink_interval 0.5

# Scrollback
scrollback_lines 10000

# Mouse
copy_on_select clipboard

# Tab bar
tab_bar_edge bottom
tab_bar_style powerline
EOF
```

### Alacritty

```bash
# Install Alacritty
bfsos install alacritty

# Launch Alacritty
alacritty

# Set as default
xdg-mime default alacritty.desktop x-scheme-handler/terminal
```

### Configuration

```bash
# Alacritty configuration directory
~/.config/alacritty/

# Configuration file
cat > ~/.config/alacritty/alacritty.toml <<'EOF'
[window]
padding = { x = 5, y = 5 }
decorations = "Full"

[font]
size = 12.0

[font.normal]
family = "JetBrains Mono"
style = "Regular"

[colors.primary]
background = "#1e1e2e"
foreground = "#cdd6f4"

[scrolling]
history = 10000
EOF
```

### foot (Wayland)

```bash
# Install foot
bfsos install foot

# Launch foot
foot

# Set as default
xdg-mime default foot.desktop x-scheme-handler/terminal
```

### Configuration

```bash
# foot configuration directory
~/.config/foot/

# Configuration file
cat > ~/.config/foot/foot.ini <<'EOF'
[main]
term=xterm-256color
font=JetBrains Mono:size=12

[colors]
background=1e1e2e
foreground=cdd6f4

[scrollback]
lines=10000
EOF
```

### Other Terminal Emulators

```bash
# XFCE Terminal
bfsos install xfce4-terminal
xfce4-terminal

# Konsole (KDE)
bfsos install konsole
konsole

# GNOME Terminal
bfsos install gnome-terminal
gnome-terminal

# Terminator (multi-pane)
bfsos install terminator
terminator
```

## Other Utilities

### Clipboard Managers

```bash
# Install clipboard manager
bfsos install clipmenu
# or
bfsos install parcellite

# Launch clipboard manager
clipmenud
```

### Screenshot Tools

```bash
# Install screenshot tool
bfsos install xfce4-screenshooter
# or
bfsos install flameshot

# Take screenshot
xfce4-screenshooter
flameshot gui
```

### System Information

```bash
# Install system information tools
bfsos install neofetch screenfetch

# Display system info
neofetch
screenfetch
```

### Archive Managers

```bash
# Install archive managers
bfsos install atool

# List archive contents
atool --list archive.tar.gz

# Extract archive
atool --extract archive.tar.gz

# Add to archive
atool --add archive.tar.gz /path/to/file
```

## Tips

- Use `Ctrl+Shift+C` and `Ctrl+Shift+V` for copy/paste in most terminal emulators.
- Use `Ctrl+Shift+T` to open a new tab in most terminal emulators.
- Use `Ctrl+Shift+F` to search in terminal output.
- Consider using `tmux` for persistent terminal sessions.
- Use `alias` for frequently used commands.
- Use `~/.bashrc` or `~/.zshrc` for shell configuration.

## Troubleshooting

### File Manager Not Starting

1. Check dependencies:
   ```bash
   ldd /usr/bin/thunar
   ```

2. Check permissions:
   ```bash
   ls -la ~/.config/Thunar/
   ```

### Terminal Emulator Issues

1. Check terminal configuration:
   ```bash
   echo $TERM
   ```

2. Check font availability:
   ```bash
   fc-list | grep JetBrains
   ```

### Process Monitor Issues

1. Check permissions:
   ```bash
   sudo htop
   ```

2. Check for zombie processes:
   ```bash
   ps aux | grep Z
   ```

## Next Steps

After system utilities setup, proceed to [Chapter 28: Communication](chapters/28-communication.md) for communication applications.
