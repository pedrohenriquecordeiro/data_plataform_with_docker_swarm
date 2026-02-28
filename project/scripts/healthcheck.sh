#!/usr/bin/env bash
# healthcheck.sh — Global health check script for all data platform services.
# Polls health endpoints for MinIO, Airflow webserver, PostgreSQL, and Redis.
# Reports a summary table with the status of each service.
# Usage: bash scripts/healthcheck.sh

# Exit immediately on error, treat unset variables as errors, fail on pipe errors
set -euo pipefail

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
# Tracking variables
# ─────────────────────────────────────────────────────────────────────────────

# Counter for tracking overall health status
total_checks=0       # Total number of health checks performed
passed_checks=0      # Number of checks that passed
failed_checks=0      # Number of checks that failed

# Array to accumulate results for the summary table
declare -a results=()

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Check a service health endpoint
# ─────────────────────────────────────────────────────────────────────────────

# Performs a health check against a service and records the result.
# Arguments:
#   $1 — Service name (displayed in the summary table)
#   $2 — Health check command to execute (passed to eval)
check_service() {
  local service_name="$1"     # Human-readable service name
  local check_command="$2"    # Shell command to evaluate for health check

  total_checks=$((total_checks + 1))   # Increment total check counter

  # Execute the health check command and capture the result
  if eval "${check_command}" &>/dev/null; then
    # Service is healthy
    results+=("${service_name}|✅ HEALTHY")
    passed_checks=$((passed_checks + 1))
    log_info "${service_name}: HEALTHY"
  else
    # Service is unhealthy or unreachable
    results+=("${service_name}|❌ UNHEALTHY")
    failed_checks=$((failed_checks + 1))
    log_error "${service_name}: UNHEALTHY"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run health checks for all services
# ─────────────────────────────────────────────────────────────────────────────

log_info "Starting health checks for all data platform services..."
echo ""

# --- MinIO API health check ---
# Checks the MinIO live health endpoint on port 9000
check_service "MinIO API" "curl -sf http://127.0.0.1:9000/minio/health/live"

# --- MinIO Console health check ---
# Checks if the MinIO console UI is reachable on port 9001
check_service "MinIO Console" "curl -sf http://127.0.0.1:9001"

# --- Airflow Webserver health check ---
# Checks the Airflow built-in health endpoint on port 8080
check_service "Airflow Webserver" "curl -sf http://127.0.0.1:8080/health"

# --- PostgreSQL health check ---
# Uses pg_isready inside the postgres container to verify database readiness
check_service "PostgreSQL" "docker exec \$(docker ps --filter 'name=airflow_postgres' --format '{{.ID}}' | head -1) pg_isready -U airflow"

# --- Redis health check ---
# Uses redis-cli ping inside the redis container to verify broker readiness
check_service "Redis" "docker exec \$(docker ps --filter 'name=airflow_redis' --format '{{.ID}}' | head -1) redis-cli ping"

# --- Airflow Scheduler health check ---
# Checks if the scheduler service has running tasks in Docker Swarm
check_service "Airflow Scheduler" "docker service ls --format '{{.Name}} {{.Replicas}}' | grep 'airflow_airflow-scheduler' | grep -q '1/1'"

# --- Airflow Worker health check ---
# Checks if the worker service has running tasks in Docker Swarm
check_service "Airflow Worker" "docker service ls --format '{{.Name}} {{.Replicas}}' | grep 'airflow_airflow-worker' | grep -q '1/1'"

# --- Airflow Triggerer health check ---
# Checks if the triggerer service has running tasks in Docker Swarm
check_service "Airflow Triggerer" "docker service ls --format '{{.Name}} {{.Replicas}}' | grep 'airflow_airflow-triggerer' | grep -q '1/1'"

# ─────────────────────────────────────────────────────────────────────────────
# Print summary table
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "============================================="
echo "  Data Platform Health Check Summary"
echo "============================================="
# Print table header
printf "  %-25s %s\n" "SERVICE" "STATUS"
printf "  %-25s %s\n" "-------------------------" "-------------"

# Iterate over results array and print each service status
for result in "${results[@]}"; do
  # Split the result string on the pipe delimiter
  service_name="${result%%|*}"     # Everything before the pipe
  service_status="${result##*|}"   # Everything after the pipe
  printf "  %-25s %s\n" "${service_name}" "${service_status}"
done

echo "============================================="
echo "  Total: ${total_checks} | Passed: ${passed_checks} | Failed: ${failed_checks}"
echo "============================================="

# ─────────────────────────────────────────────────────────────────────────────
# Exit code: non-zero if any check failed
# ─────────────────────────────────────────────────────────────────────────────

# Return non-zero exit code if any health check failed
if [[ ${failed_checks} -gt 0 ]]; then
  log_error "${failed_checks} service(s) are unhealthy."
  exit 1
fi

# All checks passed
log_info "All services are healthy."
exit 0
