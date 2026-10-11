# Chapter 11: Audio Configuration

## Overview

This chapter covers audio configuration with OpenRC.

## ALSA

ALSA provides basic audio support.

### Installation

```bash
bfsos install alsa-utils
```

### Configuration

```bash
# Enable ALSA
sudo rc-update add alsa boot

# Start ALSA
sudo rc-service alsa start
```

### Save/Restore State

```bash
# Save current state
sudo alsactl store

# Restore saved state
sudo alsactl restore
```

### Volume Control

```bash
# List sound cards
aplay -l

# List controls
amixer scontrols

# Set volume
amixer set Master 50%

# Unmute
amixer set Master unmute
```

## PulseAudio

PulseAudio provides advanced audio features. For a desktop, prefer per-user PulseAudio or PipeWire; the system-wide OpenRC wrapper is intended for machines that explicitly need a system daemon.

### Installation

```bash
bfsos install pulseaudio
```

### System-Wide Mode

For system-wide PulseAudio:

```bash
# Enable PulseAudio
sudo rc-update add pulseaudio default

# Start PulseAudio
sudo rc-service pulseaudio start
```

### User Mode

For per-user PulseAudio (recommended for desktops):

```bash
# Add to user's .bash_profile
pulseaudio --start
```

### Configuration

Edit `/etc/pulse/daemon.conf`:

```ini
default-sample-format = s16le
default-sample-rate = 44100
default-sample-channels = 2
default-fragments = 2
default-fragment-size-msec = 25
```

## PipeWire

PipeWire is a modern multimedia server. Its OpenRC wrapper requires D-Bus and should be started after the system bus is available.

### Installation

```bash
bfsos install pipewire
bfsos install wireplumber
```

### System-Wide Configuration

The OpenRC `pipewire` wrapper is an explicit system-wide option. Enable it only when a system daemon is required:

```bash
sudo rc-update add dbus boot
sudo rc-update add pipewire default
sudo rc-service pipewire start
```

### User Mode (Recommended)

PipeWire and WirePlumber normally belong to each logged-in user's audio session. Do not add `wireplumber` to a root runlevel. Start both from the desktop session or its autostart mechanism:

```bash
# In the desktop session environment
pipewire &
wireplumber &
```

Check the active session:

```bash
pgrep -a pipewire
pgrep -a wireplumber
pactl info 2>/dev/null || true
```

## Audio Applications

### alsamixer

```bash
# Start alsamixer
alsamixer

# Navigate: arrow keys
# Increase volume: up arrow
# Decrease volume: down arrow
# Mute/unmute: m
```

### pavucontrol

```bash
# Start PulseAudio volume control
pavucontrol
```

### pw-top

```bash
# Monitor PipeWire
pw-top
```

## Troubleshooting

### No Sound

1. Check sound cards:
   ```bash
   aplay -l
   ```

2. Check mixer levels:
   ```bash
   amixer
   ```

3. Check PulseAudio:
   ```bash
   pactl list sinks
   ```

### Audio Cracking

1. Increase buffer size in PulseAudio config
2. Check CPU frequency scaling
3. Try different sample rates

## Next Steps

After audio configuration, proceed to [Chapter 12: Bluetooth](chapters/12-bluetooth.md) to configure Bluetooth.
