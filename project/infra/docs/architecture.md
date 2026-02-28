# Architecture Overview

Data platform architecture for MinIO and Apache Airflow deployed on a single on-premise Linux server using Docker Swarm.

## Table of Contents

- [System Diagram](#system-diagram)
- [Components](#components)
- [Networking](#networking)
- [Data Flow](#data-flow)
- [Storage Layout](#storage-layout)
- [Security Boundaries](#security-boundaries)
- [Scale-Out Path](#scale-out-path)

---

## System Diagram

> **Note:** The architecture diagram is maintained as a draw.io file. Open `architecture.drawio` with [draw.io](https://app.diagrams.net/) or the VS Code draw.io extension to view and edit it.
>
> TODO(user): Create the `architecture.drawio` diagram file showing the components below.

### Text-Based Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Docker Swarm (Single Manager Node)                   │
│                                                                         │
│  ┌─────────────────────── data-platform-network (overlay) ────────────┐ │
│  │                                                                     │ │
│  │  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐   │ │
│  │  │   MinIO       │   │  PostgreSQL  │   │    Redis             │   │ │
│  │  │  :9000 (API)  │   │  :5432       │   │    :6379             │   │ │
│  │  │  :9001 (UI)   │   │              │   │    (broker + result) │   │ │
│  │  └──────┬───────┘   └──────┬───────┘   └──────────┬───────────┘   │ │
│  │         │                   │                       │               │ │
│  │  ┌──────┴───────────────────┴───────────────────────┴──────────┐   │ │
│  │  │                   Airflow Components                         │   │ │
│  │  │  ┌─────────────┐ ┌─────────────┐ ┌──────────┐ ┌──────────┐ │   │ │
│  │  │  │  Webserver   │ │  Scheduler  │ │  Worker  │ │ Triggerer│ │   │ │
│  │  │  │  :8080       │ │             │ │ (Celery) │ │          │ │   │ │
│  │  │  └─────────────┘ └─────────────┘ └──────────┘ └──────────┘ │   │ │
│  │  └─────────────────────────────────────────────────────────────┘   │ │
│  │                                                                     │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  Host Ports: 8080 (Airflow UI), 9000 (MinIO API), 9001 (MinIO Console) │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Components

### MinIO (Object Storage)

| Attribute | Value |
|-----------|-------|
| Image | `minio/minio:RELEASE.2025-02-07T23-21-09Z` |
| Mode | Single-Node Single-Drive (SNSD) |
| Ports | `9000` (S3 API), `9001` (Web Console) |
| Bucket | `init-bucket` (single bucket, path prefixes) |
| Credentials | Docker Swarm secrets (`minio_root_user`, `minio_root_password`) |

### Apache Airflow (Workflow Orchestration)

| Component | Image | Role |
|-----------|-------|------|
| Webserver | Custom (`airflow:2.10.5`) | UI + REST API |
| Scheduler | Custom (`airflow:2.10.5`) | DAG parsing + task scheduling |
| Worker | Custom (`airflow:2.10.5`) | Celery task execution |
| Triggerer | Custom (`airflow:2.10.5`) | Deferred task handling |

### PostgreSQL (Metadata Database)

| Attribute | Value |
|-----------|-------|
| Image | `postgres:16.6-alpine3.21` |
| Purpose | Airflow metadata storage |
| Connections | Direct (no PgBouncer) |
| Password | Docker Swarm secret (`airflow_db_password`) |

### Redis (Message Broker)

| Attribute | Value |
|-----------|-------|
| Image | `redis:7.4.2-alpine3.21` |
| Purpose | Celery broker (DB 0) + result backend (DB 1) |
| Persistence | Disabled (ephemeral broker) |

---

## Networking

All services communicate over a single flat **Docker Swarm overlay network** named `data-platform-network`.

### Key design decisions:

1. **Overlay from day one** — Even on a single node, the overlay driver is used so that adding Swarm worker nodes requires zero network reconfiguration.
2. **Service DNS** — Inter-service communication uses Docker Swarm DNS names (`redis`, `postgres`, `minio`), never `localhost` or host IPs.
3. **No host-mode networking** — All services use Swarm routing mesh for port exposure.
4. **No encryption** — Plain overlay (no VXLAN encryption) since all traffic is internal.
5. **No reverse proxy** — Services are exposed directly via host port bindings.

### External access:

| Service | Host Port | URL |
|---------|-----------|-----|
| Airflow UI | `8080` | `http://<HOST_IP>:8080` |
| MinIO API | `9000` | `http://<HOST_IP>:9000` |
| MinIO Console | `9001` | `http://<HOST_IP>:9001` |

---

## Data Flow

```
                          ┌──────────────────┐
                          │   DAG Authors    │
                          │ (manual copy)    │
                          └────────┬─────────┘
                                   │
                            DAG .py files
                                   │
                                   ▼
                     /opt/data-platform/airflow/dags
                          (bind-mount on host)
                                   │
            ┌──────────────────────┼──────────────────────┐
            │                      │                      │
            ▼                      ▼                      ▼
      ┌──────────┐         ┌──────────┐         ┌──────────────┐
      │ Scheduler │         │ Webserver│         │   Worker     │
      │ (parses)  │         │ (UI)     │         │ (executes)   │
      └────┬─────┘         └──────────┘         └──────┬───────┘
           │                                            │
           │  schedules tasks                    reads/writes
           │  via Celery                         data via S3 API
           ▼                                            │
      ┌──────────┐                                      ▼
      │  Redis    │                                ┌──────────┐
      │ (broker)  │                                │  MinIO    │
      └──────────┘                                 │ (storage) │
                                                   └──────────┘
```

---

## Storage Layout

All persistent data resides under `/opt/data-platform` on the host:

```
/opt/data-platform/
├── minio/
│   └── data/           # MinIO object data (S3 buckets)
├── airflow/
│   ├── dags/           # DAG definition files
│   ├── logs/           # Task execution logs (90-day retention)
│   ├── plugins/        # Airflow plugins
│   └── config/         # Airflow configuration overrides
├── postgres/
│   └── data/           # PostgreSQL database files
└── redis/
    └── data/           # Redis data (persistence disabled)
```

---

## Security Boundaries

### Secrets Management

All sensitive credentials are stored as **Docker Swarm secrets** and mounted at `/run/secrets/<name>` inside containers:

| Secret | Service | Purpose |
|--------|---------|---------|
| `minio_root_user` | MinIO | Root username |
| `minio_root_password` | MinIO | Root password |
| `airflow_fernet_key` | Airflow | Encryption key for metadata |
| `airflow_secret_key` | Airflow | Webserver session key |
| `airflow_db_password` | PostgreSQL | Database user password |
| `airflow_admin_password` | Airflow | Initial admin password |

### What is NOT in scope

- TLS termination (internal network only)
- RBAC / multi-user access control
- Encryption at rest
- Network firewall rules
- External identity providers

---

## Scale-Out Path

The architecture is designed for single-node operation with a clear path to multi-node expansion:

1. **Join new worker nodes:** `docker swarm join --token <WORKER_TOKEN> <MANAGER_IP>:2377`
2. **Scale workers:** `docker service scale airflow_airflow-worker=N`
3. **Migrate storage:** Replace bind-mount volumes with shared storage (NFS, GlusterFS) for DAGs, logs and plugins
4. **MinIO expansion:** Migrate from SNSD to MNMD via `mc mirror` when additional drives/nodes are available

> **See also:** `maintenance_guide.md` → "Scaling to Multi-Node" section for detailed procedures.
