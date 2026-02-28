#!/usr/bin/env bash
# test_stack.sh — Manual integration test suite for the data platform.
# Validates that all Docker Swarm services (MinIO and Airflow) are deployed,
# reachable, and correctly configured. Run AFTER deploying and configuring both stacks.
# Usage: bash scripts/test_stack.sh

# Exit immediately on error, treat unset variables as errors, fail on pipe errors
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Test tracking variables
# ─────────────────────────────────────────────────────────────────────────────

# Counters for test results
total_tests=0       # Total number of tests executed
passed_tests=0      # Number of tests that passed
failed_tests=0      # Number of tests that failed

# ─────────────────────────────────────────────────────────────────────────────
# Test helper functions
# ─────────────────────────────────────────────────────────────────────────────

# Assert that two values are equal.
# Arguments: $1=test name, $2=expected value, $3=actual value
assert_equal() {
  local test_name="$1"        # Human-readable test name
  local expected="$2"         # Expected value
  local actual="$3"           # Actual value from the test

  total_tests=$((total_tests + 1))   # Increment test counter

  # Compare expected and actual values
  if [[ "${expected}" == "${actual}" ]]; then
    echo "[PASS] ${test_name}"
    passed_tests=$((passed_tests + 1))
  else
    echo "[FAIL] ${test_name} — expected: '${expected}', got: '${actual}'"
    failed_tests=$((failed_tests + 1))
  fi
}

# Assert that a string contains a given substring.
# Arguments: $1=test name, $2=expected substring, $3=full string to search
assert_contains() {
  local test_name="$1"        # Human-readable test name
  local expected="$2"         # Substring that must be present
  local actual="$3"           # Full string to search within

  total_tests=$((total_tests + 1))   # Increment test counter

  # Check if the actual string contains the expected substring
  if echo "${actual}" | grep -q "${expected}"; then
    echo "[PASS] ${test_name}"
    passed_tests=$((passed_tests + 1))
  else
    echo "[FAIL] ${test_name} — expected to contain: '${expected}', got: '${actual}'"
    failed_tests=$((failed_tests + 1))
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Test suite: Docker Swarm infrastructure
# ─────────────────────────────────────────────────────────────────────────────

echo "============================================="
echo "  Data Platform Integration Tests"
echo "============================================="
echo ""
echo "--- Docker Swarm Infrastructure ---"

# Test: Verify Docker Swarm is in active state
test_swarm_active() {
  local swarm_state
  swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")
  assert_equal "Swarm is active" "active" "${swarm_state}"
}
test_swarm_active

# Test: Verify the overlay network exists
test_overlay_network_exists() {
  local network_exists
  network_exists=$(docker network ls --format '{{.Name}}' | grep -c "^data-platform-network$" || echo "0")
  assert_equal "Overlay network 'data-platform-network' exists" "1" "${network_exists}"
}
test_overlay_network_exists

# ─────────────────────────────────────────────────────────────────────────────
# Test suite: Stacks deployed
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- Swarm Stacks ---"

# Test: Verify the MinIO stack is deployed
test_minio_stack_deployed() {
  local stack_exists
  stack_exists=$(docker stack ls --format '{{.Name}}' | grep -c "^minio$" || echo "0")
  assert_equal "MinIO stack is deployed" "1" "${stack_exists}"
}
test_minio_stack_deployed

# Test: Verify the Airflow stack is deployed
test_airflow_stack_deployed() {
  local stack_exists
  stack_exists=$(docker stack ls --format '{{.Name}}' | grep -c "^airflow$" || echo "0")
  assert_equal "Airflow stack is deployed" "1" "${stack_exists}"
}
test_airflow_stack_deployed

# ─────────────────────────────────────────────────────────────────────────────
# Test suite: Service replicas
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- Service Replicas ---"

# Test: Verify MinIO service has 1/1 replicas running
test_minio_replicas() {
  local replicas
  replicas=$(docker service ls --format '{{.Name}} {{.Replicas}}' | grep "minio_minio" | awk '{print $2}' || echo "0/0")
  assert_equal "MinIO replicas" "1/1" "${replicas}"
}
test_minio_replicas

# Test: Verify Airflow webserver has 1/1 replicas
test_webserver_replicas() {
  local replicas
  replicas=$(docker service ls --format '{{.Name}} {{.Replicas}}' | grep "airflow_airflow-webserver" | awk '{print $2}' || echo "0/0")
  assert_equal "Airflow webserver replicas" "1/1" "${replicas}"
}
test_webserver_replicas

# Test: Verify Airflow scheduler has 1/1 replicas
test_scheduler_replicas() {
  local replicas
  replicas=$(docker service ls --format '{{.Name}} {{.Replicas}}' | grep "airflow_airflow-scheduler" | awk '{print $2}' || echo "0/0")
  assert_equal "Airflow scheduler replicas" "1/1" "${replicas}"
}
test_scheduler_replicas

# Test: Verify Airflow worker has 1/1 replicas
test_worker_replicas() {
  local replicas
  replicas=$(docker service ls --format '{{.Name}} {{.Replicas}}' | grep "airflow_airflow-worker" | awk '{print $2}' || echo "0/0")
  assert_equal "Airflow worker replicas" "1/1" "${replicas}"
}
test_worker_replicas

# Test: Verify Airflow triggerer has 1/1 replicas
test_triggerer_replicas() {
  local replicas
  replicas=$(docker service ls --format '{{.Name}} {{.Replicas}}' | grep "airflow_airflow-triggerer" | awk '{print $2}' || echo "0/0")
  assert_equal "Airflow triggerer replicas" "1/1" "${replicas}"
}
test_triggerer_replicas

# Test: Verify PostgreSQL has 1/1 replicas
test_postgres_replicas() {
  local replicas
  replicas=$(docker service ls --format '{{.Name}} {{.Replicas}}' | grep "airflow_postgres" | awk '{print $2}' || echo "0/0")
  assert_equal "PostgreSQL replicas" "1/1" "${replicas}"
}
test_postgres_replicas

# Test: Verify Redis has 1/1 replicas
test_redis_replicas() {
  local replicas
  replicas=$(docker service ls --format '{{.Name}} {{.Replicas}}' | grep "airflow_redis" | awk '{print $2}' || echo "0/0")
  assert_equal "Redis replicas" "1/1" "${replicas}"
}
test_redis_replicas

# ─────────────────────────────────────────────────────────────────────────────
# Test suite: Endpoint reachability
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- Endpoint Reachability ---"

# Test: MinIO API responds on port 9000
test_minio_api_reachable() {
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9000/minio/health/live 2>/dev/null || echo "000")
  assert_equal "MinIO API responds (HTTP 200)" "200" "${http_code}"
}
test_minio_api_reachable

# Test: MinIO Console responds on port 9001
test_minio_console_reachable() {
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9001 2>/dev/null || echo "000")
  # MinIO console returns 200 or 307 (redirect to login)
  if [[ "${http_code}" == "200" ]] || [[ "${http_code}" == "307" ]]; then
    echo "[PASS] MinIO Console responds (HTTP ${http_code})"
    total_tests=$((total_tests + 1))
    passed_tests=$((passed_tests + 1))
  else
    echo "[FAIL] MinIO Console responds — expected: 200 or 307, got: ${http_code}"
    total_tests=$((total_tests + 1))
    failed_tests=$((failed_tests + 1))
  fi
}
test_minio_console_reachable

# Test: Airflow webserver responds on port 8080
test_airflow_webserver_reachable() {
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/health 2>/dev/null || echo "000")
  assert_equal "Airflow webserver responds (HTTP 200)" "200" "${http_code}"
}
test_airflow_webserver_reachable

# ─────────────────────────────────────────────────────────────────────────────
# Test suite: Swarm secrets exist
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- Swarm Secrets ---"

# Test: Verify all required Swarm secrets exist
test_secret_exists() {
  local secret_name="$1"   # Name of the Swarm secret to verify
  local exists
  exists=$(docker secret ls --format '{{.Name}}' | grep -c "^${secret_name}$" || echo "0")
  assert_equal "Secret '${secret_name}' exists" "1" "${exists}"
}

# Check each required secret
test_secret_exists "minio_root_user"          # MinIO root username
test_secret_exists "minio_root_password"      # MinIO root password
test_secret_exists "airflow_fernet_key"       # Airflow Fernet key
test_secret_exists "airflow_secret_key"       # Airflow webserver secret
test_secret_exists "airflow_db_password"      # PostgreSQL password
test_secret_exists "airflow_admin_password"   # Airflow admin password

# ─────────────────────────────────────────────────────────────────────────────
# Test suite: Host data directories exist
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- Host Data Directories ---"

# Test: Verify host data directories exist
test_directory_exists() {
  local dir_path="$1"    # Directory path to verify
  local exists
  if [[ -d "${dir_path}" ]]; then
    exists="true"
  else
    exists="false"
  fi
  assert_equal "Directory '${dir_path}' exists" "true" "${exists}"
}

# Check each required host data directory
test_directory_exists "/opt/data-platform/minio/data"        # MinIO data
test_directory_exists "/opt/data-platform/airflow/dags"      # Airflow DAGs
test_directory_exists "/opt/data-platform/airflow/logs"      # Airflow logs
test_directory_exists "/opt/data-platform/airflow/plugins"   # Airflow plugins
test_directory_exists "/opt/data-platform/postgres/data"     # PostgreSQL data
test_directory_exists "/opt/data-platform/redis/data"        # Redis data

# ─────────────────────────────────────────────────────────────────────────────
# Test suite: Database connectivity
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- Database & Broker ---"

# Test: PostgreSQL accepts connections
test_postgres_connectivity() {
  local pg_ready
  pg_ready=$(docker exec "$(docker ps --filter 'name=airflow_postgres' --format '{{.ID}}' | head -1)" pg_isready -U airflow 2>/dev/null && echo "ready" || echo "not_ready")
  assert_contains "PostgreSQL accepts connections" "ready" "${pg_ready}"
}
test_postgres_connectivity

# Test: Redis responds to PING
test_redis_connectivity() {
  local redis_response
  redis_response=$(docker exec "$(docker ps --filter 'name=airflow_redis' --format '{{.ID}}' | head -1)" redis-cli ping 2>/dev/null || echo "no_response")
  assert_equal "Redis responds to PING" "PONG" "${redis_response}"
}
test_redis_connectivity

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "============================================="
echo "  Test Summary"
echo "============================================="
echo "  Total : ${total_tests}"
echo "  Passed: ${passed_tests}"
echo "  Failed: ${failed_tests}"
echo "============================================="

# Exit with non-zero code if any test failed
if [[ ${failed_tests} -gt 0 ]]; then
  echo ""
  echo "  ❌ SOME TESTS FAILED"
  exit 1
fi

echo ""
echo "  ✅ ALL TESTS PASSED"
exit 0
