# Maintenance Guide

Comprehensive operations and maintenance guide for the MinIO & Airflow data platform on Docker Swarm.

## Table of Contents

- [Platform Overview](#platform-overview)
- [Service Architecture](#service-architecture)
- [Monitoring & Health Checks](#monitoring--health-checks)
- [Backup & Restore](#backup--restore)
- [Upgrade Procedures](#upgrade-procedures)
- [Log Management](#log-management)
- [Swarm Service Scaling](#swarm-service-scaling)
- [Scaling to Multi-Node](#scaling-to-multi-node)
- [Troubleshooting](#troubleshooting)
- [Common Maintenance Tasks](#common-maintenance-tasks)
- [Disaster Recovery](#disaster-recovery)
- [Teardown](#teardown)

---

## Platform Overview

This data platform provides an on-premise data engineering stack running on a single Linux server using Docker Swarm. It consists of:

- **MinIO** — S3-compatible object storage for raw data, processed files, and artifacts
- **Apache Airflow** — Workflow orchestration for scheduling and running data pipelines
- **PostgreSQL** — Airflow metadata database storing DAG runs, task states, and connections
- **Redis** — Celery message broker enabling distributed task execution across Airflow workers

All services communicate over a shared Docker Swarm overlay network (`data-platform-network`) and use Docker Swarm secrets for credential management. Persistent data is stored under `/opt/data-platform/` on the host.

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Docker Swarm (not K8s) | Simpler to operate on a single server; built into Docker Engine |
| Overlay network from day one | Zero reconfiguration needed when adding worker nodes |
| Bind-mount volumes | Simpler than named volumes; direct access to data on host |
| Celery executor | Production-grade distributed execution; scalable workers |
| All scripts idempotent | Safe to re-run at any time; facilitates disaster recovery |

---

## Service Architecture

```
┌─────────────────────────────────────────────────────────────┐
│              Docker Swarm (Single Manager Node)              │
│                                                              │
│  ┌────── data-platform-network (overlay) ──────────────────┐ │
│  │                                                          │ │
│  │  MinIO (:9000/:9001)    PostgreSQL (:5432)               │ │
│  │                                                          │ │
│  │  Airflow: Webserver (:8080)  |  Scheduler  |  Worker    │ │
│  │           Triggerer          |  Redis (:6379)            │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                              │
│  Host Ports: 8080, 9000, 9001                                │
│  Data: /opt/data-platform/                                   │
└─────────────────────────────────────────────────────────────┘
```

### Service Endpoints

| Service | Port | URL | Purpose |
|---------|------|-----|---------|
| Airflow Webserver | 8080 | `http://<HOST_IP>:8080` | DAG management, task monitoring |
| MinIO API | 9000 | `http://<HOST_IP>:9000` | S3-compatible API |
| MinIO Console | 9001 | `http://<HOST_IP>:9001` | Web UI for bucket management |
| PostgreSQL | 5432 | Internal only | Airflow metadata |
| Redis | 6379 | Internal only | Celery broker |

### Data Directory Layout

```
/opt/data-platform/
├── minio/data/         # MinIO object data (S3 buckets)
├── airflow/
│   ├── dags/           # DAG definition files
│   ├── logs/           # Task execution logs (90-day retention)
│   ├── plugins/        # Airflow plugins
│   └── config/         # Airflow configuration overrides
├── postgres/data/      # PostgreSQL database files
└── redis/data/         # Redis data (persistence disabled)
```

---

## Monitoring & Health Checks

### Automated Health Check

Run the global health check script to verify all services:

```bash
bash scripts/healthcheck.sh
```

This checks MinIO API, MinIO Console, Airflow Webserver, PostgreSQL, Redis, Scheduler, Worker, and Triggerer — reporting `✅ HEALTHY` or `❌ UNHEALTHY` for each.

### Integration Tests

Run the full integration test suite:

```bash
bash scripts/test_stack.sh
```

Tests cover: Swarm status, overlay network, stack deployments, service replicas, endpoint reachability, secrets, host directories, database connectivity, and Redis connectivity.

### Manual Monitoring Commands

```bash
# List all services with replica status
docker service ls

# Check specific service tasks
docker service ps airflow_airflow-webserver --no-trunc

# Follow live logs for a service
docker service logs airflow_airflow-scheduler --follow

# Check disk usage for platform data
du -sh /opt/data-platform/*/

# Check Docker system resource usage
docker system df
```

### DAG Integrity Tests

Validate that all DAG files import without errors:

```bash
pytest tests/test_dag_integrity.py -v
```

---

## Backup & Restore

### PostgreSQL Metadata Database

#### Manual Backup (`pg_dump`)

```bash
# Find the PostgreSQL container ID
POSTGRES_CONTAINER=$(docker ps --filter "name=airflow_postgres" --format '{{.ID}}' | head -1)

# Create a compressed SQL dump
docker exec "${POSTGRES_CONTAINER}" pg_dump -U airflow -Fc airflow > /opt/data-platform/backups/airflow_metadata_$(date +%Y%m%d_%H%M%S).dump
```

> **Tip:** Schedule via a system cron job for automated daily backups:
> ```bash
> # Crontab entry — daily backup at 02:00
> 0 2 * * * docker exec $(docker ps --filter "name=airflow_postgres" --format '{{.ID}}' | head -1) pg_dump -U airflow -Fc airflow > /opt/data-platform/backups/airflow_metadata_$(date +\%Y\%m\%d).dump 2>&1
> ```

#### Restore from Backup

```bash
POSTGRES_CONTAINER=$(docker ps --filter "name=airflow_postgres" --format '{{.ID}}' | head -1)

# Restore from a dump file
cat /opt/data-platform/backups/airflow_metadata_YYYYMMDD.dump | docker exec -i "${POSTGRES_CONTAINER}" pg_restore -U airflow -d airflow --clean --if-exists
```

### MinIO Data Backup

MinIO data backup is **not automated** in this deployment. To back up:

```bash
# Option 1: Use mc mirror to copy all data to a backup location
mc mirror local-minio/init-bucket /opt/data-platform/backups/minio/

# Option 2: Copy the raw data directory
cp -r /opt/data-platform/minio/data/ /opt/data-platform/backups/minio-raw/
```

### Configuration Backup

```bash
# Back up the .env file and stack definitions
tar czf /opt/data-platform/backups/config_$(date +%Y%m%d).tar.gz \
    .env \
    minio/stack.minio.yml \
    airflow/stack.airflow.yml
```

---

## Upgrade Procedures

### Airflow Upgrade

1. **Review release notes** at [Apache Airflow Releases](https://airflow.apache.org/docs/apache-airflow/stable/release_notes.html).

2. **Back up the metadata database** (see Backup section above).

3. **Update the Dockerfile** with the new base image version:

```bash
# Edit airflow/Dockerfile — change the FROM tag
# FROM apache/airflow:2.10.5-python3.12
# TO:  FROM apache/airflow:<NEW_VERSION>-python3.12
```

4. **Build and push the new image:**

```bash
docker build -t registry.local/data-platform/airflow:<NEW_VERSION> airflow/
docker push registry.local/data-platform/airflow:<NEW_VERSION>
```

5. **Update `.env`:**

```bash
AIRFLOW_IMAGE=registry.local/data-platform/airflow:<NEW_VERSION>
```

6. **Redeploy the stack:**

```bash
sudo bash scripts/deploy_airflow.sh
```

7. **Run database migration:**

```bash
CONTAINER=$(docker ps --filter "name=airflow_airflow-webserver" --format '{{.ID}}' | head -1)
docker exec "${CONTAINER}" airflow db migrate
```

### MinIO Upgrade

1. **Review release notes** at [MinIO Releases](https://github.com/minio/minio/releases).

2. **Update the image tag** in `minio/stack.minio.yml`:

```yaml
image: minio/minio:<NEW_RELEASE_TAG>
```

3. **Redeploy:**

```bash
sudo bash scripts/deploy_minio.sh
```

### PostgreSQL Upgrade

1. **Back up the database** (critical step — see Backup section).

2. **Update the image tag** in `airflow/stack.airflow.yml`:

```yaml
image: postgres:<NEW_VERSION>-alpine<ALPINE_VERSION>
```

3. **Redeploy:**

```bash
sudo bash scripts/deploy_airflow.sh
```

> **Warning:** Major PostgreSQL version upgrades (e.g., 16→17) require `pg_dump`/`pg_restore` migration. Minor version upgrades within the same major version are in-place safe.

### Redis Upgrade

1. **Update the image tag** in `airflow/stack.airflow.yml`:

```yaml
image: redis:<NEW_VERSION>-alpine<ALPINE_VERSION>
```

2. **Redeploy:**

```bash
sudo bash scripts/deploy_airflow.sh
```

---

## Log Management

### Airflow Task Logs

Airflow task logs are automatically cleaned after **90 days** via the native `AIRFLOW__LOG__LOG_RETENTION_DAYS=90` environment variable. No custom DAG is needed.

To manually inspect or clean logs:

```bash
# View disk usage of Airflow logs
du -sh /opt/data-platform/airflow/logs/

# Manually remove logs older than 90 days
find /opt/data-platform/airflow/logs/ -type f -mtime +90 -delete
```

### Docker Container Logs

All container logs use the `json-file` driver with rotation configured:

| Service | Max Size | Max Files | Total Max |
|---------|----------|-----------|-----------|
| MinIO | 50 MB | 5 | 250 MB |
| Webserver | 50 MB | 5 | 250 MB |
| Scheduler | 50 MB | 5 | 250 MB |
| Worker | 50 MB | 5 | 250 MB |
| Triggerer | 25 MB | 3 | 75 MB |
| PostgreSQL | 50 MB | 5 | 250 MB |
| Redis | 25 MB | 3 | 75 MB |

To check log disk usage:

```bash
# Find Docker container log files
find /var/lib/docker/containers/ -name "*.log" -exec ls -lh {} \;

# Check total Docker log disk usage
du -sh /var/lib/docker/containers/
```

---

## Swarm Service Scaling

### Scale Airflow Workers

```bash
# Scale workers to N replicas
docker service scale airflow_airflow-worker=3

# Verify scaling
docker service ls --filter "name=airflow_airflow-worker"

# View worker tasks
docker service ps airflow_airflow-worker
```

### Check Service Status

```bash
# List all services with their replica counts
docker service ls

# View detailed service information
docker service inspect <service_name> --pretty

# View service tasks (containers)
docker service ps <service_name> --no-trunc
```

### Force Service Update (Rolling Restart)

```bash
# Force a rolling restart of a service
docker service update --force airflow_airflow-webserver
```

---

## Scaling to Multi-Node

This section documents the procedure for expanding from a single-node to a multi-node Docker Swarm cluster.

### Step 1 — Get the Join Token

On the **manager node**, retrieve the worker join token:

```bash
docker swarm join-token worker
```

This outputs a command like:

```bash
docker swarm join --token SWMTKN-1-xxxxxxxx <MANAGER_IP>:2377
```

### Step 2 — Join Worker Nodes

On each **new worker node**:

1. Install Docker Engine (run `scripts/install_dependencies.sh` — it will skip Swarm init on worker nodes, so initialize manually using the join command).

2. Join the Swarm:

```bash
docker swarm join --token SWMTKN-1-xxxxxxxx <MANAGER_IP>:2377
```

3. Verify the node joined:

```bash
# On the manager node
docker node ls
```

### Step 3 — Migrate Bind-Mount Volumes to Shared Storage

On a single node, DAGs, logs, and plugins are bind-mounted from the local filesystem. For multi-node, these must be accessible from all nodes.

**Options:**

| Storage | Complexity | Notes |
|---------|------------|-------|
| NFS | Low | Simple to set up; some performance limitations |
| GlusterFS | Medium | Distributed filesystem; good for multiple nodes |
| Rook/Ceph | High | Enterprise-grade; overkill for small clusters |

**Migration procedure (NFS example):**

1. Set up an NFS server on the manager node:

```bash
apt-get install -y nfs-kernel-server
echo "/opt/data-platform *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
exportfs -ra
```

2. On each worker node, mount the NFS share:

```bash
apt-get install -y nfs-common
mkdir -p /opt/data-platform
mount <MANAGER_IP>:/opt/data-platform /opt/data-platform
echo "<MANAGER_IP>:/opt/data-platform /opt/data-platform nfs defaults 0 0" >> /etc/fstab
```

### Step 4 — Scale Worker Replicas

Once shared storage is configured:

```bash
# Scale Airflow workers across nodes
docker service scale airflow_airflow-worker=3

# Workers will be distributed across available nodes by the Swarm scheduler
```

### Step 5 — MinIO Scale-Out Path

Current deployment: Single-Node Single-Drive (SNSD).

To expand to Multi-Node Multi-Drive (MNMD):

1. Add additional drives/nodes.
2. Use `mc mirror` to copy existing data to the new cluster.
3. Update `stack.minio.yml` with the new MultiNode configuration.
4. Redeploy.

> **Full MinIO expansion documentation:** [MinIO Multi-Node Multi-Drive](https://min.io/docs/minio/linux/operations/install-deploy-manage/deploy-minio-multi-node-multi-drive.html)

---

## Troubleshooting

### Service Not Starting

```bash
# Check service logs (last 100 lines)
docker service logs <service_name> --tail 100

# Check service task status (shows error messages)
docker service ps <service_name> --no-trunc

# List all recent events
docker events --since 10m
```

**Common causes:**
- Missing Docker secrets → Run the deploy script to recreate them
- Missing host directories → Run `scripts/install_dependencies.sh`
- Image not found → Build the Airflow image first: `docker build -t <tag> airflow/`
- Port already in use → Check with `ss -tlnp | grep <port>`

### MinIO Not Reachable

```bash
# Check MinIO container directly
docker service logs minio_minio --tail 50

# Verify port binding
ss -tlnp | grep -E '9000|9001'

# Test the health endpoint
curl -sf http://localhost:9000/minio/health/live
```

### Airflow Webserver Not Starting

```bash
# Check webserver logs
docker service logs airflow_airflow-webserver --tail 100

# Check init service logs (database migration)
docker service logs airflow_airflow-init --tail 100

# Verify database is running
docker service logs airflow_postgres --tail 50

# Check if database migration completed
docker exec $(docker ps --filter "name=airflow_airflow-webserver" --format '{{.ID}}' | head -1) airflow db check
```

### DAGs Not Showing in UI

```bash
# Verify DAG files are in the correct directory
ls -la /opt/data-platform/airflow/dags/

# Check scheduler logs for parsing errors
docker service logs airflow_airflow-scheduler --tail 100 | grep -i "error\|warning"

# Force scheduler to re-parse DAGs
docker service update --force airflow_airflow-scheduler
```

### Secret-Related Errors

```bash
# List all Swarm secrets
docker secret ls

# Re-create a secret (remove first, then create)
docker secret rm <secret_name>
echo -n "new_value" | docker secret create <secret_name> -
```

### Network Issues

```bash
# List networks
docker network ls

# Inspect the overlay network
docker network inspect data-platform-network

# Verify services are attached
docker service inspect <service_name> --format '{{json .Spec.TaskTemplate.Networks}}'
```

### Disk Space Issues

```bash
# Check overall disk usage
df -h /opt/data-platform/

# Per-component usage
du -sh /opt/data-platform/*/

# Docker system disk usage
docker system df

# Prune unused resources
docker system prune -f
```

---

## Common Maintenance Tasks

### Restart a Service

```bash
# Restart a specific service (rolling restart)
docker service update --force airflow_airflow-scheduler
```

### View Service Logs

```bash
# View last 100 lines of logs
docker service logs airflow_airflow-webserver --tail 100

# Follow live logs
docker service logs airflow_airflow-webserver --follow
```

### Check Disk Usage

```bash
# Overall disk usage
df -h /opt/data-platform/

# Per-component usage
du -sh /opt/data-platform/*/
```

### Prune Docker Resources

```bash
# Remove unused images
docker image prune -f

# Remove unused volumes (CAUTION: may delete data)
docker volume prune -f

# Full cleanup
docker system prune -f
```

### Adding New DAGs

1. Copy the DAG `.py` file to `/opt/data-platform/airflow/dags/`.
2. The scheduler will automatically detect and parse the new DAG within 30 seconds.
3. New DAGs start paused — unpause via the Airflow UI or CLI:
   ```bash
   docker exec $(docker ps --filter "name=airflow_airflow-webserver" --format '{{.ID}}' | head -1) airflow dags unpause <dag_id>
   ```

### Clearing Task Instances

```bash
# Clear all task instances for a DAG run
docker exec $(docker ps --filter "name=airflow_airflow-webserver" --format '{{.ID}}' | head -1) airflow tasks clear <dag_id> -s <start_date> -e <end_date> --yes
```

---

## Disaster Recovery

### RTO Strategy

The recovery strategy is based on idempotent redeployment from a known good state:

1. **Back up your `.env` file** and stack definitions regularly.
2. **Maintain PostgreSQL backups** (automated via cron — see Backup section).
3. **To recover:**

```bash
# 1. Run dependency installer on a new/clean server
sudo bash scripts/install_dependencies.sh

# 2. Restore .env configuration
cp backup/.env .env

# 3. Build Airflow image
docker build -t <AIRFLOW_IMAGE_TAG> airflow/

# 4. Deploy all services
sudo bash scripts/deploy.sh

# 5. Restore PostgreSQL backup
POSTGRES_CONTAINER=$(docker ps --filter "name=airflow_postgres" --format '{{.ID}}' | head -1)
cat backup/airflow_metadata.dump | docker exec -i "${POSTGRES_CONTAINER}" pg_restore -U airflow -d airflow --clean --if-exists

# 6. Restore MinIO data (if backed up)
mc mirror backup/minio/ local-minio/init-bucket/

# 7. Verify
bash scripts/healthcheck.sh
```

---

## Teardown

To remove the entire data platform, see the [Teardown Guide](teardown.md).

```bash
# Preview what will be removed
sudo bash scripts/teardown.sh --dry-run

# Execute teardown
sudo bash scripts/teardown.sh

# Full teardown including data directories
sudo bash scripts/teardown.sh --purge-data
```
