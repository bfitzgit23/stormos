# Chapter 12: Bluetooth

## Overview

This chapter covers Bluetooth configuration with OpenRC.

## BlueZ

BlueZ is the official Linux Bluetooth stack.

### Installation

```bash
bfsos install bluez
```

### Configuration

```bash
# Enable the BlueZ OpenRC service
sudo rc-update add bluez default

# Start BlueZ
sudo rc-service bluez start
```

### Configuration File

Edit `/etc/bluetooth/main.conf`:

```ini
[General]
Name = StormFS
Class = 0x000100
DiscoverableTimeout = 0

[Policy]
AutoEnable = true

[Adapter]
Discoverable = true
```

## Bluetooth Management

### bluetoothctl

The main Bluetooth management tool:

```bash
# Start bluetoothctl
bluetoothctl

# Inside bluetoothctl:
power on
agent on
discoverable on
scan on
```

### Pairing Devices

```bash
# In bluetoothctl:
devices                    # List devices
pair XX:XX:XX:XX:XX:XX    # Pair with device
connect XX:XX:XX:XX:XX:XX # Connect to device
trust XX:XX:XX:XX:XX:XX   # Trust device
```

### Audio Devices

```bash
# Connect audio device
bluetoothctl connect XX:XX:XX:XX:XX:XX

# Set as audio sink
bluetoothctl audio sink XX:XX:XX:XX:XX:XX
```

## Bluetooth Audio

### PulseAudio Bluetooth

```bash
# Load Bluetooth module
pactl load-module module-bluetooth-discover

# List Bluetooth sinks
pactl list sinks short
```

### PipeWire Bluetooth

PipeWire handles Bluetooth automatically:

```bash
# Check Bluetooth devices
pw-dump | grep bluetooth
```

## File Transfer

### OBEX

OBEX support is normally provided by the BlueZ/desktop D-Bus services rather than a separate `obex` OpenRC service in this port tree. Start BlueZ and the desktop session bus first:

```bash
sudo rc-update add dbus boot
sudo rc-update add bluez default
sudo rc-service dbus start
sudo rc-service bluez start
```

Check that the OBEX client is available before using it:

```bash
command -v bluetooth-sendto
command -v obexctl 2>/dev/null || true
```

### Send Files

```bash
# Using bluetooth-sendto
bluetooth-sendto --device=XX:XX:XX:XX:XX:XX file.txt
```

## Tethering

### Phone Tethering

```bash
# Connect phone
bluetoothctl connect XX:XX:XX:XX:XX:XX

# Enable tethering
bluetoothctl network/server enable
```

## Troubleshooting

### Device Not Found

1. Check Bluetooth is on:
   ```bash
   bluetoothctl show
   ```

2. Check adapter:
   ```bash
   hciconfig
   ```

3. Reset adapter:
   ```bash
   sudo hciconfig hci0 reset
   ```

### Connection Issues

1. Remove and re-pair device
2. Check battery level
3. Check distance/interference

## Next Steps

After Bluetooth configuration, proceed to [Chapter 13: Remote Desktop](chapters/13-remote-desktop.md) to configure remote desktop.
