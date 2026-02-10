#!/bin/bash
# Install PostgreSQL 18 in chroot environment
set -e

echo "Installing PostgreSQL 18..."

# Add PostgreSQL APT repository
apt-get install -y wget ca-certificates gnupg

# Add PostgreSQL repository key
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg

# Add PostgreSQL repository
echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

# Update package lists
apt-get update

# Install PostgreSQL 18
apt-get install -y postgresql-18 postgresql-client-18 postgresql-contrib-18

# Configure PostgreSQL for local development
# Allow local connections without password for development
sed -i 's/peer/trust/g' /etc/postgresql/18/main/pg_hba.conf
sed -i 's/md5/trust/g' /etc/postgresql/18/main/pg_hba.conf

# Enable and start PostgreSQL service
systemctl enable postgresql

echo "PostgreSQL 18 installed successfully"
