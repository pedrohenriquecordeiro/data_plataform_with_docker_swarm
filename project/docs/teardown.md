# Teardown Guide

Complete teardown utility for removing all data platform resources from the server.

## Overview

The `scripts/teardown.sh` script is the reverse of the deployment process — it removes all Docker Swarm stacks, secrets, the overlay network, named volumes, and optionally purges host data directories. Think of it as the equivalent of `terraform destroy` for this platform.

## Usage

```bash
# Standard teardown (removes infra, keeps data)
sudo bash scripts/teardown.sh

# Dry-run — preview what would be removed without executing
sudo bash scripts/teardown.sh --dry-run

# Full teardown including host data directories
sudo bash scripts/teardown.sh --purge-data

# Dry-run with data purge preview
sudo bash scripts/teardown.sh --dry-run --purge-data
```

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--dry-run` | `false` | Print all actions without executing any destructive commands |
| `--purge-data` | `false` | Delete host data directories under `/opt/data-platform/` |

## What Gets Removed

The script removes resources in a specific order to respect dependencies:

### Step 1 — Docker Swarm Stacks

Stacks are removed in reverse-dependency order:

1. `airflow` — Airflow webserver, scheduler, worker, triggerer, postgres, redis
2. `minio` — MinIO object storage
3. `shared` — Shared infrastructure (if deployed)

After removal, the script waits up to **120 seconds** for all containers to drain, plus a 10-second grace period.

### Step 2 — Docker Swarm Secrets

All secrets created by the deploy scripts:

| Secret | Service |
|--------|---------|
| `minio_root_user` | MinIO |
| `minio_root_password` | MinIO |
| `airflow_fernet_key` | Airflow |
| `airflow_secret_key` | Airflow |
| `airflow_db_password` | PostgreSQL |
| `airflow_admin_password` | Airflow |
| `airflow_admin_user` | Airflow |

### Step 3 — Overlay Network

Removes the `data-platform-network` overlay network shared by all services.

### Step 4 — Docker Volumes

Removes all named Docker volumes with prefixes: `airflow_`, `minio_`, `shared_`.

### Step 4.5 — Custom Docker Images

Removes the custom Airflow image specified in the `.env` file (`AIRFLOW_IMAGE`). Falls back to `registry.local/data-platform/airflow:2.10.5` if `.env` is not found.

### Step 5 — Host Data Directories (optional, `--purge-data` only)

> **⚠️ Warning:** This permanently deletes all persistent data.

Directories removed when `--purge-data` is specified:

| Directory | Contents |
|-----------|----------|
| `/opt/data-platform/minio` | MinIO object data (S3 buckets) |
| `/opt/data-platform/airflow` | DAGs, logs, plugins |
| `/opt/data-platform/postgres` | PostgreSQL database files |
| `/opt/data-platform/redis` | Redis data |

A confirmation prompt (`Type 'yes' to confirm`) is required before deletion.

## Summary Report

After completion, the script prints a summary table showing the status of each resource:

```
=============================================
  Teardown Summary
=============================================
  RESOURCE                                 STATUS
  ────────────────────────────────────────  ──────────────────
  stack/airflow                            removed
  stack/minio                              removed
  secret/minio_root_user                   removed
  ...
=============================================
```

Possible statuses: `removed`, `skipped`, `failed`, `dry-run`.

## Recommended Workflow

1. **Always dry-run first:**
   ```bash
   sudo bash scripts/teardown.sh --dry-run
   ```

2. **Review the summary**, then execute:
   ```bash
   sudo bash scripts/teardown.sh
   ```

3. **Only use `--purge-data`** if you want to completely remove all persistent data and start fresh.
