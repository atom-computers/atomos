#!/bin/bash
# Install SurrealDB in chroot environment
set -euo pipefail

echo "Installing SurrealDB..."

# Install dependencies
apt-get install -y curl

# Download and install SurrealDB binary
curl -sSf https://install.surrealdb.com | sh

if [ ! -x /usr/local/bin/surreal ]; then
    echo "FATAL: SurrealDB binary not found at /usr/local/bin/surreal after install"
    exit 1
fi
chmod +x /usr/local/bin/surreal

# Create SurrealDB data directory
mkdir -p /var/lib/surrealdb

# Create systemd service file
cat > /etc/systemd/system/surrealdb.service << 'EOF'
[Unit]
Description=SurrealDB Database
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/surreal start --log trace --user root --pass root surrealkv:///var/lib/surrealdb/data.db
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Enable SurrealDB service
systemctl enable surrealdb

# Temporarily start SurrealDB to apply the initial schema
echo "Initializing SurrealDB schema..."
/usr/local/bin/surreal start --user root --pass root surrealkv:///var/lib/surrealdb/data.db &
SURREAL_PID=$!

# Wait for SurrealDB to be ready
until curl -s http://localhost:8000/health; do
  echo "Waiting for SurrealDB to start..."
  sleep 1
done

# Ensure the atomos database exists (SurrealDB v3 import does not always auto-create it)
curl -sf -X POST http://localhost:8000/sql \
  -H 'Authorization: Basic cm9vdDpyb290' \
  -H 'Accept: application/json' \
  -H 'surreal-ns: atomos' \
  -d 'DEFINE DATABASE IF NOT EXISTS atomos;'
echo ""

# All tables live in a single database: atomos/atomos
/usr/local/bin/surreal import --endpoint http://localhost:8000 --user root --pass root --ns atomos --db atomos /tmp/atomos-install/core/atomos-db/migrations/0001_initial_schema.surql
/usr/local/bin/surreal import --endpoint http://localhost:8000 --user root --pass root --ns atomos --db atomos /tmp/atomos-install/core/atomos-db/migrations/0002_tool_registry.surql

# Kill the background SurrealDB process
kill $SURREAL_PID
wait $SURREAL_PID || true

echo "SurrealDB installed successfully"
