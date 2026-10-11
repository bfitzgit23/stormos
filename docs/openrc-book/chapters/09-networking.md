# Chapter 9: Networking

## Overview

This chapter covers network configuration with OpenRC. The examples use the StormFS service names: `networkmanager`, `dhcpcd`, `iwd`, `wpa_supplicant`, and `nftables`. Run only one primary network manager at a time.

## OpenRC Network Bootstrap

Start the services common to a desktop or laptop installation:

```bash
bfsos install openrc-init-scripts dbus openresolv
rc-update add dbus boot
rc-update add networking boot 2>/dev/null || true
rc-status --all
```

Use either NetworkManager, or the lower-level `dhcpcd`/`iwd` path below. Do not enable both NetworkManager and an independent DHCP manager for the same interface.

## NetworkManager

NetworkManager is the recommended network manager for desktop systems.

### Installation

```bash
bfsos install networkmanager
```

### Configuration

```bash
# Enable the StormFS OpenRC service
sudo rc-update add networkmanager default

# Start NetworkManager
sudo rc-service networkmanager start
```

### Usage

```bash
# List connections
nmcli connection show

# Connect to WiFi
nmcli device wifi connect "SSID" password "PASSWORD"

# Show status
nmcli general status
```

## dhcpcd

dhcpcd is a lightweight DHCP client.

### Installation

```bash
bfsos install dhcpcd
```

### Configuration

```bash
# Enable dhcpcd after the network configuration is available
sudo rc-update add dhcpcd default

# Start dhcpcd
sudo rc-service dhcpcd start
```

### Manual Configuration

```bash
# Request IP address
sudo dhcpcd eth0

# Release IP address
sudo dhcpcd -k eth0
```

## wpa_supplicant

wpa_supplicant handles WiFi authentication.

### Installation

```bash
bfsos install wpa_supplicant
```

### Configuration

Create `/etc/wpa_supplicant/wpa_supplicant.conf` (the OpenRC port installs this path):

```bash
ctrl_interface=DIR=/run/wpa_supplicant GROUP=wheel
update_config=1

network={
    ssid="your-network-name"
    psk="your-password"
}
```

### Enable and Start

```bash
# Enable wpa_supplicant (use this instead of iwd)
sudo rc-update add wpa_supplicant default

# Start wpa_supplicant
sudo rc-service wpa_supplicant start
```

## Static IP Configuration

### Using /etc/conf.d/net

```bash
# /etc/conf.d/net

# Interface configuration
config_eth0="192.168.1.100/24"
routes_eth0="default via 192.168.1.1"
dns_servers_eth0="8.8.8.8 8.8.4.4"
```

### Enable Network Script

```bash
# Configure the interface through the OpenRC networking service
# /etc/conf.d/net contains config_eth0, routes_eth0, and dns_servers_eth0
sudo rc-update add networking boot

# Start the configured interface
sudo rc-service networking restart
```

## Firewall Configuration

### nftables

```bash
# Install nftables
bfsos install nftables

# Enable nftables before the normal network services
sudo rc-update add nftables boot

# Create ruleset
sudo nano /etc/nftables.nft

# Start nftables
sudo rc-service nftables start
```

### Example Ruleset

```bash
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Allow loopback
        iif "lo" accept
        
        # Allow established connections
        ct state established,related accept
        
        # Allow SSH
        tcp dport 22 accept
        
        # Allow ICMP
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }
    
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
```

## DNS Configuration

### Using resolvconf

```bash
# Install the StormFS resolver framework
bfsos install openresolv

# Configure DNS servers
sudo ln -sf /run/resolvconf/resolv.conf /etc/resolv.conf
sudo resolvconf -u
```

### Using /etc/resolv.conf

```bash
# /etc/resolv.conf
nameserver 8.8.8.8
nameserver 8.8.4.4
search example.com
```

## Next Steps

After networking configuration, proceed to [Chapter 10: Display Managers](chapters/10-display-managers.md) to configure display managers.
