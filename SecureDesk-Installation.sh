#!/bin/bash

set -e

echo "🔧 Starting SecureDesk setup..."

# --- Step 1: Get IP Address ---
IP=$(hostname -I | awk '{print $1}')
echo "🌐 Detected server IP: $IP"

# --- Step 2: Install Docker & Docker Compose ---
echo "📦 Installing Docker and Docker Compose..."
apt update -y
apt install -y docker.io docker-compose sqlite plocate 

systemctl enable docker
systemctl start docker

# --- Step 3: Stop Anything Using 443 or 80 ---
echo "🚫 Stopping services on ports 443 and 80 if occupied..."
fuser -k 443/tcp || true
fuser -k 80/tcp || true

# --- Step 4: Create docker-compose.yml ---
echo "🛠️ Creating docker-compose.yml..."

mkdir -p /opt/securedesk
cd /opt/securedesk

cat <<EOF > docker-compose.yml
version: '3.8'

services:
  remotely:
    image: immybot/remotely:latest
    container_name: securedesk
    restart: unless-stopped
    volumes:
      - ./remotely-data:/remotely-data
    environment:
      - ASPNETCORE_URLS=http://+:5000
    networks:
      - internal

  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "443:443"
    volumes:
      - ./caddy_data:/data
      - ./caddy_config:/config
      - ./Caddyfile:/etc/caddy/Caddyfile
    networks:
      - internal

networks:
  internal:
    driver: bridge
EOF

# --- Step 5: Create Caddyfile ---
echo "🌍 Configuring Caddy with server IP..."

cat <<EOF > Caddyfile
https://$IP {
    reverse_proxy remotely:5000
    tls internal
}
EOF

# --- Step 6: Launch SecureDesk ---
echo "🚀 Starting SecureDesk with Docker Compose..."
docker-compose up -d

echo ""
echo "✅ Remotely is now accessible at: https://$IP"
echo "🔐 Using internal TLS certificate via Caddy"
