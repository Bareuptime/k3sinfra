#!/bin/bash
set -euo pipefail

echo "Installing ClickHouse..."

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "Cannot detect OS"
    exit 1
fi

# Install ClickHouse
case $OS in
    ubuntu|debian)
        echo "Installing on Ubuntu/Debian..."
        sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
        curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' | sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" | sudo tee /etc/apt/sources.list.d/clickhouse.list
        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y clickhouse-server clickhouse-client
        ;;
    centos|rhel|rocky|almalinux)
        echo "Installing on CentOS/RHEL..."
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://packages.clickhouse.com/rpm/clickhouse.repo
        sudo yum install -y clickhouse-server clickhouse-client
        ;;
    *)
        echo "Unsupported OS: $OS"
        exit 1
        ;;
esac

# Start ClickHouse
sudo systemctl start clickhouse-server
sudo systemctl enable clickhouse-server

# Wait for ClickHouse to start
sleep 5

# Create user (prompt for password)
read -p "Enter ClickHouse user [default]: " CH_USER
CH_USER=${CH_USER:-default}

read -sp "Enter ClickHouse password: " CH_PASS
echo

# Create user and database
clickhouse-client --query "CREATE USER IF NOT EXISTS $CH_USER IDENTIFIED BY '$CH_PASS'"
clickhouse-client --query "GRANT ALL ON *.* TO $CH_USER"
clickhouse-client --user=$CH_USER --password=$CH_PASS --query "CREATE DATABASE IF NOT EXISTS bareuptime"

echo "ClickHouse installed successfully!"
echo "Connection: clickhouse://$CH_USER:$CH_PASS@localhost:9000/bareuptime"

# Save connection info
cat > clickhouse-info.txt <<EOF
ClickHouse Installation Info
============================
User: $CH_USER
Password: $CH_PASS
Host: localhost
HTTP Port: 8123
Native Port: 9000
Database: bareuptime

Connection String:
clickhouse://$CH_USER:$CH_PASS@localhost:9000/bareuptime

HTTP URL:
http://localhost:8123

Test Connection:
clickhouse-client --user=$CH_USER --password=$CH_PASS
EOF

echo "Connection info saved to clickhouse-info.txt"
