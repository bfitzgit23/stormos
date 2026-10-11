# Chapter 28: Communication

## Overview

Communication applications provide email, IRC, chat, and video conferencing capabilities. This chapter covers installing and configuring communication applications on StormFS Linux.

## Prerequisites

Before installing communication applications, ensure the following are configured:

- Network configuration ([Chapter 9: Networking](chapters/09-networking.md))
- Desktop environment or window manager ([Chapters 17-21](chapters/17-xfce.md))

## Email Clients

### Thunderbird

```bash
# Install Thunderbird
bfsos install thunderbird

# Launch Thunderbird
thunderbird
```

### Configuration

```bash
# Thunderbird profile directory
~/.thunderbird/

# Create new profile
thunderbird -P

# Safe mode
thunderbird --safe-mode

# Reset configuration
rm -rf ~/.thunderbird/
```

### Account Setup

```bash
# Add email account
# Tools → Account Settings → Add Account

# Common IMAP settings
# Server: imap.gmail.com
# Port: 993
# Security: SSL/TLS

# Common SMTP settings
# Server: smtp.gmail.com
# Port: 587
# Security: STARTTLS
```

### Extensions

```bash
# Popular Thunderbird extensions
# - Lightning (calendar)
# - Enigmail (encryption)
# - Quicktext (templates)
# - ImportExportTools (backup)

# Install extensions
# Tools → Add-ons → Get Add-ons
```

### Backup and Restore

```bash
# Backup profile
cp -r ~/.thunderbird ~/thunderbird-backup

# Restore profile
cp -r ~/thunderbird-backup ~/.thunderbird
```

## IRC Clients

### Hexchat

```bash
# Install Hexchat
bfsos install hexchat

# Launch Hexchat
hexchat
```

### Configuration

```bash
# Hexchat configuration directory
~/.config/hexchat/

# Configure network
# Hexchat → Network List → Add network

# Common IRC networks
# - Libera.Chat: irc.libera.chat
# - OFTC: irc.oftc.net
# - Freenode: irc.freenode.net
```

### Commands

```bash
# Join channel
/join #channel

# Private message
/msg nickname message

# List channels
/list

# Whois
/whois nickname

# Disconnect
/disconnect
```

### Configuration File

```bash
# Hexchat config
cat > ~/.config/hexchat/hexchat.conf <<'EOF'
[global]
away_reason = I'm not here right now

[flood]
flood_ctcp_wait = 30
flood_msg_wait = 3
EOF
```

### Other IRC Clients

```bash
# irssi (terminal-based)
bfsos install irssi
irssi

# Weechat (terminal-based)
bfsos install weechat
weechat
```

## Chat Applications

### Discord

```bash
# Install Discord
bfsos install discord

# Launch Discord
discord
```

### Configuration

```bash
# Discord configuration directory
~/.config/discord/

# Reset configuration
rm -rf ~/.config/discord/

# Clear cache
rm -rf ~/.config/discord/Cache
```

### Alternative: WebCord

```bash
# Install WebCord (open-source Discord client)
bfsos install webcord

# Launch WebCord
webcord
```

### Element (Matrix Client)

```bash
# Install Element
bfsos install element-desktop

# Launch Element
element-desktop
```

### Configuration

```bash
# Element configuration directory
~/.config/Element/

# Matrix server
# Default: matrix.org
# Self-hosted: https://your-server.com
```

### Matrix Account Setup

```bash
# Create Matrix account
# Element → Create Account

# Join room
# Click + → Join Room

# Direct message
# Click + → Direct Message
```

### Other Chat Applications

```bash
# Telegram Desktop
bfsos install telegram-desktop
telegram-desktop

# Slack
bfsos install slack-desktop
slack-desktop

# Mattermost
bfsos install mattermost-desktop
mattermost-desktop
```

## Video Conferencing

### Jitsi Meet (Web-based)

```bash
# Jitsi Meet is web-based, use your browser
# https://meet.jit.si

# Install Jitsi Meet Desktop (Electron wrapper)
bfsos install jitsi-meet-desktop
```

### Zoom

```bash
# Install Zoom
bfsos install zoom

# Launch Zoom
zoom
```

### Google Meet

```bash
# Google Meet is web-based, use your browser
# https://meet.google.com
```

### Microsoft Teams

```bash
# Install Teams
bfsos install teams

# Launch Teams
teams
```

### Configuration

```bash
# Camera settings
# Settings → Video → Camera

# Microphone settings
# Settings → Audio → Microphone

# Speaker settings
# Settings → Audio → Speaker
```

### Virtual Backgrounds

```bash
# Most applications support virtual backgrounds
# Settings → Video → Virtual Background

# Download background images
# Use royalty-free images from Unsplash or Pexels
```

## Screen Sharing

### OBS Studio

```bash
# Install OBS Studio
bfsos install obs-studio

# Launch OBS Studio
obs

# Add screen capture
# Sources → Add → Screen Capture
```

### Screen Sharing in Applications

```bash
# Discord
# Click Screen Share button → Select window/screen

# Zoom
# Click Share Screen → Select window/screen

# Google Meet
# Click Present Now → Select window/screen
```

### Wayland Screen Sharing

```bash
# Install XDG Desktop Portal
bfsos install xdg-desktop-portal xdg-desktop-portal-wlr

# For Wayland compositors
# Set environment variable
export XDG_CURRENT_DESKTOP=sway
```

## Tips

- Use `Ctrl+K` to clear screen in most terminal IRC clients.
- Use `Ctrl+Shift+T` to reopen closed tabs in browsers.
- Consider using a password manager for storing credentials.
- Enable two-factor authentication for important accounts.
- Use encrypted email with Enigmail/GPG.
- For video calls, test your camera and microphone before joining.
- Use headphones to prevent echo in video calls.

## Troubleshooting

### Email Client Issues

1. Check network connection:
   ```bash
   ping imap.gmail.com
   ```

2. Check firewall:
   ```bash
   sudo iptables -L
   ```

3. Check certificates:
   ```bash
   certutil -d sql:$HOME/.thunderbird -L
   ```

### IRC Connection Issues

1. Check network:
   ```bash
   ping irc.libera.chat
   ```

2. Check port:
   ```bash
   nc -zv irc.libera.chat 6667
   ```

### Video Call Issues

1. Check camera:
   ```bash
   v4l2-ctl --list-devices
   ```

2. Check microphone:
   ```bash
   arecord -l
   ```

3. Test audio:
   ```bash
   speaker-test -t wav -c 2
   ```

### Screen Sharing Issues

1. Check XDG Desktop Portal:
   ```bash
   systemctl --user status xdg-desktop-portal
   ```

2. Check the OpenRC user-session and portal processes:
   ```bash
   echo "$DBUS_SESSION_BUS_ADDRESS"
   pgrep -a dbus-daemon
   pgrep -a xdg-desktop-portal
   ```

   On an OpenRC desktop, install `dbus`, `consolekit2`, and the matching portal backend. Portals are normally started by the desktop session or its autostart mechanism, not by a systemd user unit.

3. Check compositor support:
   ```bash
   echo $XDG_CURRENT_DESKTOP
   ```

## Next Steps

After communication setup, you have completed the BLFS OpenRC book for StormFS Linux. Refer to [Chapter 15: Troubleshooting](chapters/15-troubleshooting.md) for general troubleshooting and [Chapter 16: Advanced Topics](chapters/16-advanced.md) for advanced configuration.
