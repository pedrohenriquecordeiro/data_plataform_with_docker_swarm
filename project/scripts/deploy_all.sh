#!/usr/bin/env bash
# deploy.sh — Master deployment script for the data platform.
# Orchestrates the full deployment pipeline: dependencies, image build,
# MinIO and Airflow deployment, health checks, and integration tests.
# Usage: sudo bash scripts/deploy.sh

# Exit immediately on error, treat unset variables as errors, fail on pipe errors
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Resolve paths
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # Absolute path to scripts/
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"                # Project root

# ─────────────────────────────────────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────────────────────────────────────

log_info() {
  echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') — $*"
}

log_error() {
  echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') — $*" >&2
}

log_step() {
  echo ""
  echo "============================================="
  echo "  $*"
  echo "============================================="
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight: Ensure root privileges
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$(id -u)" -ne 0 ]]; then
  log_error "This script must be run as root or with sudo."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Load environment variables
# ─────────────────────────────────────────────────────────────────────────────

ENV_FILE="${PROJECT_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  log_error ".env file not found at ${ENV_FILE}"
  log_error "Copy .env.example to .env and fill in values before deploying."
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"
log_info "Loaded environment variables from ${ENV_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Install dependencies (Docker, Swarm, host directories)
# ─────────────────────────────────────────────────────────────────────────────

log_step "Step 1/6: Installing dependencies..."
bash "${SCRIPT_DIR}/install_dependencies.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Build the custom Airflow image
# ─────────────────────────────────────────────────────────────────────────────

log_step "Step 2/6: Building custom Airflow image..."

# Use the AIRFLOW_IMAGE from .env or default
AIRFLOW_IMAGE_TAG="${AIRFLOW_IMAGE:-airflow:2.10.5}"
log_info "Building image: ${AIRFLOW_IMAGE_TAG}"
docker build -t "${AIRFLOW_IMAGE_TAG}" "${PROJECT_ROOT}/airflow/"
log_info "Airflow image built successfully: ${AIRFLOW_IMAGE_TAG}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Deploy and configure MinIO
# ─────────────────────────────────────────────────────────────────────────────

log_step "Step 3/6: Deploying MinIO..."
bash "${SCRIPT_DIR}/deploy_minio.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Deploy and configure Airflow
# ─────────────────────────────────────────────────────────────────────────────

log_step "Step 4/6: Deploying Airflow..."
bash "${SCRIPT_DIR}/deploy_airflow.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Run health checks
# ─────────────────────────────────────────────────────────────────────────────

log_step "Step 5/6: Running health checks..."
bash "${SCRIPT_DIR}/healthcheck.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Run integration tests
# ─────────────────────────────────────────────────────────────────────────────

log_step "Step 6/6: Running integration tests..."
bash "${SCRIPT_DIR}/test_stack.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Deployment complete
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "============================================="
echo "  ✅ DATA PLATFORM DEPLOYMENT COMPLETE"
echo "============================================="
echo ""
echo "  Services:"
echo "    Airflow UI   : http://localhost:8080"
echo "    MinIO Console: http://localhost:9001"
echo "    MinIO API    : http://localhost:9000"
echo ""
echo "  Next steps:"
echo "    - Access Airflow UI and verify DAGs"
echo "    - Access MinIO Console and verify buckets"
echo "    - Copy DAG files to /opt/data-platform/airflow/dags/"
echo ""
echo "============================================="
