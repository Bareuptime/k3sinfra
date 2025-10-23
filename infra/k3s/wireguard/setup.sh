#!/bin/bash
set -euo pipefail

WG_NET="10.10.85.0/24"
POD_NET="10.42.0.0/16"
WG_IF="nm-wg0"

# Function to add route + NAT
add_rules() {
  echo "🚀 Adding route and NAT rules for K3s pods → WireGuard network"

  # 1. Add route
  if ! ip route show | grep -q "$WG_NET"; then
    ip route add "$WG_NET" dev "$WG_IF"
    echo "✅ Added route: $WG_NET via $WG_IF"
  else
    echo "⚠️ Route for $WG_NET already exists, skipping"
  fi

  # 2. Add NAT masquerade rule
  if ! iptables -t nat -C POSTROUTING -s "$POD_NET" -d "$WG_NET" -o "$WG_IF" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$POD_NET" -d "$WG_NET" -o "$WG_IF" -j MASQUERADE
    echo "✅ Added NAT masquerade rule for pods → WireGuard"
  else
    echo "⚠️ NAT rule already exists, skipping"
  fi

  # 3. Enable IP forwarding
  sysctl -w net.ipv4.ip_forward=1 > /dev/null
  echo "✅ IP forwarding enabled"

  echo ""
  echo "🔎 Current route:"
  ip route | grep "$WG_NET" || echo "❌ Route not found!"
  echo ""
  echo "🔎 Current NAT rules:"
  iptables -t nat -L POSTROUTING -n --line-numbers | grep "$WG_NET" || echo "❌ NAT rule not found!"
  echo ""
  echo "✅ Setup complete."
}

# Function to rollback (delete rules)
rollback() {
  echo "🔄 Rolling back route and NAT rules..."

  # Remove route
  if ip route show | grep -q "$WG_NET"; then
    ip route del "$WG_NET" dev "$WG_IF" || true
    echo "✅ Removed route for $WG_NET"
  else
    echo "⚠️ Route for $WG_NET not found"
  fi

  # Remove NAT rule
  if iptables -t nat -C POSTROUTING -s "$POD_NET" -d "$WG_NET" -o "$WG_IF" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -D POSTROUTING -s "$POD_NET" -d "$WG_NET" -o "$WG_IF" -j MASQUERADE
    echo "✅ Removed NAT rule for pods → WireGuard"
  else
    echo "⚠️ NAT rule not found"
  fi

  # Disable IP forwarding
  sysctl -w net.ipv4.ip_forward=0 > /dev/null
  echo "✅ Disabled IP forwarding"
  echo ""
  echo "🧹 Rollback complete."
}

# Function to test connectivity from node
test_connection() {
  echo "🔍 Testing connectivity to DB host (10.10.85.1:5432)..."
  if nc -zv 10.10.85.1 5432 >/dev/null 2>&1; then
    echo "✅ Node can reach 10.10.85.1:5432"
  else
    echo "❌ Connection failed — check WireGuard tunnel or firewall."
  fi
}

# Main menu
echo "==========================================="
echo " K3s ↔ Netmaker Route Management Script"
echo "==========================================="
echo "1) Add route + NAT rules"
echo "2) Roll back (remove rules)"
echo "3) Test connectivity"
echo "4) Exit"
echo "-------------------------------------------"
read -rp "Choose an option [1-4]: " choice

case "$choice" in
  1)
    add_rules
    ;;
  2)
    rollback
    ;;
  3)
    test_connection
    ;;
  4)
    echo "👋 Exiting"
    exit 0
    ;;
  *)
    echo "❌ Invalid option"
    exit 1
    ;;
esac
