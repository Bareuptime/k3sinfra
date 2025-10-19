#!/bin/bash
set -euo pipefail

echo "Installing PostgreSQL with pgvector support..."

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "Cannot detect OS"
    exit 1
fi

# Install PostgreSQL
case $OS in
    ubuntu|debian)
        echo "Installing on Ubuntu/Debian..."
        sudo apt update
        sudo apt install -y postgresql postgresql-contrib postgresql-server-dev-all git build-essential
        ;;
    centos|rhel|rocky|almalinux)
        echo "Installing on CentOS/RHEL..."
        sudo dnf install -y postgresql-server postgresql-contrib postgresql-devel git gcc make
        sudo postgresql-setup --initdb
        ;;
    *)
        echo "Unsupported OS: $OS"
        exit 1
        ;;
esac

# Start and enable PostgreSQL
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Install pgvector
echo "Installing pgvector extension..."
cd /tmp
git clone --branch v0.7.4 https://github.com/pgvector/pgvector.git
cd pgvector
make
sudo make install

# Configure PostgreSQL
echo "Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS vector;"

# Create application user (prompt for password)
read -p "Enter database name [bareuptime]: " DB_NAME
DB_NAME=${DB_NAME:-bareuptime}

read -p "Enter database user [bareuptime]: " DB_USER
DB_USER=${DB_USER:-bareuptime}

read -sp "Enter database password: " DB_PASS
echo

sudo -u postgres psql <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER $DB_USER WITH ENCRYPTED PASSWORD '$DB_PASS';
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
\c $DB_NAME
CREATE EXTENSION IF NOT EXISTS vector;
EOF

echo "PostgreSQL installed successfully!"
echo "Connection string: postgresql://$DB_USER:$DB_PASS@localhost:5432/$DB_NAME"

# Save connection info
cat > postgres-info.txt <<EOF
PostgreSQL Installation Info
=============================
Database: $DB_NAME
User: $DB_USER
Password: $DB_PASS
Host: localhost
Port: 5432

Connection String:
postgresql://$DB_USER:$DB_PASS@localhost:5432/$DB_NAME

Extensions Installed:
- pgvector (v0.7.4)
EOF

echo "Connection info saved to postgres-info.txt"
