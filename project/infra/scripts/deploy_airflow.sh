#!/usr/bin/env bash
# deploy_airflow.sh — Idempotent deployment script for the Airflow stack.
# Creates Docker Swarm secrets, ensures host directories exist, deploys the
# shared overlay network (if not present), deploys the Airflow stack and
# configures Airflow connections.
# Usage: sudo bash scripts/deploy_airflow.sh

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

# Print an informational message with timestamp
log_info() {
  echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') — $*"
}

# Print a warning message with timestamp
log_warn() {
  echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') — $*"
}

# Print an error message with timestamp to stderr
log_error() {
  echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') — $*" >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight: Verify Docker Swarm is active
# ─────────────────────────────────────────────────────────────────────────────

log_info "Checking Docker Swarm status..."

# Query the local Swarm state — must be 'active' to deploy stacks
swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")
if [[ "${swarm_state}" != "active" ]]; then
  log_error "Docker Swarm is not active (state: ${swarm_state})."
  log_error "Initialize Swarm first: docker swarm init"
  # TODO(user): if the node has multiple network interfaces, run:
  #   docker swarm init --advertise-addr <INTERFACE>
  exit 1
fi
log_info "Docker Swarm is active."

# ─────────────────────────────────────────────────────────────────────────────
# Load environment variables from .env file
# ─────────────────────────────────────────────────────────────────────────────

# Path to the .env file containing configuration and secret values
ENV_FILE="${PROJECT_ROOT}/.env"

# Verify .env file exists
if [[ ! -f "${ENV_FILE}" ]]; then
  log_error ".env file not found at ${ENV_FILE}"
  log_error "Copy .env.example to .env and fill in values before deploying."
  exit 1
fi

# Source the .env file to load all variables
# shellcheck disable=SC1090
source "${ENV_FILE}"
log_info "Loaded environment variables from ${ENV_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Create Docker Swarm secrets (idempotent)
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 1: Creating Airflow Docker Swarm secrets..."

# Ensure .env is created and permissions set if deploying directly
if [[ ! -f "${ENV_FILE}" ]]; then
  log_info "Creating .env from .env.example..."
  cp "${PROJECT_ROOT}/.env.example" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  source "${ENV_FILE}"
fi

# Helper function to create a Swarm secret idempotently.
# Checks existence before creating to avoid errors on re-runs.
create_secret_if_missing() {
  local secret_name="$1"    # Name of the Swarm secret
  local secret_value="$2"   # Plaintext value to store

  # Check if the secret already exists in Docker Swarm
  if docker secret inspect "${secret_name}" &>/dev/null; then
    log_warn "Secret '${secret_name}' already exists. Skipping creation."
  else
    # Create the secret by piping the value to docker secret create
    echo -n "${secret_value}" | docker secret create "${secret_name}" -
    log_info "Secret '${secret_name}' created successfully."
  fi
}

# Create all Airflow-related secrets from .env values
create_secret_if_missing "airflow_fernet_key" "${AIRFLOW__CORE__FERNET_KEY}"         # Fernet encryption key
create_secret_if_missing "airflow_secret_key" "${AIRFLOW_SECRET_KEY}"         # Webserver session secret
create_secret_if_missing "airflow_db_password" "${AIRFLOW_POSTGRES_PASSWORD}"       # PostgreSQL password
create_secret_if_missing "airflow_admin_password" "${AIRFLOW_WWW_PASSWORD}" # Initial admin password
create_secret_if_missing "airflow_admin_user" "${AIRFLOW_WWW_USERNAME}"         # Admin username

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Deploy the shared overlay network (if not already deployed)
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 2: Ensuring shared overlay network exists..."

# Docker Swarm only creates overlay networks when a service that references them is scheduled.
# A stack with only a 'networks:' block and no services will NOT create the network.
# The correct approach is to create the network directly via 'docker network create'.
if docker network ls --format '{{.Name}}' | grep -q "^data-platform-network$"; then
  log_info "Overlay network 'data-platform-network' already exists. Skipping."
else
  # Create the attachable overlay network — used by all service stacks
  docker network create \
    --driver overlay \
    --attachable \
    --opt encrypted=false \
    data-platform-network
  log_info "Overlay network 'data-platform-network' created."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Create host data directories for Airflow and its dependencies
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 3: Ensuring host data directories exist..."

# Create all directories needed by Airflow and its dependency services.
# -p flag makes these calls idempotent (no error if directory exists).
mkdir -p /opt/data-platform/airflow/dags       # Airflow DAG files
mkdir -p /opt/data-platform/airflow/logs       # Airflow task logs
mkdir -p /opt/data-platform/airflow/plugins    # Airflow plugins
mkdir -p /opt/data-platform/airflow/config     # Airflow config files
mkdir -p /opt/data-platform/postgres/data      # PostgreSQL data directory
mkdir -p /opt/data-platform/redis/data         # Redis data directory

# Set appropriate ownership for container users
# Airflow image uses UID 50000 (airflow)
chown -R 50000:0 /opt/data-platform/airflow
# Postgres alpine image uses UID 70 (postgres)
chown -R 70:70 /opt/data-platform/postgres
# Redis alpine image uses UID 999 (redis)
chown -R 999:1000 /opt/data-platform/redis || chown -R 999:999 /opt/data-platform/redis || chmod -R 777 /opt/data-platform/redis

chmod -R 775 /opt/data-platform/airflow
chmod -R 775 /opt/data-platform/postgres

log_info "Host data directories created/verified."

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Deploy the Airflow stack
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 4: Deploying Airflow stack..."

# Export all .env variables so they're available to docker stack deploy.
# Docker stack deploy resolves ${VAR} substitutions from the environment.
export AIRFLOW_IMAGE
export AIRFLOW_POSTGRES_PASSWORD
export AIRFLOW_PARALLELISM
export AIRFLOW_WORKER_CONCURRENCY

# Deploy the Airflow stack — idempotent: re-running updates the stack.
docker stack deploy -c "${PROJECT_ROOT}/airflow/stack.airflow.yml" airflow
log_info "Airflow stack deployed successfully."

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Wait for Airflow webserver to become healthy
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 5: Waiting for Airflow webserver to become healthy..."

# Maximum time to wait for the webserver health endpoint
max_wait=180        # Total timeout in seconds (webserver takes longer to start)
wait_interval=10    # Seconds between health check polls
elapsed=0           # Elapsed time counter

# Poll the Airflow health endpoint until it responds
while [[ ${elapsed} -lt ${max_wait} ]]; do
  if curl -sf http://127.0.0.1:8080/health &>/dev/null; then
    log_info "Airflow webserver is healthy and accepting requests."
    break
  fi
  # Webserver not ready — wait and retry
  log_info "Webserver not ready (${elapsed}s elapsed). Retrying in ${wait_interval}s..."
  sleep "${wait_interval}"
  elapsed=$((elapsed + wait_interval))
done

# Check if we timed out waiting for the webserver
if [[ ${elapsed} -ge ${max_wait} ]]; then
  log_error "Airflow webserver did not become healthy within ${max_wait} seconds."
  log_error "Check service logs: docker service logs airflow_airflow-webserver"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Execute a command inside the running Airflow webserver container
# ─────────────────────────────────────────────────────────────────────────────

# Runs a command inside the airflow-webserver service container.
# Uses docker exec on the first running task of the service.
airflow_exec() {
  # Find the container ID of the first running airflow-webserver task
  local container_id
  container_id=$(docker ps --filter "name=airflow_airflow-webserver" --format '{{.ID}}' | head -1)

  # Verify that a running container was found
  if [[ -z "${container_id}" ]]; then
    log_error "No running airflow-webserver container found."
    exit 1
  fi

  # Execute the provided command inside the container
  docker exec "${container_id}" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Configure Airflow connections
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 6: Configuring Airflow connections..."

# --- MinIO connection (S3-compatible via AWS provider) ---
# Uses Swarm DNS name 'minio' for internal communication over the overlay network.
# Do NOT use the external host IP for this connection.
log_info "Setting up 'minio_default' connection..."
airflow_exec airflow connections delete minio_default 2>/dev/null || true   # Remove existing (if any)
airflow_exec airflow connections add minio_default \
  --conn-type aws \
  --conn-host "http://minio:9000" \
  --conn-login "${MINIO_WWW_USERNAME}" \
  --conn-password "${MINIO_WWW_PASSWORD}" \
  --conn-extra '{"endpoint_url": "http://minio:9000"}'    # MinIO endpoint via Swarm DNS
log_info "Connection 'minio_default' configured."

# --- PostgreSQL metadata connection ---
# Uses Swarm DNS name 'postgres' for internal communication.
log_info "Setting up 'postgres_default' connection..."
airflow_exec airflow connections delete postgres_default 2>/dev/null || true   # Remove existing (if any)
airflow_exec airflow connections add postgres_default \
  --conn-type postgres \
  --conn-host "postgres" \
  --conn-port 5432 \
  --conn-schema "airflow" \
  --conn-login "airflow" \
  --conn-password "${AIRFLOW_POSTGRES_PASSWORD}"    # Password from .env
log_info "Connection 'postgres_default' configured."

# ─────────────────────────────────────────────────────────────────────────────
# Deployment complete
# ─────────────────────────────────────────────────────────────────────────────

log_info "============================================="
log_info "  Airflow deployment and configuration complete."
log_info "============================================="
log_info "  Webserver  : http://localhost:8080"
log_info "  Scheduler  : running"
log_info "  Worker     : running (1 replica)"
log_info "  Triggerer  : running"
log_info "  Admin user : ${AIRFLOW_WWW_USERNAME}"
log_info "  Connections: minio_default, postgres_default"
log_info ""
log_info "  Next step: run scripts/healthcheck.sh"
log_info "============================================="

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Clean up built image
# ─────────────────────────────────────────────────────────────────────────────
AIRFLOW_IMAGE_TO_REMOVE="${AIRFLOW_IMAGE:-local/data-platform-airflow:2.10.5}"
if docker image inspect "${AIRFLOW_IMAGE_TO_REMOVE}" &>/dev/null; then
  log_info "Removing Airflow image '${AIRFLOW_IMAGE_TO_REMOVE}' post-deployment..."
  docker rmi "${AIRFLOW_IMAGE_TO_REMOVE}" >/dev/null 2>&1 || log_warn "Failed to remove image '${AIRFLOW_IMAGE_TO_REMOVE}'"
fi
