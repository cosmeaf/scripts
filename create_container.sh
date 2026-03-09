#!/usr/bin/env bash
# Script refatorado - ambiente pdinfinita.app com logins e senhas explícitos
# Uso: chmod +x setup-pdinfinita.sh && ./setup-pdinfinita.sh

set -euo pipefail

trap 'echo "[ERRO] Linha $LINENO: Comando falhou (código $?)" >&2; exit 1' ERR

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURAÇÕES - MUDE AS SENHAS PARA VALORES REAIS E FORTES!
# ──────────────────────────────────────────────────────────────────────────────
readonly DOMAIN="pdinfinita.app"

readonly ADMIN_EMAIL="admin@${DOMAIN}"
readonly ADMIN_PASS="pdadmin@2026"

readonly MINIO_USER="${ADMIN_EMAIL}"
readonly MINIO_PASS="${ADMIN_PASS}"

readonly MYSQL_ROOT_PASS="${ADMIN_PASS}"
readonly MYSQL_USER="pdadmin"
readonly MYSQL_USER_PASS="${ADMIN_PASS}"

readonly POSTGRES_SUPERUSER="postgres"
readonly POSTGRES_SUPERUSER_PASS="${ADMIN_PASS}"
readonly POSTGRES_APP_USER="pdadmin"
readonly POSTGRES_APP_PASS="${ADMIN_PASS}"
readonly POSTGRES_DB="pdinfinita_db"

readonly PGADMIN_EMAIL="${ADMIN_EMAIL}"
readonly PGADMIN_PASS="${ADMIN_PASS}"

readonly LOG_FILE="/var/log/setup-pdinfinita-containers.log"

# ──────────────────────────────────────────────────────────────────────────────
# FUNÇÕES
# ──────────────────────────────────────────────────────────────────────────────
log() {
    local level="$1" msg="$2"
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$LOG_FILE"
}

check_port() {
    local port="$1"
    if ss -tuln | grep -q "[: ]${port}[[:space:]]"; then
        log "ERRO" "Porta ${port} já está em uso. Libere antes de continuar."
        exit 1
    fi
}

check_and_remove_container() {
    local name="$1"
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        log "INFO" "Container ${name} existe. Removendo..."
        docker stop "${name}" >/dev/null 2>&1 || true
        docker rm -f "${name}" >/dev/null 2>&1 || true
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# INÍCIO
# ──────────────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
touch "$LOG_FILE" && chmod 644 "$LOG_FILE"
log "INFO" "Iniciando configuração do ambiente pdinfinita.app"

# Verifica portas
log "INFO" "Verificando portas..."
check_port 9002   # MinIO API
check_port 9003   # MinIO Console
check_port 3307   # MySQL
check_port 5433   # PostgreSQL
check_port 9000   # Portainer
check_port 8080   # phpMyAdmin
check_port 8081   # pgAdmin
check_port 6380   # Redis

# Limpa containers antigos
log "INFO" "Removendo containers antigos..."
for c in redis-central minio mysql postgres portainer phpmyadmin pgadmin; do
    check_and_remove_container "$c"
done

# Cria network
log "INFO" "Criando/verficando network docker_network..."
docker network create --subnet=172.20.0.0/16 docker_network 2>/dev/null || true

# Cria volumes
log "INFO" "Criando volumes..."
for v in minio-data mysql-data postgres-data portainer-data redis-central-data pgadmin-data; do
    docker volume create "$v" 2>/dev/null || true
done

# Atualiza imagens
log "INFO" "Atualizando imagens..."
docker pull minio/minio:latest           >/dev/null
docker pull mysql:9.1                    >/dev/null
docker pull postgres:17-alpine           >/dev/null
docker pull portainer/portainer-ce:latest >/dev/null
docker pull phpmyadmin:latest            >/dev/null
docker pull dpage/pgadmin4:latest        >/dev/null
docker pull redis:7-alpine               >/dev/null

# ──────────────────────────────────────────────────────────────────────────────
# CRIANDO CONTAINERS
# ──────────────────────────────────────────────────────────────────────────────
log "INFO" "Criando Redis central..."
docker run -d --name redis-central \
  --hostname redis-central-pdinfinita \
  --restart unless-stopped \
  -p 6380:6379 \
  -v redis-central-data:/data \
  --network docker_network \
  --ip 172.20.0.8 \
  redis:7-alpine redis-server --save 60 1 --loglevel warning

log "INFO" "Criando MinIO..."
docker run -d --name minio \
  --hostname minio-pdinfinita \
  --restart unless-stopped \
  -p 9002:9000 -p 9003:9001 \
  -v minio-data:/data \
  -e "MINIO_ROOT_USER=${MINIO_USER}" \
  -e "MINIO_ROOT_PASSWORD=${MINIO_PASS}" \
  -e "MINIO_DOMAIN=minio.${DOMAIN}" \
  --network docker_network \
  --ip 172.20.0.2 \
  minio/minio:latest server /data --console-address ":9001"

log "INFO" "Criando MySQL (root + usuário pdadmin)..."
docker run -d --name mysql \
  --hostname mysql-pdinfinita \
  --restart unless-stopped \
  -p 3307:3306 \
  -v mysql-data:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASS}" \
  -e MYSQL_DATABASE="${POSTGRES_DB}" \
  -e MYSQL_USER="${MYSQL_USER}" \
  -e MYSQL_PASSWORD="${MYSQL_USER_PASS}" \
  --network docker_network \
  --ip 172.20.0.3 \
  mysql:9.1

log "INFO" "Criando PostgreSQL (superuser postgres + usuário pdadmin)..."
docker run -d --name postgres \
  --hostname postgres-pdinfinita \
  --restart unless-stopped \
  -p 5433:5432 \
  -v postgres-data:/var/lib/postgresql/data \
  -e POSTGRES_USER="${POSTGRES_SUPERUSER}" \
  -e POSTGRES_PASSWORD="${POSTGRES_SUPERUSER_PASS}" \
  -e POSTGRES_DB="${POSTGRES_DB}" \
  --network docker_network \
  --ip 172.20.0.4 \
  postgres:17-alpine

# Nota: para conectar com pdadmin, rode manualmente após o container subir:
# docker exec -it postgres psql -U postgres -c "CREATE USER ${POSTGRES_APP_USER} WITH PASSWORD '${POSTGRES_APP_PASS}'; GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_APP_USER};"

log "INFO" "Criando Portainer..."
docker run -d --name portainer \
  --hostname portainer-pdinfinita \
  --restart unless-stopped \
  -p 9000:9000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer-data:/data \
  --network docker_network \
  --ip 172.20.0.10 \
  portainer/portainer-ce:latest

log "INFO" "Criando phpMyAdmin..."
docker run -d --name phpmyadmin \
  --hostname phpmyadmin-pdinfinita \
  --restart unless-stopped \
  -p 8080:80 \
  -e PMA_HOST=mysql \
  --network docker_network \
  --ip 172.20.0.6 \
  phpmyadmin:latest

log "INFO" "Criando pgAdmin..."
docker run -d --name pgadmin \
  --hostname pgadmin-pdinfinita \
  --restart unless-stopped \
  -p 8081:80 \
  -e PGADMIN_DEFAULT_EMAIL="${PGADMIN_EMAIL}" \
  -e PGADMIN_DEFAULT_PASSWORD="${PGADMIN_PASS}" \
  -v pgadmin-data:/var/lib/pgadmin \
  --network docker_network \
  --ip 172.20.0.7 \
  dpage/pgadmin4:latest

# ──────────────────────────────────────────────────────────────────────────────
# VERIFICAÇÃO FINAL
# ──────────────────────────────────────────────────────────────────────────────
log "INFO" "Aguardando inicialização (45 segundos)..."
sleep 45

log "SUCESSO" "Ambiente iniciado! Status:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

log "INFO" "Portas escutando no host:"
ss -tuln | grep -E ':(900[0-3]|330[67]|5433|808[01]|6380)' || true

log "INFO" "Credenciais de acesso (use essas para conectar):"
echo ""
echo "• MinIO:"
echo "  Console: http://localhost:9003"
echo "  Usuário: ${MINIO_USER}"
echo "  Senha:   ${MINIO_PASS}"
echo ""
echo "• MySQL:"
echo "  Host: localhost:3307"
echo "  Root: root / ${MYSQL_ROOT_PASS}"
echo "  App user: ${MYSQL_USER} / ${MYSQL_USER_PASS}"
echo ""
echo "• PostgreSQL:"
echo "  Host: localhost:5433"
echo "  Superuser: ${POSTGRES_SUPERUSER} / ${POSTGRES_SUPERUSER_PASS}"
echo "  App user (crie manualmente se necessário): ${POSTGRES_APP_USER} / ${POSTGRES_APP_PASS}"
echo "  DB: ${POSTGRES_DB}"
echo ""
echo "• phpMyAdmin: http://localhost:8080   → use root / ${MYSQL_ROOT_PASS}"
echo "• pgAdmin:    http://localhost:8081   → use ${PGADMIN_EMAIL} / ${PGADMIN_PASS}"
echo "• Portainer:  http://localhost:9000"
echo "• Redis:      localhost:6380 (sem senha por padrão)"
echo ""

log "INFO" "Finalizado. Verifique logs se houver problemas."