#!/bin/bash

# Exit on errors, undefined variables, or pipeline failures
set -euo pipefail

# Trap errors for better debugging
trap 'echo "[ERROR] Line $LINENO: Command failed with exit code $?. Aborting." >&2; exit 1' ERR

# Constants
LOG_FILE="/var/log/setup-containers.log"
CREDENTIALS_USER="admin@pdinfinita.com"
CREDENTIALS_PASS="pdadmin@2024"
DOMAIN="pdinfinita.com"

# Function to log messages
log() {
    local level=$1
    local message=$2
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "$LOG_FILE"
}

# Function to check if a port is in use
check_port() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        log "ERROR" "Port $port is already in use. Please free the port or choose another."
        exit 1
    fi
}

# Function to check if a container exists
check_container() {
    local container=$1
    if docker ps -a --format '{{.Names}}' | grep -q "^$container$"; then
        log "INFO" "Container $container already exists. Stopping and removing it."
        docker stop "$container" >/dev/null 2>&1 || true
        docker rm "$container" >/dev/null 2>&1 || true
    fi
}

# Function to clean up unused containers and images
cleanup_unused() {
    log "INFO" "Cleaning up unused containers..."
    docker container prune -f || log "WARN" "No unused containers to prune."
    log "INFO" "Cleaning up dangling images..."
    docker image prune -f || log "WARN" "No dangling images to prune."
}

# Create log file if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log "INFO" "Starting container setup..."

# Create custom network with subnet
log "INFO" "Creating custom network pdinfinita_network..."
docker network create --subnet=172.20.0.0/16 pdinfinita_network >/dev/null 2>&1 || log "INFO" "Network pdinfinita_network already exists."

# Clean up unused resources
cleanup_unused

# Validate ports
log "INFO" "Checking port availability..."
check_port 9002  # MinIO API
check_port 9003  # MinIO Console
check_port 3307  # MySQL
check_port 5433  # PostgreSQL
check_port 9000  # Portainer
check_port 8080  # phpMyAdmin
check_port 8081  # pgAdmin
check_port 6380  # Redis

# Validate containers
log "INFO" "Checking for existing containers..."
check_container minio
check_container mysql
check_container postgres
check_container portainer
check_container phpmyadmin
check_container pgadmin
check_container redis-central

# Create volumes
log "INFO" "Creating volumes..."
docker volume create minio-data >/dev/null 2>&1 || log "INFO" "Volume minio-data already exists."
docker volume create mysql-data >/dev/null 2>&1 || log "INFO" "Volume mysql-data already exists."
docker volume create postgres-data >/dev/null 2>&1 || log "INFO" "Volume postgres-data already exists."
docker volume create portainer-data >/dev/null 2>&1 || log "INFO" "Volume portainer-data already exists."
docker volume create redis-central-data >/dev/null 2>&1 || log "INFO" "Volume redis-central-data already exists."

# Pull images
log "INFO" "Pulling Docker images..."
docker pull minio/minio:latest >/dev/null
docker pull mysql:latest >/dev/null
docker pull postgres:latest >/dev/null
docker pull portainer/portainer-ce:latest >/dev/null
docker pull phpmyadmin:latest >/dev/null
docker pull dpage/pgadmin4:latest >/dev/null
docker pull redis:7-alpine >/dev/null

# Create containers
log "INFO" "Creating container Redis central..."
docker run -d \
  --name redis-central \
  --hostname redis-central-pdinfinita \
  --restart unless-stopped \
  -p 6380:6379 \
  -v redis-central-data:/data \
  --network pdinfinita_network \
  --ip 172.20.0.8 \
  redis:7-alpine >/dev/null

log "INFO" "Creating container MinIO..."
docker run -d \
  --name minio \
  --hostname minio-pdinfinita \
  --restart unless-stopped \
  -p 9002:9000 \
  -p 9003:9001 \
  -v minio-data:/data \
  -e MINIO_ROOT_USER="$CREDENTIALS_USER" \
  -e MINIO_ROOT_PASSWORD="$CREDENTIALS_PASS" \
  -e MINIO_DOMAIN="minio.$DOMAIN" \
  --network pdinfinita_network \
  --ip 172.20.0.2 \
  minio/minio:latest server /data --console-address ":9001" >/dev/null

log "INFO" "Creating container MySQL..."
docker run -d \
  --name mysql \
  --hostname mysql-pdinfinita \
  --restart unless-stopped \
  -p 3307:3306 \
  -v mysql-data:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD="$CREDENTIALS_PASS" \
  -e MYSQL_DATABASE="pdinfinita_db" \
  -e MYSQL_USER="$CREDENTIALS_USER" \
  -e MYSQL_PASSWORD="$CREDENTIALS_PASS" \
  --network pdinfinita_network \
  --ip 172.20.0.3 \
  mysql:latest >/dev/null

log "INFO" "Creating container PostgreSQL..."
docker run -d \
  --name postgres \
  --hostname postgres-pdinfinita \
  --restart unless-stopped \
  -p 5433:5432 \
  -v postgres-data:/var/lib/postgresql/data \
  -e POSTGRES_USER="$CREDENTIALS_USER" \
  -e POSTGRES_PASSWORD="$CREDENTIALS_PASS" \
  -e POSTGRES_DB="pdinfinita_db" \
  --network pdinfinita_network \
  --ip 172.20.0.4 \
  postgres:latest >/dev/null

log "INFO" "Creating container Portainer..."
docker run -d \
  --name portainer \
  --hostname portainer-pdinfinita \
  --restart unless-stopped \
  -p 9000:9000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer-data:/data \
  --network pdinfinita_network \
  --ip 172.20.0.10 \
  portainer/portainer-ce:latest >/dev/null

log "INFO" "Creating container phpMyAdmin..."
docker run -d \
  --name phpmyadmin \
  --hostname phpmyadmin-pdinfinita \
  --restart unless-stopped \
  -p 8080:80 \
  -e PMA_HOST="mysql" \
  --network pdinfinita_network \
  --ip 172.20.0.6 \
  phpmyadmin:latest >/dev/null

log "INFO" "Creating container pgAdmin..."
docker run -d \
  --name pgadmin \
  --hostname pgadmin-pdinfinita \
  --restart unless-stopped \
  -p 8081:80 \
  -e PGADMIN_DEFAULT_EMAIL="$CREDENTIALS_USER" \
  -e PGADMIN_DEFAULT_PASSWORD="$CREDENTIALS_PASS" \
  --network pdinfinita_network \
  --ip 172.20.0.7 \
  dpage/pgadmin4:latest >/dev/null

log "OK" "All containers created successfully!"

# Verify containers
log "INFO" "Verifying container status..."
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Verify network
log "INFO" "Verifying network configuration..."
docker network inspect pdinfinita_network

# Verify ports
log "INFO" "Verifying listening ports..."
ss -tuln | grep -E ':9002|:9003|:3307|:5433|:9000|:8080|:8081|:6380' || log "WARN" "Some ports may not be listening."

log "INFO" "Setup complete. Check Nginx configuration and restart Nginx."