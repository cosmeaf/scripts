#!/bin/bash

# Exit on errors, undefined variables, or pipeline failures
set -euo pipefail

# Trap errors for better debugging
trap 'echo "[ERROR] Line $LINENO: Command failed with exit code $?. Aborting." >&2; exit 1' ERR

# Constants
LOG_FILE="/var/log/docker-cleanup.log"
BACKUP_DIR="/opt/docker-backup-$(date '+%Y%m%d-%H%M%S')"

# Function to log messages
log() {
    local level=$1
    local message=$2
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "$LOG_FILE"
}

# Check if Docker is installed
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "INFO" "Docker is not installed. No cleanup needed."
        exit 0
    fi
    log "INFO" "Docker found. Proceeding with cleanup."
}

# Backup important Docker data
backup_docker_data() {
    log "INFO" "Creating backup of Docker data in $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    if [ -d "/var/lib/docker" ]; then
        cp -r /var/lib/docker "$BACKUP_DIR/docker-data" 2>/dev/null || log "WARN" "Failed to back up /var/lib/docker."
    fi
    if [ -f "/var/log/setup-containers.log" ]; then
        cp /var/log/setup-containers.log "$BACKUP_DIR/setup-containers.log" 2>/dev/null || log "WARN" "Failed to back up /var/log/setup-containers.log."
    fi
    if [ -f "/etc/pdinfinita/credentials.env" ]; then
        cp /etc/pdinfinita/credentials.env "$BACKUP_DIR/credentials.env" 2>/dev/null || log "WARN" "Failed to back up /etc/pdinfinita/credentials.env."
    fi
    log "INFO" "Backup completed in $BACKUP_DIR."
}

# Stop and remove all containers
clean_containers() {
    log "INFO" "Stopping and removing all containers..."
    docker ps -a -q | xargs -r docker stop >/dev/null 2>&1 || log "WARN" "No containers to stop."
    docker ps -a -q | xargs -r docker rm >/dev/null 2>&1 || log "WARN" "No containers to remove."
    log "INFO" "All containers stopped and removed."
}

# Remove all images
clean_images() {
    log "INFO" "Removing all Docker images..."
    docker images -a -q | sort -u | xargs -r docker rmi -f >/dev/null 2>&1 || log "WARN" "No images to remove."
    log "INFO" "All Docker images removed."
}

# Remove all volumes
clean_volumes() {
    log "INFO" "Removing all Docker volumes..."
    docker volume ls -q | xargs -r docker volume rm >/dev/null 2>&1 || log "WARN" "No volumes to remove."
    log "INFO" "All Docker volumes removed."
}

# Remove all networks
clean_networks() {
    log "INFO" "Removing all Docker networks..."
    docker network ls -q | grep -v -E 'bridge|host|none' | xargs -r docker network rm >/dev/null 2>&1 || log "WARN" "No custom networks to remove."
    log "INFO" "All custom Docker networks removed."
}

# Clean up logs and configuration files
clean_logs_configs() {
    log "INFO" "Cleaning up Docker-related logs and configs..."
    [ -f "/var/log/setup-containers.log" ] && rm -f /var/log/setup-containers.log && log "INFO" "Removed /var/log/setup-containers.log."
    [ -f "/var/log/setup-nginx.log" ] && rm -f /var/log/setup-nginx.log && log "INFO" "Removed /var/log/setup-nginx.log."
    [ -f "/etc/pdinfinita/credentials.env" ] && rm -f /etc/pdinfinita/credentials.env && log "INFO" "Removed /etc/pdinfinita/credentials.env."
    [ -d "/etc/pdinfinita" ] && rmdir /etc/pdinfinita 2>/dev/null && log "INFO" "Removed /etc/pdinfinita directory."
    log "INFO" "Logs and configuration files cleaned."
}

# Optional: Uninstall Docker (commented out for safety)
uninstall_docker() {
    log "INFO" "Uninstalling Docker (uncomment to enable)..."
    # systemctl stop docker docker.socket
    # apt-get purge -y docker.io docker-ce docker-ce-cli containerd
    # rm -rf /var/lib/docker /etc/docker
    # log "INFO" "Docker uninstalled."
}

# Main execution
log "INFO" "Starting full Docker cleanup..."

# Create log file
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Execute cleanup steps
check_docker
backup_docker_data
clean_containers
clean_images
clean_volumes
clean_networks
clean_logs_configs
# uninstall_docker  # Uncomment to enable Docker uninstallation

log "OK" "Docker cleanup completed successfully! Backup saved in $BACKUP_DIR."