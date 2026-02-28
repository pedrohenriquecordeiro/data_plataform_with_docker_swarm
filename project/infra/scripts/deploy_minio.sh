#!/usr/bin/env bash
# deploy_minio.sh — Idempotent deployment and configuration script for the MinIO stack.
# Creates Docker Swarm secrets, deploys the shared overlay network, deploys the MinIO
# stack, waits for it to be healthy and configures the initial buckets and policies.
# Usage: sudo bash scripts/deploy_minio.sh

# Exit immediately on error, treat unset variables as errors, fail on pipe errors
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Resolve project root (two levels up from this script's location)
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # Absolute path to this script's directory
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"               # Project root (data-platform/)

# ─────────────────────────────────────────────────────────────────────────────
# Logging helpers — consistent output format for all messages
# ─────────────────────────────────────────────────────────────────────────────
log_info() {
  echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') — $*"
}

log_warn() {
  echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') — $*"
}

log_error() {
  echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') — $*" >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# Configuration variables
# ─────────────────────────────────────────────────────────────────────────────
ENV_FILE="${PROJECT_ROOT}/.env"

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight: Verify Docker Swarm is active
# ─────────────────────────────────────────────────────────────────────────────
log_info "Checking Docker Swarm status..."
swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")
if [[ "${swarm_state}" != "active" ]]; then
  log_error "Docker Swarm is not active (state: ${swarm_state})."
  log_error "Initialize Swarm first: docker swarm init"
  exit 1
fi
log_info "Docker Swarm is active."

# ─────────────────────────────────────────────────────────────────────────────
# Load environment variables from .env file
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
  log_error ".env file not found at ${ENV_FILE}"
  log_error "Copy .env.example to .env and fill in values before deploying."
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"
log_info "Loaded environment variables from ${ENV_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Create Docker Swarm secrets (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
log_info "Step 1: Creating MinIO Docker Swarm secrets..."
create_secret_if_missing() {
  local secret_name="$1"
  local secret_value="$2"
  if docker secret inspect "${secret_name}" &>/dev/null; then
    log_warn "Secret '${secret_name}' already exists. Skipping creation."
  else
    echo -n "${secret_value}" | docker secret create "${secret_name}" -
    log_info "Secret '${secret_name}' created successfully."
  fi
}
create_secret_if_missing "minio_root_user" "${MINIO_WWW_USERNAME}"
create_secret_if_missing "minio_root_password" "${MINIO_WWW_PASSWORD}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Deploy the shared overlay network
# ─────────────────────────────────────────────────────────────────────────────
log_info "Step 2: Ensuring shared overlay network exists..."
if docker network ls --format '{{.Name}}' | grep -q "^data-platform-network$"; then
  log_info "Overlay network 'data-platform-network' already exists. Skipping."
else
  docker network create \
    --driver overlay \
    --attachable \
    --opt encrypted=false \
    data-platform-network
  log_info "Overlay network 'data-platform-network' created."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Create MinIO host data directory
# ─────────────────────────────────────────────────────────────────────────────
log_info "Step 3: Ensuring MinIO data directory exists..."
mkdir -p /opt/data-platform/minio/data

# Ensure MinIO container can write to its directory (MinIO often runs as 1000 or root)
chown -R 1000:1000 /opt/data-platform/minio || chmod -R 777 /opt/data-platform/minio

log_info "MinIO data directory ready: /opt/data-platform/minio/data"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Deploy the MinIO stack
# ─────────────────────────────────────────────────────────────────────────────
log_info "Step 4: Deploying MinIO stack..."
docker stack deploy -c "${PROJECT_ROOT}/minio/stack.minio.yml" minio
log_info "MinIO stack deployed successfully."

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Wait for MinIO to become healthy
# ─────────────────────────────────────────────────────────────────────────────
log_info "Step 5: Waiting for MinIO to become healthy..."
max_wait=120
wait_interval=5
elapsed=0
while [[ ${elapsed} -lt ${max_wait} ]]; do
  if curl -sf "${MINIO_HOSTNAME}/minio/health/live" &>/dev/null; then
    log_info "MinIO is healthy and accepting requests."
    break
  fi
  log_info "MinIO not ready yet (${elapsed}s elapsed). Retrying in ${wait_interval}s..."
  sleep "${wait_interval}"
  elapsed=$((elapsed + wait_interval))
done

if [[ ${elapsed} -ge ${max_wait} ]]; then
  log_error "MinIO did not become healthy within ${max_wait} seconds."
  log_error "Check service logs: docker service logs minio_minio"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Ensure MinIO Client (mc) is available
# ─────────────────────────────────────────────────────────────────────────────
log_info "Step 6: Checking for MinIO Client (mc)..."
if command -v mc &>/dev/null; then
  log_info "MinIO Client (mc) found: $(mc --version 2>/dev/null | head -1)"
else
  log_info "MinIO Client (mc) not found. Downloading..."
  curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
  chmod +x /usr/local/bin/mc
  log_info "MinIO Client installed at /usr/local/bin/mc"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Configure mc alias for the local MinIO server
# ─────────────────────────────────────────────────────────────────────────────
log_info "Step 7: Setting up mc alias '${MINIO_CLIENT_NAME}'..."
mc alias set "${MINIO_CLIENT_NAME}" "${MINIO_HOSTNAME}" "${MINIO_WWW_USERNAME}" "${MINIO_WWW_PASSWORD}"
log_info "mc alias '${MINIO_CLIENT_NAME}' configured for ${MINIO_HOSTNAME}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Create the default bucket (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
log_info "Step 8: Creating bucket '${BUCKET_NAME}'..."
if mc ls "${MINIO_CLIENT_NAME}/${BUCKET_NAME}" &>/dev/null; then
  log_warn "Bucket '${BUCKET_NAME}' already exists. Skipping creation."
else
  mc mb "${MINIO_CLIENT_NAME}/${BUCKET_NAME}"
  log_info "Bucket '${BUCKET_NAME}' created successfully."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 9: Set bucket access policy
# ─────────────────────────────────────────────────────────────────────────────
log_info "Step 9: Setting access policy on bucket '${BUCKET_NAME}'..."
mc anonymous set none "${MINIO_CLIENT_NAME}/${BUCKET_NAME}"
log_info "Bucket '${BUCKET_NAME}' access policy set to 'none' (private)."

# ─────────────────────────────────────────────────────────────────────────────
# Deployment and Configuration complete
# ─────────────────────────────────────────────────────────────────────────────
log_info "============================================="
log_info "  MinIO deployment and configuration complete."
log_info "============================================="
log_info "  API      : ${MINIO_HOSTNAME}"
log_info "  Console  : http://localhost:${MINIO_PORT_CONSOLE}"
log_info "  Bucket   : ${BUCKET_NAME}"
log_info "  Policy   : private (root credentials only)"
log_info "============================================="
