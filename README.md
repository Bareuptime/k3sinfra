# BareUptime Infrastructure & K3s Networking

This repository contains infrastructure setup and networking utilities for the BareUptime application, including K3s cluster management and WireGuard network integration via Netmaker.

## Repository Structure

```
.
├── apps/                      # Application deployments
├── infra/                     # Infrastructure setup scripts
├── k3s-netmaker-route.sh     # K3s ↔ Netmaker networking script (THIS FILE)
├── gcr-cleanup.sh            # GHCR container cleanup utility
└── README.md                 # This file
```

## K3s ↔ Netmaker Route Management Script

### 🎯 Purpose

The `k3s-netmaker-route.sh` script solves a critical networking challenge when running K3s (lightweight Kubernetes) alongside Netmaker (WireGuard mesh networking). It enables K3s pods to communicate with services running on remote networks accessed through WireGuard tunnels.

### 🔧 What It Does

This script manages the networking bridge between:
- **K3s Pod Network** (`10.42.0.0/16`) - Default K3s pod CIDR
- **WireGuard Network** (`10.10.85.0/24`) - Netmaker-managed WireGuard mesh network

**Key Functions:**
1. **Route Management** - Adds/removes routes for WireGuard network traffic
2. **NAT Configuration** - Sets up iptables masquerade rules for proper packet forwarding
3. **IP Forwarding** - Enables kernel IP forwarding
4. **Connectivity Testing** - Tests connection to remote database services

### 🚀 Why It's Required

#### The Problem

When K3s pods need to connect to external services (like databases) that are only accessible through WireGuard tunnels:

```
K3s Pod (10.42.x.x) → wants to reach → Database (10.10.85.1:5432)
                                           ↑
                                    Only accessible via WireGuard
```

Without proper routing and NAT rules:
- ❌ K3s pods cannot reach WireGuard network destinations
- ❌ Return packets don't know how to route back to pods
- ❌ Applications fail to connect to external services

#### The Solution

This script creates the necessary network plumbing:

```
K3s Pod (10.42.x.x) → K3s Node → WireGuard Interface (nm-wg0) → Database (10.10.85.1:5432)
                         ↑                    ↑
                   NAT masquerade      Route via WireGuard
```

### 📋 Prerequisites

#### System Requirements
- **Linux server** running K3s
- **Root privileges** (script modifies routing and iptables)
- **Netmaker client** installed and connected
- **WireGuard interface** active (default: `nm-wg0`)

#### Network Tools
```bash
# Required packages
sudo apt update
sudo apt install -y iptables iproute2 netcat-openbsd
```

#### Netmaker Setup
Ensure your Netmaker client is:
1. **Installed** and **configured**
2. **Connected** to the mesh network
3. **WireGuard interface** (`nm-wg0`) is **active**

Verify with:
```bash
ip addr show nm-wg0
ip route | grep nm-wg0
```

### 🔧 Configuration

The script uses these default network configurations:

```bash
WG_NET="10.10.85.0/24"    # WireGuard network (Netmaker mesh)
POD_NET="10.42.0.0/16"    # K3s pod network (default)
WG_IF="nm-wg0"            # WireGuard interface name
```

**Customization:**
If your networks differ, modify these variables at the top of the script:

```bash
# Example: Custom network ranges
WG_NET="192.168.100.0/24"   # Your WireGuard network
POD_NET="10.244.0.0/16"     # Your K3s pod network
WG_IF="wg0"                 # Your WireGuard interface name
```

### 🚀 Usage

#### Interactive Mode
```bash
sudo ./k3s-netmaker-route.sh
```

Choose from the menu:
```
===========================================
 K3s ↔ Netmaker Route Management Script
===========================================
1) Add route + NAT rules
2) Roll back (remove rules)  
3) Test connectivity
4) Exit
```

#### Direct Execution (for automation)
```bash
# Add rules
echo "1" | sudo ./k3s-netmaker-route.sh

# Test connectivity
echo "3" | sudo ./k3s-netmaker-route.sh

# Remove rules
echo "2" | sudo ./k3s-netmaker-route.sh
```

### 🔍 What Each Option Does

#### Option 1: Add Route + NAT Rules

**Creates the networking bridge:**

1. **Route Addition**
   ```bash
   ip route add 10.10.85.0/24 dev nm-wg0
   ```
   - Routes WireGuard network traffic through the WireGuard interface

2. **NAT Masquerade Rule**
   ```bash
   iptables -t nat -A POSTROUTING -s 10.42.0.0/16 -d 10.10.85.0/24 -o nm-wg0 -j MASQUERADE
   ```
   - Translates pod IP addresses to node IP for WireGuard traffic
   - Ensures return packets can find their way back to pods

3. **IP Forwarding**
   ```bash
   sysctl -w net.ipv4.ip_forward=1
   ```
   - Enables packet forwarding at the kernel level

#### Option 2: Roll Back (Remove Rules)

**Safely removes all networking changes:**
- Removes the WireGuard route
- Deletes the NAT masquerade rule  
- Disables IP forwarding

#### Option 3: Test Connectivity

**Verifies the setup works:**
```bash
nc -zv 10.10.85.1 5432  # Tests PostgreSQL connection
```

### 📊 Example Output

**Successful Setup:**
```bash
🚀 Adding route and NAT rules for K3s pods → WireGuard network
✅ Added route: 10.10.85.0/24 via nm-wg0
✅ Added NAT masquerade rule for pods → WireGuard  
✅ IP forwarding enabled

🔎 Current route:
10.10.85.0/24 dev nm-wg0 scope link

🔎 Current NAT rules:
1  MASQUERADE  tcp  --  10.42.0.0/16  10.10.85.0/24  0.0.0.0/0  tcp

✅ Setup complete.
```

**Connectivity Test:**
```bash
🔍 Testing connectivity to DB host (10.10.85.1:5432)...
✅ Node can reach 10.10.85.1:5432
```

### 🔧 Integration with K3s Applications

After running the script, your K3s applications can connect to WireGuard network services:

**Example: PostgreSQL Connection from Pod**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      containers:
      - name: app
        image: my-app:latest
        env:
        - name: DATABASE_URL
          value: "postgresql://user:pass@10.10.85.1:5432/db"
          # ↑ This will now work thanks to the routing script!
```

### 🚨 Troubleshooting

#### Common Issues

**1. "Route already exists" Warning**
```
⚠️ Route for 10.10.85.0/24 already exists, skipping
```
- **Not an error** - Route is already configured
- Script safely skips duplicate routes

**2. "Connection failed" Error**
```
❌ Connection failed — check WireGuard tunnel or firewall.
```
**Troubleshooting steps:**
```bash
# Check WireGuard interface status
ip addr show nm-wg0

# Check if WireGuard tunnel is active  
ping 10.10.85.1

# Check Netmaker connection
netmaker list

# Verify iptables rules
iptables -t nat -L POSTROUTING -n --line-numbers
```

**3. Permission Denied**
```bash
# Script must run as root
sudo ./k3s-netmaker-route.sh
```

**4. Interface Not Found**
```bash
# Check your WireGuard interface name
ip addr show | grep wg
# Update WG_IF variable if different than nm-wg0
```

#### Verification Commands

**Check routing:**
```bash
ip route | grep 10.10.85.0
```

**Check NAT rules:**
```bash
iptables -t nat -L POSTROUTING -n | grep 10.10.85.0
```

**Check IP forwarding:**
```bash
sysctl net.ipv4.ip_forward
```

**Test from pod:**
```bash
kubectl run test-pod --image=busybox --rm -it -- sh
# Inside pod:
nc -zv 10.10.85.1 5432
```

### 🔒 Security Considerations

#### Network Isolation
- Script only allows K3s pods to access WireGuard network
- No inbound access from WireGuard to K3s pods
- Maintains network segmentation

#### Firewall Rules
The NAT rule is specific and targeted:
```bash
# Only affects: K3s pods → WireGuard network
-s 10.42.0.0/16 -d 10.10.85.0/24 -o nm-wg0 -j MASQUERADE
```

#### Cleanup
Always run **Option 2 (rollback)** when:
- Testing is complete
- Removing K3s cluster
- Changing network configurations

### 🔄 Automation & Persistence

#### Systemd Service (Optional)

Create `/etc/systemd/system/k3s-netmaker-route.service`:

```ini
[Unit]
Description=K3s Netmaker Route Setup
After=k3s.service netmaker.service
Requires=k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'echo "1" | /path/to/k3s-netmaker-route.sh'
ExecStop=/bin/bash -c 'echo "2" | /path/to/k3s-netmaker-route.sh'

[Install]
WantedBy=multi-user.target
```

Enable the service:
```bash
sudo systemctl enable k3s-netmaker-route.service
sudo systemctl start k3s-netmaker-route.service
```

#### Startup Script Integration

Add to your server's startup sequence (e.g., `/etc/rc.local` or cron `@reboot`):
```bash
# Wait for services to start
sleep 30
echo "1" | /path/to/k3s-netmaker-route.sh
```

### 🏗️ Architecture Overview

```mermaid
graph TD
    A[K3s Pod<br/>10.42.x.x] --> B[K3s Node<br/>Routing Rules]
    B --> C[WireGuard Interface<br/>nm-wg0]
    C --> D[Netmaker Mesh<br/>10.10.85.0/24]
    D --> E[Remote Services<br/>Database, APIs, etc.]
    
    F[NAT Masquerade] --> B
    G[IP Forwarding] --> B
    
    style A fill:#e1f5fe
    style E fill:#f3e5f5
    style B fill:#fff3e0
```

### 📚 Related Documentation

- **Main Infrastructure**: See `/infra/README.md` for complete infrastructure setup
- **K3s Documentation**: https://k3s.io/
- **Netmaker Documentation**: https://docs.netmaker.org/
- **WireGuard**: https://www.wireguard.com/

### 🆘 Support

For issues with this script:
1. **Check Prerequisites** - Ensure K3s, Netmaker, and WireGuard are working
2. **Review Logs** - Check system logs for networking errors
3. **Test Manually** - Verify each component works independently
4. **Network Diagnosis** - Use `traceroute`, `ping`, `tcpdump` for debugging

### 📝 License

This script is part of the BareUptime infrastructure toolkit.

---

**⚡ Quick Start:**
```bash
# 1. Ensure Netmaker is connected
netmaker list

# 2. Run the script
sudo ./k3s-netmaker-route.sh

# 3. Choose option 1 to add rules
# 4. Choose option 3 to test connectivity
# 5. Deploy your K3s applications with WireGuard network access!
```
