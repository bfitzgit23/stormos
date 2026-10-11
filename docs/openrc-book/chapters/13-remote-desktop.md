# Chapter 13: Remote Desktop

## Overview

This chapter covers remote desktop configuration with OpenRC.

## RustDesk

RustDesk is an open-source remote desktop solution.

### Installation

```bash
bfsos install rustdesk-bin
```

### Configuration

```bash
# Enable RustDesk
sudo rc-update add rustdesk default

# Start RustDesk
sudo rc-service rustdesk start
```

### Service Mode

Run RustDesk as a service:

```bash
# Start service
rustdesk --service

# Or use init script
sudo rc-service rustdesk start
```

## AnyDesk

AnyDesk is a commercial remote desktop solution.

### Installation

```bash
bfsos install anydesk
```

### Configuration

```bash
# Enable AnyDesk
sudo rc-update add anydesk default

# Start AnyDesk
sudo rc-service anydesk start
```

### Service Mode

```bash
# Start service
anydesk --service

# Or use init script
sudo rc-service anydesk start
```

## TeamViewer

TeamViewer is another commercial remote desktop solution.

### Installation

```bash
bfsos install teamviewer
```

### Configuration

```bash
# Enable TeamViewer
sudo rc-update add teamviewer default

# Start TeamViewer
sudo rc-service teamviewer start
```

### Service Mode

```bash
# Start service
/opt/teamviewer/tv_bin/teamviewerd

# Or use init script
sudo rc-service teamviewer start
```

## VNC

VNC provides remote access to the desktop.

### Installation

```bash
bfsos install tigervnc
```

### Configuration

```bash
# Set VNC password
vncpasswd

# Start VNC server
vncserver :1 -geometry 1920x1080 -depth 24
```

### OpenRC Service

Create `/etc/init.d/vncserver`:

```bash
#!/sbin/openrc-run

description="VNC Server"

depend() {
    need net
    after logger
}

start() {
    ebegin "Starting VNC server"
    su - $VNC_USER -c "vncserver :$VNC_DISPLAY -geometry $VNC_GEOMETRY -depth $VNC_DEPTH"
    eend $?
}

stop() {
    ebegin "Stopping VNC server"
    su - $VNC_USER -c "vncserver -kill :$VNC_DISPLAY"
    eend $?
}
```

## SSH Tunneling

For secure remote desktop access:

### Basic Tunnel

```bash
# Create tunnel
ssh -L 5901:localhost:5901 user@remote-server

# Connect VNC to localhost:5901
```

### X11 Forwarding

```bash
# Enable X11 forwarding
ssh -X user@remote-server

# Run graphical application
xeyes
```

## Troubleshooting

### Connection Refused

1. Check service is running:
   ```bash
   sudo rc-service rustdesk status
   ```

2. Check firewall:
   ```bash
   sudo nft list ruleset
   ```

3. Check ports:
   ```bash
   ss -tlnp | grep -E "(5900|5901|21115|21116|21117)"
   ```

### Black Screen

1. Check display manager
2. Check X configuration
3. Check user permissions

## Next Steps

After remote desktop configuration, proceed to [Chapter 14: System Services](chapters/14-system-services.md) to configure other system services.
