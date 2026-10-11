# Chapter 22: Web Browsers

## Overview

Web browsers are essential for internet access. This chapter covers installing and configuring web browsers on StormFS Linux.

## Prerequisites

Before installing web browsers, ensure the following are configured:

- Network configuration ([Chapter 9: Networking](chapters/09-networking.md))

## Firefox

### Installation

```bash
# Install Firefox
bfsos install firefox

# Or binary version (faster updates)
bfsos install firefox-bin
```

### OpenRC Service

Firefox does not require a system service. However, you can configure auto-start:

```bash
# Create autostart entry
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/firefox.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Firefox
Exec=firefox
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
```

### Configuration

```bash
# Launch Firefox
firefox

# Profile Manager
firefox -P

# New profile
firefox -CreateProfile myprofile

# Safe mode (disable extensions)
firefox --safe-mode
```

### Profile Management

```bash
# List profiles
firefox -P

# Create new profile
firefox -CreateProfile work

# Backup profile
cp -r ~/.mozilla/firefox/your-profile ~/firefox-backup

# Restore profile
cp -r ~/firefox-backup ~/.mozilla/firefox/your-profile
```

### Extensions

```bash
# Popular extensions
# - uBlock Origin (ad blocker)
# - Bitwarden (password manager)
# - Dark Reader (dark mode)
# - Vimium (keyboard navigation)

# Install via command line (requires extension ID)
firefox -install-extension uBlock0@raymondhill.net.xpi
```

### Configuration File

Edit `~/.mozilla/firefox/your-profile/user.js`:

```javascript
// Set homepage
user_pref("browser.startup.homepage", "https://start.duckduckgo.com");

// Enable smooth scrolling
user_pref("general.smoothScroll", true);

// Disable telemetry
toolkit.telemetry.enabled = false;

// Enable DRM content
media.eme.enabled = true;
```

## Chromium

### Installation

```bash
# Install Chromium
bfsos install chromium

# Or binary version
bfsos install chromium-bin
```

### Configuration

```bash
# Launch Chromium
chromium

# With flags
chromium --no-sandbox --disable-gpu
```

### Profile Management

```bash
# Profile directory
~/.config/chromium/

# Create new profile
chromium --user-data-dir=/path/to/new-profile

# Backup profile
cp -r ~/.config/chromium ~/chromium-backup
```

### Extensions

```bash
# Popular extensions
# - uBlock Origin
# - Bitwarden
# - Dark Reader
# - Vimium

# Install via Chrome Web Store
# https://chrome.google.com/webstore/category/extensions
```

### Configuration File

Edit `~/.config/chromium/Default/Preferences`:

```json
{
    "browser": {
        "show_home_button": true,
        "check_default_browser": false
    },
    "session": {
        "restore_on_startup": 1,
        "startup_urls": ["https://start.duckduckgo.com"]
    }
}
```

### Chromium Flags

```bash
# Create flags file
cat > ~/.config/chromium-flags.conf <<'EOF'
--enable-features=VaapiVideoDecoder
--ignore-gpu-blocklist
--enable-gpu-rasterization
EOF
```

## Other Browsers

### Brave Browser

```bash
# Install Brave
bfsos install brave-browser

# Configuration
~/.config/BraveSoftware/Brave-Browser/
```

### Vivaldi

```bash
# Install Vivaldi
bfsos install vivaldi

# Configuration
~/.config/vivaldi/
```

### Qutebrowser (Keyboard-driven)

```bash
# Install Qutebrowser
bfsos install qutebrowser

# Configuration
mkdir -p ~/.config/qutebrowser
cat > ~/.config/qutebrowser/config.py <<'EOF'
# Set search engines
c.url.search_engines = {
    'DEFAULT': 'https://duckduckgo.com/?q={}',
    'g': 'https://www.google.com/search?q={}',
    'gh': 'https://github.com/search?q={}',
}

# Set start page
c.url.start_pages = ['https://start.duckduckgo.com']

# Bindings
config.bind('J', 'tab-prev')
config.bind('K', 'tab-next')
EOF
```

## Browser Configuration

### Default Browser

```bash
# Set default browser
xdg-settings set default-web-browser firefox.desktop

# Verify
xdg-settings get default-web-browser
```

### MIME Types

```bash
# Set HTTP handler
xdg-mime default firefox.desktop x-scheme-handler/http
xdg-mime default firefox.desktop x-scheme-handler/https

# Set HTML handler
xdg-mime default firefox.desktop text/html
```

### Hardware Acceleration

```bash
# Firefox: enable hardware acceleration
# In about:config:
# layers.acceleration.force-enabled = true
# gfx.webrender.all = true

# Chromium: enable hardware acceleration
# In chrome://settings:
# Use hardware acceleration when available = ON
```

## Tips

- Use `Ctrl+Shift+Delete` to clear browsing data.
- Use `Ctrl+L` to focus the address bar.
- Use `Ctrl+T` to open a new tab.
- Use `Ctrl+Shift+T` to reopen a closed tab.
- Use `F12` to open developer tools.
- Consider using a VPN extension for privacy.
- Enable DRM content for streaming services like Netflix.

## Troubleshooting

### Browser Not Starting

1. Check dependencies:
   ```bash
   ldd /usr/lib/firefox/firefox
   ```

2. Run in safe mode:
   ```bash
   firefox --safe-mode
   chromium --no-sandbox
   ```

3. Check permissions:
   ```bash
   ls -la ~/.mozilla/firefox/
   ```

### No Audio in Browser

1. Check PulseAudio/PipeWire:
   ```bash
   pactl list sinks
   ```

2. Check browser audio settings:
   - Firefox: `about:config` → `media.audio.paused`
   - Chromium: `chrome://settings/content/sound`

### Slow Performance

1. Disable hardware acceleration temporarily:
   ```bash
   # Firefox
   about:config → layers.acceleration.force-enabled = false
   
   # Chromium
   chrome://settings → Use hardware acceleration when available = OFF
   ```

2. Clear cache:
   ```bash
   # Firefox
   Ctrl+Shift+Delete
   
   # Chromium
   Ctrl+Shift+Delete
   ```

## Next Steps

After browser configuration, proceed to [Chapter 23: Office Suites](chapters/23-office.md) for office application setup.
