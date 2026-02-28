#!/usr/bin/env bash
# destroy.sh — Full destroy utility for the data platform.
# Removes all Swarm stacks, secrets, the overlay network and named volumes.
# Analogous to 'terraform destroy' — reverses everything created by the deploy scripts.
# Supports: --dry-run (print actions without executing) and --purge-data (delete host data dirs).
# Usage: sudo bash scripts/destroy.sh [--dry-run] [--purge-data]

# Exit immediately on error, treat unset variables as errors, fail on pipe errors
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Parse command-line flags
# ─────────────────────────────────────────────────────────────────────────────

# Flag: when true, print actions without executing any destructive commands
DRY_RUN=false

# Flag: when true, delete host data directories under /opt/data-platform
PURGE_DATA=false

# Parse all command-line arguments
for arg in "$@"; do
  case "${arg}" in
    --dry-run)
      DRY_RUN=true        # Enable dry-run mode
      ;;
    --purge-data)
      PURGE_DATA=true     # Enable host data purge
      ;;
    *)
      echo "Unknown argument: ${arg}"
      echo "Usage: $0 [--dry-run] [--purge-data]"
      exit 1
      ;;
  esac
done

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

# Print a dry-run marker message
log_dry() {
  echo "[DRY]   $(date '+%Y-%m-%d %H:%M:%S') — WOULD: $*"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tracking arrays for the summary report
# ─────────────────────────────────────────────────────────────────────────────

# Arrays to track the status of each resource removal
declare -a summary_resources=()    # Resource names for the summary table
declare -a summary_statuses=()     # Corresponding statuses (removed/skipped/failed)

# Record a resource removal outcome for the final summary
record_result() {
  local resource="$1"    # Resource identifier
  local status="$2"      # Outcome: removed, skipped, failed, dry-run

  summary_resources+=("${resource}")
  summary_statuses+=("${status}")
}

# ─────────────────────────────────────────────────────────────────────────────
# Dry run mode notification
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${DRY_RUN}" == "true" ]]; then
  log_info "============================================="
  log_info "  DRY-RUN MODE — no destructive actions will be performed"
  log_info "============================================="
  echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Remove Docker Swarm stacks
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 1: Removing Docker Swarm stacks..."

# List of stacks to remove in reverse-dependency order
readonly STACKS_TO_REMOVE=("airflow" "minio" "shared")

for stack_name in "${STACKS_TO_REMOVE[@]}"; do
  # Check if the stack exists before attempting removal
  if docker stack ls --format '{{.Name}}' | grep -q "^${stack_name}$"; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_dry "docker stack rm ${stack_name}"
      record_result "stack/${stack_name}" "dry-run"
    else
      # Remove the stack
      log_info "Removing stack '${stack_name}'..."
      docker stack rm "${stack_name}"
      record_result "stack/${stack_name}" "removed"
    fi
  else
    # Stack doesn't exist — skip
    log_warn "Stack '${stack_name}' not found. Skipping."
    record_result "stack/${stack_name}" "skipped"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 1b: Wait for all stack tasks to stop (max 120s)
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${DRY_RUN}" != "true" ]]; then
  log_info "Waiting for all stack tasks to stop..."

  # Maximum wait time and polling interval for stack removal
  max_wait=120          # Total timeout in seconds
  wait_interval=5      # Seconds between polls
  elapsed=0            # Elapsed time counter

  # Poll 'docker stack ls' until removed stacks are no longer listed
  while [[ ${elapsed} -lt ${max_wait} ]]; do
    # Check if any of the target stacks are still listed
    remaining=false
    for stack_name in "${STACKS_TO_REMOVE[@]}"; do
      if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -q "^${stack_name}$"; then
        remaining=true
        break
      fi
    done

    # If no stacks remain, break out of the loop
    if [[ "${remaining}" == "false" ]]; then
      log_info "All stacks removed successfully."
      break
    fi

    # Wait and retry
    log_info "Stacks still draining (${elapsed}s elapsed). Waiting ${wait_interval}s..."
    sleep "${wait_interval}"
    elapsed=$((elapsed + wait_interval))
  done

  # Warn if timeout was reached
  if [[ ${elapsed} -ge ${max_wait} ]]; then
    log_warn "Timeout waiting for stacks to drain. Proceeding anyway."
  fi

  # Additional grace period for containers to fully stop
  log_info "Waiting 10 seconds for container cleanup..."
  sleep 10
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Remove Docker Swarm secrets
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 2: Removing Docker Swarm secrets..."

# Complete list of all secrets created by the deploy scripts
readonly SECRETS_TO_REMOVE=(
  "minio_root_user"          # MinIO root username
  "minio_root_password"      # MinIO root password
  "airflow_fernet_key"       # Airflow Fernet encryption key
  "airflow_secret_key"       # Airflow webserver session secret
  "airflow_db_password"      # PostgreSQL password for Airflow
  "airflow_admin_password"   # Airflow admin user password
  "airflow_admin_user"       # Airflow admin username
)

for secret_name in "${SECRETS_TO_REMOVE[@]}"; do
  # Check if the secret exists before attempting removal
  if docker secret inspect "${secret_name}" &>/dev/null; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_dry "docker secret rm ${secret_name}"
      record_result "secret/${secret_name}" "dry-run"
    else
      # Remove the secret
      docker secret rm "${secret_name}"
      log_info "Secret '${secret_name}' removed."
      record_result "secret/${secret_name}" "removed"
    fi
  else
    # Secret doesn't exist — skip
    log_warn "Secret '${secret_name}' not found. Skipping."
    record_result "secret/${secret_name}" "skipped"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Remove the overlay network
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 3: Removing overlay network..."

# Name of the shared overlay network
readonly NETWORK_NAME="data-platform-network"

# Check if the network exists
if docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dry "docker network rm ${NETWORK_NAME}"
    record_result "network/${NETWORK_NAME}" "dry-run"
  else
    # Remove the overlay network
    docker network rm "${NETWORK_NAME}"
    log_info "Network '${NETWORK_NAME}' removed."
    record_result "network/${NETWORK_NAME}" "removed"
  fi
else
  # Network doesn't exist — skip
  log_warn "Network '${NETWORK_NAME}' not found. Skipping."
  record_result "network/${NETWORK_NAME}" "skipped"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Remove named Docker volumes
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 4: Removing Docker volumes created by stacks..."

# Find all volumes with names matching the stack prefixes
for volume_name in $(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^(airflow_|minio_|shared_)" || true); do
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dry "docker volume rm ${volume_name}"
    record_result "volume/${volume_name}" "dry-run"
  else
    # Remove the volume
    if docker volume rm "${volume_name}" 2>/dev/null; then
      log_info "Volume '${volume_name}' removed."
      record_result "volume/${volume_name}" "removed"
    else
      log_warn "Failed to remove volume '${volume_name}' (may still be in use)."
      record_result "volume/${volume_name}" "failed"
    fi
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 4.5: Remove custom Docker images
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 4.5: Removing custom Airflow image..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

# Extract AIRFLOW_IMAGE from .env if it exists
AIRFLOW_IMAGE=""
if [[ -f "${ENV_FILE}" ]]; then
  AIRFLOW_IMAGE=$(grep -E "^AIRFLOW_IMAGE=" "${ENV_FILE}" | cut -d '=' -f2 | tr -d '"'\'' ' | tail -n 1 || echo "")
fi

AIRFLOW_IMAGE_TO_REMOVE="${AIRFLOW_IMAGE:-local/data-platform-airflow:2.10.5}"

# Check if the image exists locally
if docker image inspect "${AIRFLOW_IMAGE_TO_REMOVE}" &>/dev/null; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dry "docker rmi ${AIRFLOW_IMAGE_TO_REMOVE}"
    record_result "image/${AIRFLOW_IMAGE_TO_REMOVE}" "dry-run"
  else
    # Try to remove the image
    if docker rmi "${AIRFLOW_IMAGE_TO_REMOVE}" >/dev/null 2>&1; then
      log_info "Image '${AIRFLOW_IMAGE_TO_REMOVE}' removed."
      record_result "image/${AIRFLOW_IMAGE_TO_REMOVE}" "removed"
    else
      log_warn "Failed to remove image '${AIRFLOW_IMAGE_TO_REMOVE}' (may be in use or have dependent child images)."
      record_result "image/${AIRFLOW_IMAGE_TO_REMOVE}" "failed"
    fi
  fi
else
  log_info "Image '${AIRFLOW_IMAGE_TO_REMOVE}' not found locally. Skipping."
  record_result "image/${AIRFLOW_IMAGE_TO_REMOVE}" "skipped"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 (Optional): Purge host data directories
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${PURGE_DATA}" == "true" ]]; then
  log_info "Step 5: Purging host data directories..."

  # Paths that will be permanently deleted
  readonly DATA_PATHS=(
    "/opt/data-platform/minio"       # MinIO object data
    "/opt/data-platform/airflow"     # Airflow DAGs, logs, plugins
    "/opt/data-platform/postgres"    # PostgreSQL database files
    "/opt/data-platform/redis"       # Redis data
  )

  # Print a prominent warning listing every path that will be deleted
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  ⚠️  WARNING: DESTRUCTIVE OPERATION                  ║"
  echo "║  The following directories will be PERMANENTLY DELETED: ║"
  echo "╠══════════════════════════════════════════════════════╣"
  for data_path in "${DATA_PATHS[@]}"; do
    printf "║    %-48s ║\n" "${data_path}"
  done
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  if [[ "${DRY_RUN}" == "true" ]]; then
    # In dry-run mode, do not prompt — just log what would happen
    for data_path in "${DATA_PATHS[@]}"; do
      log_dry "rm -rf ${data_path}"
      record_result "data/${data_path}" "dry-run"
    done
  else
    # Require explicit confirmation before deleting host data
    read -r -p "Type 'yes' to confirm permanent deletion: " confirmation
    if [[ "${confirmation}" == "yes" ]]; then
      for data_path in "${DATA_PATHS[@]}"; do
        if [[ -d "${data_path}" ]]; then
          rm -rf "${data_path}"
          log_info "Deleted: ${data_path}"
          record_result "data/${data_path}" "removed"
        else
          log_warn "Directory '${data_path}' does not exist. Skipping."
          record_result "data/${data_path}" "skipped"
        fi
      done
    else
      # User declined — skip data purge
      log_warn "Data purge cancelled by user."
      for data_path in "${DATA_PATHS[@]}"; do
        record_result "data/${data_path}" "skipped (user cancelled)"
      done
    fi
  fi
else
  log_info "Step 5: Skipping host data purge (use --purge-data to enable)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary table
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "============================================="
echo "  Teardown Summary"
echo "============================================="
# Print table header
printf "  %-40s %s\n" "RESOURCE" "STATUS"
printf "  %-40s %s\n" "────────────────────────────────────────" "──────────────────"

# Iterate over all recorded results
for i in "${!summary_resources[@]}"; do
  printf "  %-40s %s\n" "${summary_resources[${i}]}" "${summary_statuses[${i}]}"
done

echo "============================================="
echo ""

# Inform the user about dry-run limitation
if [[ "${DRY_RUN}" == "true" ]]; then
  log_info "DRY-RUN complete. No changes were made."
  log_info "Remove --dry-run to execute the destruction."
fi

log_info "Destroy complete."
