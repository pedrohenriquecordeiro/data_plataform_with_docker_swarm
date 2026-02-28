#!/usr/bin/env bash
# install_dependencies.sh — Check and install all required dependencies on the server.
# This script verifies that Docker, Docker Compose plugin and Docker Swarm are
# available. If a dependency is missing, it attempts to install it automatically.
# Supports Debian/Ubuntu-based Linux distributions.
# Usage: sudo bash scripts/install_dependencies.sh

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
# Pre-flight checks
# ─────────────────────────────────────────────────────────────────────────────

# Ensure the script is run as root (required for package installation)
if [[ "$(id -u)" -ne 0 ]]; then
  log_error "This script must be run as root or with sudo."
  exit 1
fi

# Detect the OS distribution to ensure compatibility
if ! grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then
  log_warn "This script is designed for Debian/Ubuntu-based systems."
  log_warn "Proceeding anyway — manual adjustments may be needed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Minimum required versions
# ─────────────────────────────────────────────────────────────────────────────

# Minimum Docker Engine version required by the deployment
readonly MINIMUM_DOCKER_VERSION="24.0"

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────

# Compare two semantic version strings (major.minor).
# Returns 0 if version_a >= version_b, 1 otherwise.
version_gte() {
  local version_a="$1"   # Version to check
  local version_b="$2"   # Minimum required version

  # Use sort -V (version sort) to determine ordering
  local sorted_first
  sorted_first=$(printf '%s\n%s' "$version_a" "$version_b" | sort -V | head -n1)

  # If the minimum version sorts first (or equal), then version_a >= version_b
  [[ "$sorted_first" == "$version_b" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Check and install Docker Engine
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 1: Checking Docker Engine installation..."

if command -v docker &>/dev/null; then
  # Docker is installed — verify the version meets the minimum requirement
  installed_docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0")
  log_info "Docker Engine found: version ${installed_docker_version}"

  if version_gte "${installed_docker_version}" "${MINIMUM_DOCKER_VERSION}"; then
    log_info "Docker version ${installed_docker_version} meets minimum requirement (>= ${MINIMUM_DOCKER_VERSION}). Skipping installation."
  else
    log_error "Docker version ${installed_docker_version} is below the minimum required (${MINIMUM_DOCKER_VERSION})."
    log_error "Please upgrade Docker manually: https://docs.docker.com/engine/install/"
    exit 1
  fi
else
  # Docker is not installed — install it using the official convenience script
  log_info "Docker Engine not found. Installing via official Docker repository..."

  # Update package index to ensure fresh package lists
  apt-get update -y

  # Install prerequisite packages for HTTPS repository access
  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

  # Add Docker's official GPG signing key
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Add the Docker apt repository to the system sources
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  # Update package index again to include Docker packages
  apt-get update -y

  # Install Docker Engine, CLI, containerd and the Compose plugin
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  log_info "Docker Engine installed successfully."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Verify Docker daemon is running
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 2: Verifying Docker daemon is running..."

if docker info &>/dev/null; then
  # Docker daemon is active and responsive
  log_info "Docker daemon is running."
else
  # Attempt to start the Docker service via systemd
  log_warn "Docker daemon is not running. Attempting to start..."
  systemctl start docker
  systemctl enable docker    # Enable Docker to start on boot

  # Verify the daemon started successfully
  if docker info &>/dev/null; then
    log_info "Docker daemon started successfully."
  else
    log_error "Failed to start Docker daemon. Check 'journalctl -xeu docker' for details."
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Check and install Docker Compose plugin
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 3: Checking Docker Compose plugin..."

if docker compose version &>/dev/null; then
  # Docker Compose plugin is available
  compose_version=$(docker compose version --short 2>/dev/null || echo "unknown")
  log_info "Docker Compose plugin found: version ${compose_version}. Skipping installation."
else
  # Docker Compose plugin is missing — install it
  log_info "Docker Compose plugin not found. Installing..."
  apt-get install -y docker-compose-plugin

  # Verify installation succeeded
  if docker compose version &>/dev/null; then
    log_info "Docker Compose plugin installed successfully."
  else
    log_error "Failed to install Docker Compose plugin."
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Check and initialize Docker Swarm
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 4: Checking Docker Swarm status..."

# Query the local Swarm state from Docker info
swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")

if [[ "${swarm_state}" == "active" ]]; then
  # Swarm is already initialized — no action needed
  log_info "Docker Swarm is already active. Skipping initialization."
else
  # Swarm is not initialized — initialize this node as a manager
  log_info "Docker Swarm is not active (state: ${swarm_state}). Initializing..."
  # TODO(user): if the node has multiple network interfaces, run:
  #   docker swarm init --advertise-addr <INTERFACE>
  docker swarm init

  # Verify Swarm is now active
  swarm_state_after=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")
  if [[ "${swarm_state_after}" == "active" ]]; then
    log_info "Docker Swarm initialized successfully. This node is now a manager."
  else
    log_error "Failed to initialize Docker Swarm. Check 'docker info' for details."
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Check for additional useful tools
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 5: Checking for additional tools..."

# Check if curl is available (needed by healthchecks and MinIO client)
if command -v curl &>/dev/null; then
  log_info "curl is available. Skipping installation."
else
  log_info "Installing curl..."
  apt-get install -y curl
fi

# Check if jq is available (useful for parsing JSON output from Docker and APIs)
if command -v jq &>/dev/null; then
  log_info "jq is available. Skipping installation."
else
  log_info "Installing jq..."
  apt-get install -y jq
fi

# Check if Python 3 is available (needed for DAG integrity tests)
if command -v python3 &>/dev/null; then
  python_version=$(python3 --version 2>/dev/null || echo "unknown")
  log_info "Python 3 found: ${python_version}. Skipping installation."
else
  log_info "Installing Python 3..."
  apt-get install -y python3 python3-pip
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Create host data directories
# ─────────────────────────────────────────────────────────────────────────────

log_info "Step 6: Creating host data directories under /opt/data-platform..."

# Create all required directories for persistent data storage.
# -p flag ensures parent directories are created and no error if they already exist.
mkdir -p /opt/data-platform/minio/data          # MinIO object storage data
mkdir -p /opt/data-platform/airflow/dags         # Airflow DAG files
mkdir -p /opt/data-platform/airflow/logs         # Airflow task logs
mkdir -p /opt/data-platform/airflow/plugins      # Airflow plugins
mkdir -p /opt/data-platform/airflow/config       # Airflow config files
mkdir -p /opt/data-platform/postgres/data        # PostgreSQL data directory
mkdir -p /opt/data-platform/redis/data           # Redis data directory

log_info "Host data directories created successfully."

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

log_info "============================================="
log_info "  All dependencies verified and installed."
log_info "============================================="
log_info ""
log_info "  Docker Engine : $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
log_info "  Compose Plugin: $(docker compose version --short 2>/dev/null)"
log_info "  Swarm State   : $(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)"
log_info "  Node Role     : $(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null | sed 's/true/manager/;s/false/worker/')"
log_info ""
log_info "  Next step: copy .env.example to .env and fill in the values."
log_info "============================================="
