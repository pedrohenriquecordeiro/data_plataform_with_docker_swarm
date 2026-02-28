# Data Platform v1.1.0

On-premise data platform running **MinIO** (object storage) and **Apache Airflow** (workflow orchestration) on **Docker Swarm**.

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| MinIO | RELEASE.2025-02-07 | S3-compatible object storage |
| Apache Airflow | 2.10.5 | Workflow orchestration & scheduling |
| PostgreSQL | 16.6-alpine | Airflow metadata database |
| Redis | 7.4.2-alpine | Celery message broker |

## Architecture

> The full architecture diagram is maintained as a draw.io file. Open [`docs/architecture.drawio`](docs/architecture.drawio) with [draw.io](https://app.diagrams.net/) or the VS Code draw.io extension.

```
┌─────────────────────────────────────────────────────────┐
│              Docker Swarm (Single Manager Node)          │
│                                                          │
│  ┌──── data-platform-network (overlay) ───────────────┐ │
│  │                                                     │ │
│  │  MinIO (:9000/:9001)   PostgreSQL (:5432)           │ │
│  │                                                     │ │
│  │  Airflow: Webserver (:8080) | Scheduler | Worker    │ │
│  │           Triggerer         | Redis (:6379)         │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Project Structure

```
.
├── .env.example                 # Environment variable template
├── airflow/
│   ├── Dockerfile               # Custom Airflow image
│   └── stack.airflow.yml        # Airflow stack definition
├── minio/
│   └── stack.minio.yml          # MinIO stack definition
├── scripts/
│   ├── deploy.sh                # Master deploy (all components)
│   ├── deploy_airflow.sh        # Airflow deployment & configuration
│   ├── deploy_minio.sh          # MinIO deployment & configuration
│   ├── healthcheck.sh           # Service health checks
│   ├── install_dependencies.sh  # Docker, Swarm, host dirs setup
│   ├── destroy.sh               # Full platform destroy
│   └── test_stack.sh            # Integration tests
├── tests/
│   └── test_dag_integrity.py    # DAG import validation (pytest)
└── docs/
    ├── architecture.md          # Architecture overview
    ├── deployment_guide.md      # Step-by-step deployment
    └── maintenance_guide.md     # Operations & maintenance
```

## Quick Start

1. **Install dependencies** (Docker, Swarm, host directories):
   ```bash
   make install
   ```

2. **Configure environment**:
   ```bash
   cp .env.example .env
   chmod 600 .env
   nano .env   # Set credentials and image tags
   ```

3. **Build the Airflow image**:
   ```bash
   make build-airflow
   ```

4. **Deploy everything**:
   ```bash
   make deploy
   ```

Or deploy components individually — see the [Deployment Guide](docs/deployment_guide.md).

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | Component diagram, networking, storage layout |
| [Deployment Guide](docs/deployment_guide.md) | Full step-by-step deployment instructions |
| [Maintenance Guide](docs/maintenance_guide.md) | Backups, upgrades, scaling, troubleshooting |
| [Destroy](docs/destroy.md) | How to remove the entire platform |

## Useful Commands

```bash
# Check health of all services
make status

# Run integration tests
make test

# Full destroy (dry-run first)
sudo bash scripts/destroy.sh --dry-run
make destroy
```
