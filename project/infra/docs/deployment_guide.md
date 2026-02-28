# Deployment Guide

Step-by-step guide for deploying the MinIO & Airflow data platform on an on-premise Linux server using Docker Swarm.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Step 1 — Install Dependencies](#step-1--install-dependencies)
- [Step 2 — Configure Environment Variables](#step-2--configure-environment-variables)
- [Step 3 — Build the Custom Airflow Image](#step-3--build-the-custom-airflow-image)
- [Step 4 — Deploy and Configure MinIO](#step-4--deploy-and-configure-minio)
- [Step 5 — Deploy and Configure Airflow](#step-5--deploy-and-configure-airflow)
- [Step 6 — Verify Deployment](#step-6--verify-deployment)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

Before starting, ensure you have:

| Requirement | Minimum Version | Notes |
|-------------|----------------|-------|
| Operating System | Ubuntu 22.04 / Debian 12 | Other Debian-based distros may work |
| Docker Engine | 24.0+ | Installed by `install_dependencies.sh` |
| Docker Compose plugin | 2.x | Installed alongside Docker |
| Python | 3.12 | For DAG integrity tests |
| curl | any | For health checks |
| jq | any | For JSON parsing |
| Root / sudo access | — | Required for Docker and directory creation |
| Static IP | — | Recommended for production |

### Hardware Recommendations

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 4 cores | 8+ cores |
| RAM | 16 GB | 32+ GB |
| Disk | 50 GB | 200+ GB SSD |

---

## Step 1 — Install Dependencies

Run the dependency installer script. This will install Docker Engine, the Compose plugin, initialize Docker Swarm and create all host data directories.

```bash
# Run the dependency installer (requires root)
make install
```

The script will:
1. Install Docker Engine (if not present)
2. Start and enable the Docker daemon
3. Install Docker Compose plugin (if not present)
4. Initialize Docker Swarm (if not active)
5. Install utility tools (curl, jq, python3)
6. Create host data directories under `/opt/data-platform/`

> **Note:** If the server has multiple network interfaces, you may need to specify the advertise address:
> ```bash
> docker swarm init --advertise-addr <INTERFACE>
> ```

---

## Step 2 — Configure Environment Variables

1. Copy the example environment file:

```bash
cp .env.example .env
```

2. Restrict file permissions (contains temporary credential values):

```bash
chmod 600 .env
```

3. Edit the `.env` file and set all required values:

```bash
nano .env
```

**Critical values to change:**

| Variable | Action |
|----------|--------|
| `AIRFLOW__CORE__FERNET_KEY` | Generate: `python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"` |
| `AIRFLOW_SECRET_KEY` | Generate: `python3 -c "import secrets; print(secrets.token_urlsafe(32))"` |
| `AIRFLOW_POSTGRES_PASSWORD` | Set a strong, unique password |
| `AIRFLOW_WWW_PASSWORD` | Set the initial admin password |
| `MINIO_WWW_PASSWORD` | Set a strong, unique password (min 8 chars) |
| `AIRFLOW_IMAGE` | Set to your registry path after building the image |

> **Note**: This step is handled **automatically** by the `make deploy` or `make all` process using default credentials if not done manually beforehand. Ensure you update `.env` for production workloads!

---

## Step 3 — Build the Custom Airflow Image

Build the custom Airflow image with the additional Python packages:

```bash
# Build the image automatically (run from the project root)
make build-airflow
```

This will build `local/data-platform-airflow:2.10.5` by default, or the image tagged in `AIRFLOW_IMAGE` in your `.env`.

> **Note (Post-deploy):** After a successful Airflow deployment, the locally built image is automatically deleted from the server to save space. Be prepared to rebuild it if you plan to spin down and up again.

---

## Step 4 — Deploy and Configure MinIO

Run the MinIO deployment script:

```bash
make deploy-minio
```

This script will:
1. Create Swarm secrets (`minio_root_user`, `minio_root_password`)
2. Create the `data-platform-network` overlay network (if not already present)
3. Create the MinIO data directory
4. Deploy the MinIO stack
5. Wait for MinIO to become healthy
6. Install the MinIO Client (`mc`) if not present
7. Configure an `mc` alias for the local MinIO server
8. Create the `init-bucket` bucket
9. Set the bucket access policy to private

**Expected output:**
```
[INFO] MinIO is healthy and accepting requests.
...
[INFO] MinIO deployment and configuration complete.
[INFO]   API      : http://127.0.0.1:9000
[INFO]   Console  : http://localhost:9001
[INFO]   Bucket   : init-bucket
[INFO]   Policy   : private (root credentials only)
```

---

## Step 5 — Deploy and Configure Airflow

Run the Airflow deployment script:

```bash
make deploy-airflow
```

This script will:
1. Create Swarm secrets (fernet key, webserver secret, DB password, admin credentials)
2. Ensure the `data-platform-network` overlay network exists (skips if already created by MinIO deploy)
3. Create host data directories for Airflow, PostgreSQL and Redis
4. Deploy the Airflow stack (webserver, scheduler, worker, triggerer, postgres, redis)
5. Wait for the webserver to become healthy
6. Configure the `minio_default` connection (S3-compatible)
7. Configure the `postgres_default` connection

**Expected output:**
```
[INFO] Airflow webserver is healthy and accepting requests.
...
[INFO] Airflow deployment and configuration complete.
[INFO]   Webserver  : http://localhost:8080
[INFO]   Scheduler  : running
[INFO]   Worker     : running (1 replica)
[INFO]   Triggerer  : running
[INFO]   Admin user : admin
[INFO]   Connections: minio_default, postgres_default
```

---

## Step 6 — Verify Deployment

### 6.1 — Run the health check

```bash
make status
```

All services should show `✅ HEALTHY`.

### 6.2 — Run integration tests

```bash
make test
```

All tests should show `[PASS]`.

### 6.3 — Access the web interfaces

| Service | URL |
|---------|-----|
| Airflow UI | `http://<HOST_IP>:8080` |
| MinIO Console | `http://<HOST_IP>:9001` |

### 6.4 — Verify Swarm services

```bash
# List all running services
docker service ls

# Expected output should show 1/1 replicas for each service
```

---

## Troubleshooting

### Service not starting

```bash
# Check service logs
docker service logs <service_name> --tail 100

# Check service status
docker service ps <service_name> --no-trunc
```

### MinIO not reachable

```bash
# Check MinIO container directly
docker service logs minio_minio --tail 50

# Verify port binding
ss -tlnp | grep -E '9000|9001'
```

### Airflow webserver not starting

```bash
# Check webserver logs
docker service logs airflow_airflow-webserver --tail 100

# Verify database is running
docker service logs airflow_postgres --tail 50
```

### Secret-related errors

```bash
# List all Swarm secrets
docker secret ls

# Re-create a secret (remove first, then create)
docker secret rm <secret_name>
echo -n "new_value" | docker secret create <secret_name> -
```

### Network issues

```bash
# List networks
docker network ls

# Inspect the overlay network
docker network inspect data-platform-network
```

---

## Deployment Order Summary

You can run the entire process in one go using the "all" method, or perform a direct component deployment manually:

### Option A: Comprehensive Deployment (All-in-one)

```
1. make all       → Runs install, deploy and status. It will build images and spin up everything sequentially.
```

### Option B: Direct Component Deployment

```
1. make install       → Docker, Swarm, host dirs
2. Configure .env     → Credentials (can be auto-generated later as well)
3. make deploy-minio  → Secrets + network + stack + buckets + policy
4. make deploy-airflow→ Custom Airflow image + Secrets + Airflow stack + DB + connections
5. make status        → Verify all services
```
