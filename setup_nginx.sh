#!/bin/bash

# Exit on errors, undefined variables, or pipeline failures
set -euo pipefail

# Trap errors for better debugging
trap 'echo "[ERROR] Line $LINENO: Command failed with exit code $?. Aborting." >&2; exit 1' ERR

# Constants
LOG_FILE="/var/log/setup-nginx.log"
NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_CONF_FILE="$NGINX_CONF_DIR/pdinfinita.conf"
SSL_DIR="/etc/nginx/ssl"
SSL_KEY="$SSL_DIR/pdinfinita.key"
SSL_CERT="$SSL_DIR/pdinfinita.crt"
NETWORK_NAME="docker_network"
NETWORK_SUBNET="172.20.0.0/16"
DOMAIN="pdinfinita.app"
NGINX_IP="172.20.0.11"

# Function to log messages
log() {
    local level=$1
    local message=$2
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "$LOG_FILE"
}

# Check if Docker is installed
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "ERROR" "Docker is not installed. Install Docker and try again."
        exit 1
    fi
    if ! systemctl is-active --quiet docker; then
        log "ERROR" "Docker service is not active. Starting..."
        systemctl start docker || { log "ERROR" "Failed to start Docker."; exit 1; }
    fi
}

# Check if a port is in use
check_port() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        log "ERROR" "Port $port is already in use. Please free the port or choose another."
        exit 1
    fi
}

# Check if container exists
check_container() {
    local container=$1
    if docker ps -a --format '{{.Names}}' | grep -q "^$container$"; then
        log "INFO" "Container $container already exists. Stopping and removing it."
        docker stop "$container" >/dev/null 2>&1 || true
        docker rm "$container" >/dev/null 2>&1 || true
    fi
}

# Create Nginx configuration
create_nginx_conf() {
    log "INFO" "Creating Nginx configuration file at $NGINX_CONF_FILE..."
    mkdir -p "$NGINX_CONF_DIR"
    cat > "$NGINX_CONF_FILE" << 'EOF'
# HTTP/HTTPS reverse proxy for web-based services
server {
    listen 80;
    server_name minio.pdinfinita.app;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name minio.pdinfinita.app;
    ssl_certificate /etc/nginx/ssl/pdinfinita.crt;
    ssl_certificate_key /etc/nginx/ssl/pdinfinita.key;
    location / {
        proxy_pass http://172.20.0.2:9003;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name portainer.pdinfinita.app;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name portainer.pdinfinita.app;
    ssl_certificate /etc/nginx/ssl/pdinfinita.crt;
    ssl_certificate_key /etc/nginx/ssl/pdinfinita.key;
    location / {
        proxy_pass http://172.20.0.10:9000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name phpmyadmin.pdinfinita.app;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name phpmyadmin.pdinfinita.app;
    ssl_certificate /etc/nginx/ssl/pdinfinita.crt;
    ssl_certificate_key /etc/nginx/ssl/pdinfinita.key;
    location / {
        proxy_pass http://172.20.0.6:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name pgadmin.pdinfinita.app;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name pgadmin.pdinfinita.app;
    ssl_certificate /etc/nginx/ssl/pdinfinita.crt;
    ssl_certificate_key /etc/nginx/ssl/pdinfinita.key;
    location / {
        proxy_pass http://172.20.0.7:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

# Optional TCP streams for non-HTTP services (uncomment if needed)
# stream {
#     upstream mysql {
#         server 172.20.0.3:3306;
#     }
#     server {
#         listen 3307;
#         proxy_pass mysql;
#     }
# }
#
# stream {
#     upstream postgres {
#         server 172.20.0.4:5432;
#     }
#     server {
#         listen 5433;
#         proxy_pass postgres;
#     }
# }
#
# stream {
#     upstream redis {
#         server 172.20.0.8:6379;
#     }
#     server {
#         listen 6380;
#         proxy_pass redis;
#     }
# }
EOF
    log "INFO" "Nginx configuration file created."
}

# Generate self-signed SSL certificate
generate_ssl_cert() {
    log "INFO" "Generating self-signed SSL certificate for *.pdinfinita.app..."
    mkdir -p "$SSL_DIR"
    if [ ! -f "$SSL_KEY" ] || [ ! -f "$SSL_CERT" ]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$SSL_KEY" \
            -out "$SSL_CERT" \
            -subj "/C=BR/ST=Sao Paulo/L=Sao Paulo/O=PDInfinita/OU=IT/CN=*.pdinfinita.app" >/dev/null 2>&1
        log "INFO" "Self-signed SSL certificate generated."
    else
        log "INFO" "SSL certificate and key already exist."
    fi
}

# Create Nginx container
create_nginx_container() {
    log "INFO" "Creating Nginx reverse proxy container..."
    check_container nginx-reverse-proxy
    docker run -d \
        --name nginx-reverse-proxy \
        --hostname nginx-pdinfinita \
        --restart unless-stopped \
        -p 80:80 \
        -p 443:443 \
        -v "$NGINX_CONF_DIR:/etc/nginx/conf.d" \
        -v "$SSL_DIR:/etc/nginx/ssl" \
        --network "$NETWORK_NAME" \
        --ip "$NGINX_IP" \
        nginx:latest >/dev/null
    log "INFO" "Nginx container created."
}

# Main execution
log "INFO" "Starting Nginx reverse proxy setup..."

# Create log file
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Check Docker and ports
check_docker
check_port 80
check_port 443

# Create network if not exists
log "INFO" "Checking network $NETWORK_NAME..."
docker network create --subnet="$NETWORK_SUBNET" "$NETWORK_NAME" >/dev/null 2>&1 || log "INFO" "Network $NETWORK_NAME already exists."

# Generate SSL certificate and Nginx config
generate_ssl_cert
create_nginx_conf

# Create Nginx container
create_nginx_container

# Verify Nginx
log "INFO" "Verifying Nginx container status..."
docker ps --filter "name=nginx-reverse-proxy" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

log "OK" "Nginx reverse proxy setup completed. Test access at https://<subdomain>.pdinfinita.app."
log "INFO" "Ensure DNS records for *.pdinfinita.app point to 147.93.32.77."
