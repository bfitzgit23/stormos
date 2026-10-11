# Chapter 24: Multimedia

## Overview

Multimedia applications provide video playback, audio playback, image viewing, and content creation tools. This chapter covers installing and configuring multimedia applications on StormFS Linux.

## Prerequisites

Before installing multimedia applications, ensure the following are configured:

- Audio configuration ([Chapter 11: Audio Configuration](chapters/11-audio.md))

## Video Players

### VLC

```bash
# Install VLC
bfsos install vlc

# Launch VLC
vlc /path/to/video.mp4

# VLC as default video player
xdg-mime default vlc.desktop video/mp4
```

### mpv

```bash
# Install mpv
bfsos install mpv

# Launch mpv
mpv /path/to/video.mp4

# With subtitles
mpv --sub-file=/path/to/subtitles.srt /path/to/video.mp4

# mpv as default video player
xdg-mime default mpv.desktop video/mp4
```

### Totem (GNOME Video Player)

```bash
# Install Totem
bfsos install totem

# Launch Totem
totem /path/to/video.mp4

# Set as default
xdg-mime default totem.desktop video/mp4
```

### Configuration

```bash
# VLC configuration
vlc --intf qt

# mpv configuration
mkdir -p ~/.config/mpv
cat > ~/.config/mpv/mpv.conf <<'EOF'
# Hardware acceleration
hwdec=auto

# Audio output
ao=pulse

# Video output
vo=gpu

# Subtitles
sub-auto=fuzzy
EOF
```

## Audio Players

### Rhythmbox

```bash
# Install Rhythmbox
bfsos install rhythmbox

# Launch Rhythmbox
rhythmbox

# Set as default audio player
xdg-mime default rhythmbox.desktop audio/mpeg
```

### Lollypop

```bash
# Install Lollypop
bfsos install lollypop

# Launch Lollypop
lollypop

# Set as default
xdg-mime default lollypop.desktop audio/mpeg
```

### Clementine

```bash
# Install Clementine
bfsos install clementine

# Launch Clementine
clementine

# Set as default
xdg-mime default clementine.desktop audio/mpeg
```

### Configuration

```bash
# Rhythmbox plugins
rhythmbox-client --no-start --select-source=Local

# mpv audio
mpv --audio-device=pulse/default /path/to/audio.mp3

# Clementine configuration
# Via GUI: Tools → Preferences
```

## Image Viewers

### Eye of GNOME (eog)

```bash
# Install eog
bfsos install eog

# Launch eog
eog /path/to/image.png

# Set as default image viewer
xdg-mime default eog.desktop image/png
```

### Ristretto (XFCE Image Viewer)

```bash
# Install Ristretto
bfsos install ristretto

# Launch Ristretto
ristretto /path/to/image.png

# Set as default
xdg-mime default ristretto.desktop image/png
```

### sxiv (Simple X Image Viewer)

```bash
# Install sxiv
bfsos install sxiv

# Launch sxiv
sxiv /path/to/image.png

# Batch viewing
sxiv /path/to/images/*.png
```

### Configuration

```bash
# eog settings
gsettings set org.gnome.eog.view use-wheelbar true

# sxiv keybindings
# q: quit
# f: fullscreen
# b: toggle bar
# Arrow keys: navigate
```

## Video Editors

### Shotcut

```bash
# Install Shotcut
bfsos install shotcut

# Launch Shotcut
shotcut
```

### Kdenlive

```bash
# Install Kdenlive
bfsos install kdenlive

# Launch Kdenlive
kdenlive
```

### OBS Studio

```bash
# Install OBS Studio
bfsos install obs-studio

# Launch OBS Studio
obs
```

### Configuration

```bash
# OBS Studio configuration
# Via GUI: File → Settings

# Kdenlive configuration
# Via GUI: Settings → Configure Kdenlive

# Shotcut configuration
# Via GUI: Settings → Preferences
```

## Audio Editors

### Audacity

```bash
# Install Audacity
bfsos install audacity

# Launch Audacity
audacity

# Open audio file
audacity /path/to/audio.wav
```

### Configuration

```bash
# Audacity configuration
# Via GUI: Edit → Preferences

# Key bindings
# Space: play/pause
# R: record
# Ctrl+Z: undo
# Ctrl+S: save
```

## Codecs

### FFmpeg

```bash
# Install FFmpeg
bfsos install ffmpeg

# Convert video formats
ffmpeg -i input.avi -c:v libx264 output.mp4

# Extract audio
ffmpeg -i input.mp4 -vn output.mp3

# Create GIF from video
ffmpeg -i input.mp4 -vf "fps=10,scale=320:-1" output.gif
```

### GStreamer

```bash
# Install GStreamer
bfsos install gstreamer gst-plugins-base gst-plugins-good

# Test GStreamer
gst-launch-1.0 videotestsrc ! autovideosink
```

## Tips

- Use `mpv` for lightweight video playback with excellent performance.
- VLC supports almost all video formats out of the box.
- OBS Studio is excellent for screen recording and streaming.
- Use `ffmpeg` for command-line media conversion.
- Enable hardware acceleration for better video playback performance.
- Consider using `yt-dlp` for downloading online videos.

## Troubleshooting

### No Video Playback

1. Check codecs:
   ```bash
   ffmpeg -codecs
   ```

2. Install additional codecs:
   ```bash
   bfsos install gst-plugins-ugly gst-plugins-bad
   ```

3. Check hardware acceleration:
   ```bash
   vainfo
   ```

### No Audio in Video Players

1. Check audio output:
   ```bash
   pactl list sinks
   ```

2. Check player audio settings:
   - VLC: Audio → Audio Device
   - mpv: `--audio-device=pulse/default`

### Slow Video Playback

1. Enable hardware acceleration:
   ```bash
   # mpv
   mpv --hwdec=auto video.mp4
   
   # VLC
   # Tools → Preferences → Input/Codecs → Video codecs → FFmpeg → Hardware decoding
   ```

2. Check CPU usage:
   ```bash
   htop
   ```

## Next Steps

After multimedia setup, proceed to [Chapter 25: Graphics and Design](chapters/25-graphics.md) for graphics applications.
