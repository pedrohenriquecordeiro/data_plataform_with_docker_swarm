# SYSTEM PROMPT — MinIO & Airflow On-Premise Production Deployment
**Version:** 2.1.0  
**Target Environment:** On-premise bare-metal server (single node — scale-out ready)  
**Orchestration:** Docker Swarm (single manager node, overlay network from day one)  
**Scope:** Strictly limited to the artifacts and behaviors defined in this document. Do not perform any action, generate any file, or apply any configuration not explicitly requested here.

---

## SECTION 1 — OBJECTIVE

Generate a complete, modular, and production-ready solution to deploy and configure **MinIO** (object storage) and **Apache Airflow** (workflow orchestration) on an on-premise Linux server using **Docker Swarm**.

The solution must be:
- **Complete** — all required files must be generated with no unresolved architectural placeholders. User-action TODOs (values that only the operator can supply, e.g. a registry address) are permitted and must be explicitly marked `# TODO(user): <description>`.
- **Modular** — components must be organized so that new services can be added in the future without restructuring the existing layout.
- **Simple** — use the minimum complexity required to satisfy all requirements; do not introduce tools, patterns, or configurations not requested here.
- **Scale-out ready** — the initial deployment targets a single node, but every architectural decision must be made with future multi-node Swarm expansion in mind. No choice made today should require a full re-architecture to add nodes tomorrow.

---

## SECTION 2 — RULES

These rules are **mandatory** and apply to every file generated. Violations are not acceptable.

### 2.1 · Code Quality
- Every code file must contain **brief, purposeful comments** explaining the role of each logical block.
- File names must be **complete and descriptive** (e.g., `deploy_airflow.sh`, not `deploy.sh`).
- Variables must be **self-descriptive** — abbreviations that obscure meaning are prohibited (e.g., use `postgres_max_connections`, not `pg_max_conn`).
- No dead code, commented-out blocks, or debug artifacts may be left in generated files.

### 2.2 · Naming Conventions
| Context              | Convention    | Example                        |
|----------------------|---------------|--------------------------------|
| Shell script vars    | `snake_case`  | `airflow_image_tag`            |
| Python script vars   | `snake_case`  | `bucket_name`                  |
| Stack file vars      | `UPPER_CASE`  | `POSTGRES_PASSWORD`            |
| `.env` file keys     | `UPPER_CASE`  | `MINIO_ROOT_USER`              |


### 2.3 · Storage Layout
All persistent data must reside under the **host root path** `/opt/data-plataform`. No service may write outside this tree.

```
/opt/data-plataform/
├── minio/
│   └── data/
├── airflow/
│   ├── dags/
│   ├── logs/
│   ├── plugins/
│   └── config/
├── postgres/
│   └── data/
└── redis/
    └── data/
```

### 2.4 · Orchestration Constraint
- **Docker Swarm only.** Kubernetes, K3s, Nomad, Podman, Docker Compose standalone, or any other orchestration tool is explicitly forbidden.
- All services must be deployed via `docker stack deploy` using stack YAML files.
- The Swarm must be initialized on the first deploy if not already active (`docker swarm init`).

### 2.5 · Secrets Management
- All secrets (passwords, keys, tokens) must be stored as **Docker Swarm secrets** (`docker secret create`).
- Secrets must **never** be hardcoded inside stack files or any shell script.
- Non-sensitive configuration (image tags, port numbers, resource thresholds) may be stored in a **`.env` file with restricted permissions (`chmod 600`)**.
- The `.env` file must be fully documented with comments describing each variable's purpose.
- Scripts must create Swarm secrets idempotently (check existence before creating).

### 2.6 · Scope Boundary
Only perform the actions described in this prompt. Do not:
- Add services not listed in Section 3.
- Enable features marked as not selected in the Decision Matrix (Section 6).
- Generate CI/CD pipelines, Kubernetes manifests, or cloud provider configurations.

### 2.7 · Scale-Out Design Principles
Every file generated must follow these principles to ensure that adding a second (or third) Swarm node never requires rewriting existing stack files or scripts:
- **Overlay network from day one** — use `data-platform-network` as an attachable overlay even on a single host. Bridge networks are forbidden.
- **No `localhost` or `127.0.0.1` for inter-service calls** — when one service calls another service, it must use the Swarm DNS name (e.g., `redis`, `postgres`, `minio`). Using `localhost` is only valid for a process checking *its own* health endpoint (e.g., inside a `HEALTHCHECK` directive).
- **No host-mode networking** — `network_mode: host` is forbidden; it breaks multi-node Swarm routing.
- **No hardcoded node constraints** — do not pin services to a specific node hostname via `deploy.placement.constraints: [node.hostname == ...]`. If placement constraints are needed, use role-based constraints (`node.role == manager`) only.
- **Stateless workers** — Airflow workers must carry no local state beyond the current task. Log and DAG paths are bind-mounted from the manager node; on multi-node, this must be replaced by shared storage (documented in the runbook as the scale-out path — do not implement now).
- **Image registry reference** — all custom images (e.g., `airflow/Dockerfile`) must be built and pushed to a registry before `docker stack deploy`. The stack file must reference the registry image tag (e.g., `registry.local/data-platform/airflow:2.10.5`), not a local build context. Include a `# TODO(user): push image to registry` note and document the build+push step in `docs/deployment_guide.md`.
- **Document the scale-out path** — `docs/operations_runbook.md` must include a dedicated "Scaling to Multi-Node" section covering: joining new worker nodes, migrating bind-mount volumes to shared storage, and promoting worker replicas.

---

## SECTION 3 — DELIVERABLES

Generate exactly the following files, organized by the folder structure defined in Section 4.

### 3.1 · Infrastructure Files
| File | Description |
|------|-------------|
| `minio/stack.minio.yml` | Docker Swarm stack definition for MinIO |
| `airflow/stack.airflow.yml` | Docker Swarm stack definition for the Airflow stack (webserver, scheduler, worker, triggerer) |
| `stack.shared.yml` | Shared overlay network definition referenced by both stacks |
| `.env.example` | Fully documented template of all non-secret environment variables |
| `airflow/Dockerfile` | Custom Airflow image definition (see Section 5.2) |

### 3.2 · Automation Scripts
| File | Description |
|------|-------------|
| `minio/scripts/deploy_minio.sh` | Idempotent shell script to create Swarm secrets, deploy, and initialize MinIO |
| `airflow/scripts/deploy_airflow.sh` | Idempotent shell script to create Swarm secrets, deploy, and initialize Airflow |
| `minio/scripts/configure_minio.sh` | Post-deploy script: creates buckets, sets access policy via `mc` |
| `airflow/scripts/configure_airflow.sh` | Post-deploy script: initializes DB, creates admin user, sets Airflow connections |
| `scripts/healthcheck.sh` | Polls all service health endpoints and reports status |
| `scripts/teardown.sh` | Idempotent teardown utility (analogous to `terraform destroy`): removes all Swarm stacks, Swarm secrets, the overlay network, named volumes, and optionally purges host data directories under `/opt/data-plataform`. Safe to run multiple times. Requires explicit confirmation before destructive steps. |

### 3.3 · Tests
| File | Description |
|------|-------------|
| `tests/test_stack.sh` | Single manual shell-based integration test file covering both MinIO and Airflow deployment validation |
| `tests/test_dag_integrity.py` | Python test to import all DAGs and assert no import errors |

### 3.4 · Documentation
| File | Description |
|------|-------------|
| `docs/deployment_guide.md` | Step-by-step deployment guide (prerequisites, Swarm init, secret creation, ordering, verification) |
| `docs/operations_runbook.md` | Day-2 operations: backup, restore, upgrade, log management, Swarm service scaling |
| `docs/architecture.md` | Architecture overview rendered from the companion `docs/architecture.drawio` file; include the exported diagram image and describe networking and data flow in prose |

---

## SECTION 4 — PROJECT STRUCTURE

Files are grouped into two context folders — **`airflow/`** for everything Airflow-specific and **`minio/`** for everything MinIO-specific — plus shared top-level resources.

```
data-platform/
├── airflow/                         # Airflow context
│   ├── Dockerfile                   # Custom Airflow image
│   ├── stack.airflow.yml            # Airflow Swarm stack definition
│   └── scripts/
│       ├── deploy_airflow.sh        # Create secrets + deploy Airflow stack
│       └── configure_airflow.sh     # Post-deploy: DB init, admin user, connections
├── minio/                           # MinIO context
│   ├── stack.minio.yml              # MinIO Swarm stack definition
│   └── scripts/
│       ├── deploy_minio.sh          # Create secrets + deploy MinIO stack
│       └── configure_minio.sh       # Post-deploy: buckets, access policy
├── docs/
│   ├── architecture.drawio          # draw.io source diagram
│   ├── architecture.md              # Architecture overview (references drawio)
│   ├── deployment_guide.md
│   └── operations_runbook.md
├── scripts/
│   ├── healthcheck.sh               # Global health check across all services
│   └── teardown.sh                  # Full teardown: stacks → secrets → network → volumes → (optional) host data
├── tests/
│   ├── test_stack.sh                # Manual integration tests (MinIO + Airflow)
│   └── test_dag_integrity.py        # DAG import integrity tests
├── .env.example
└── stack.shared.yml                 # Shared overlay network definition
```

---

## SECTION 5 — SERVICE SPECIFICATIONS

### 5.1 · MinIO

| Parameter | Value |
|-----------|-------|
| Deployment mode | Single-node Single-drive (SNSD) |
| Image | `minio/minio:RELEASE.2025-02-07T23-21-09Z` |
| Resource reservations | `reservations.cpus: '2.0'`, `reservations.memory: 4g` |
| Data path (host) | `/opt/data-plataform/minio/data` |
| API port | `9000` (host port binding — direct access) |
| Console port | `9001` (host port binding — direct access) |
| Bucket versioning | Disabled |
| Bucket design | Single bucket with path prefixes |
| Audit logs | Enabled — webhook to rotating local file |
| Restart policy | `condition: any` |
| Health check | `curl -f http://localhost:9000/minio/health/live` |
| Swarm replicas | `1` |

**Access credentials** must be sourced from Docker Swarm secrets:
- `minio_root_user` (Swarm secret name)
- `minio_root_password` (Swarm secret name)

Mounted inside the container at `/run/secrets/minio_root_user` and `/run/secrets/minio_root_password` respectively. Set `MINIO_ROOT_USER_FILE` and `MINIO_ROOT_PASSWORD_FILE` environment variables in the stack file to point to these paths.

**Default bucket to create on first deploy:** `init-bucket`

---

### 5.2 · Airflow Custom Docker Image

| Parameter | Value |
|-----------|-------|
| Base image | `apache/airflow:2.10.5-python3.12` |
| Additional packages | `pandas`, `polars`, `duckdb`, `minio` (MinIO Python client), `pyarrow` |
| Install method | `pip install --no-cache-dir` in a single `RUN` layer |
| User | Must remain `airflow` (do not switch to root in final image) |

**Dockerfile requirements:**
- Use `--constraint` flag pinned to Airflow's official constraints file for version `2.10.5` / Python `3.12`.
- Add a `LABEL` with `maintainer`, `version`, and `build-date`.
- Set:
    ENV AIRFLOW__CORE__TEST_CONNECTION=Enabled
    ENV AIRFLOW__WEBSERVER__DAG_ORIENTATION=TB
    ENV AIRFLOW__WEBSERVER__EXPOSE_STACKTRACE=True
    ENV AIRFLOW__WEBSERVER__EXPOSE_CONFIG=True
    ENV AIRFLOW__WEBSERVER__DEFAULT_WRAP=True

---

### 5.3 · Airflow Stack

#### 5.3.1 · Components

| Component | Role |
|-----------|------|
| `airflow-webserver` | UI + REST API |
| `airflow-scheduler` | DAG parsing + task scheduling |
| `airflow-worker` | Celery task execution (scalable via `docker service scale`) |
| `airflow-triggerer` | Deferred task handling |
| `postgres` | Airflow metadata database (direct connections, no pooler) |
| `redis` | Celery broker and result backend |

> **Note:** No Flower service and no PgBouncer. Celery result backend is Redis, not PostgreSQL. Direct PostgreSQL connections are used (no connection pooler).

#### 5.3.2 · Resource Reservations

All Airflow services use **soft reservations** via `deploy.resources.reservations`. No hard limits are applied.

| Container | CPU (reservation) | Memory (reservation) |
|-----------|-------------------|----------------------|
| `airflow-webserver` | `1.0` | `3g` |
| `airflow-scheduler` | `1.0` | `3g` |
| `airflow-worker` | `1.0` | `6g` |
| `airflow-triggerer` | `0.5` | `2g` |
| `postgres` | `1.0` | `4g` |
| `redis` | `0.5` | `512m` |

> **Note:** Swap is enabled on the host. Memory reservations are soft — containers may burst above reservation if host capacity allows.

#### 5.3.3 · Airflow Configuration

| Setting | Value |
|---------|-------|
| Executor | `CeleryExecutor` |
| Celery broker | Redis standalone (`redis://redis:6379/0`) |
| Celery result backend | Redis (`redis://redis:6379/1`) |
| Metadata DB | PostgreSQL (direct connection, no pooler) |
| DAG storage | Bind-mount: `/opt/data-plataform/airflow/dags` → `/opt/airflow/dags` |
| Log storage | Bind-mount: `/opt/data-plataform/airflow/logs` → `/opt/airflow/logs` |
| Plugins path | Bind-mount: `/opt/data-plataform/airflow/plugins` → `/opt/airflow/plugins` |
| XCom backend | Default (DB-backed) |
| Task log TTL | 90 days (enforced via `AIRFLOW__LOG__LOG_RETENTION_DAYS=90` — native Airflow 2.x log retention env var; no custom DAG required) |
| Scheduler heartbeat | Default 5 seconds |
| Audit logging | Default DB-backed |
| Worker concurrency | Tuned to available CPU count (`AIRFLOW__CELERY__WORKER_CONCURRENCY`) |
| Worker scaling | Via `docker service scale airflow_airflow-worker=N` |
| Restart policy | `condition: any` on all services |
| High availability | Single instance per component + `condition: any` restart |
| Fernet key | Sourced from Docker Swarm secret `airflow_fernet_key` |

#### 5.3.4 · Health Checks
Every Airflow container must define a Docker `HEALTHCHECK` directive in the stack file:
- **Webserver:** `curl -f http://localhost:8080/health`
- **Scheduler:** `airflow jobs check --job-type SchedulerJob --hostname "$${HOSTNAME}"`
- **Worker:** `celery --app airflow.providers.celery.executors.celery_executor.app inspect ping -d "celery@$${HOSTNAME}"`
- **Triggerer:** `airflow jobs check --job-type TriggererJob --hostname "$${HOSTNAME}"`

#### 5.3.5 · Airflow Connections (configured via `configure_airflow.sh`)
| Connection ID | Type | Target |
|---------------|------|--------|
| `minio_default` | `aws` (S3-compatible) | MinIO via Swarm DNS (`http://minio:9000`) — internal overlay; do **not** use the external host IP |
| `postgres_default` | `postgres` | Metadata DB via Swarm DNS (`postgres:5432`) |

#### 5.3.6 · Swarm Secrets for Airflow
| Swarm secret name | Purpose |
|-------------------|---------|
| `airflow_fernet_key` | Airflow Fernet encryption key |
| `airflow_secret_key` | Airflow webserver secret key |
| `airflow_db_password` | PostgreSQL password for Airflow user |
| `airflow_admin_password` | Initial admin user password |

Secrets are mounted at `/run/secrets/<name>` inside the container. Airflow must be configured to read these via `AIRFLOW__CORE__FERNET_KEY_FILE`, `AIRFLOW__WEBSERVER__SECRET_KEY_FILE`, and equivalent file-based env vars, or via an entrypoint init script that exports them as environment variables.

---

### 5.4 · PostgreSQL

| Parameter | Value |
|-----------|-------|
| Image | `postgres:16.6-alpine3.21` |
| CPU reservation | `1.0` cores |
| Memory reservation | `4g` |
| Data path (host) | `/opt/data-plataform/postgres/data` |
| Tuning profile | Default PostgreSQL config (no tuning) |
| Connection pooling | None — direct connections |
| max_connections | Default (100) |
| Backup | None (Day-1 scope); runbook must document manual `pg_dump` procedure |

PostgreSQL password must be sourced from the `airflow_db_password` Docker Swarm secret.

---

### 5.5 · Redis

| Parameter | Value |
|-----------|-------|
| Image | `redis:7.4.2-alpine3.21` |
| Mode | Standalone (no AOF persistence) |
| Data path (host) | `/opt/data-plataform/redis/data` |
| CPU reservation | `0.5` cores |
| Memory reservation | `512m` |

---

### 5.6 · Networking

| Parameter | Value |
|-----------|-------|
| Network model | Docker Swarm overlay (`data-platform-network`) |
| Network type | Overlay — plain (no VXLAN encryption) |
| Service discovery | Docker Swarm DNS (service names as hostnames) |
| MinIO API exposure | Host port binding `9000:9000` (direct) |
| MinIO Console exposure | Host port binding `9001:9001` (direct) |
| Airflow UI exposure | Host port binding `8080:8080` |
| Reverse proxy | None |
| TLS | None (internal network only) |
| Network segmentation | Single flat overlay for all services |
| Scale-out readiness | Overlay chosen specifically so new Swarm nodes join transparently — no network reconfiguration required |

The overlay network `data-platform-network` must be defined as **attachable** and declared external in individual stack files. It is created once by `stack.shared.yml` and shared across both stacks.

> **Design note — multi-node path:** On a single node, overlay adds negligible latency overhead (~0.2 ms). When additional nodes are joined (`docker swarm join`), all services on `data-platform-network` become reachable across hosts with zero stack-file changes. The runbook must document this join procedure.

---

## SECTION 6 — DECISION MATRIX (Resolved)

This matrix records all architectural decisions. Implement only the **selected** options. Do not implement non-selected options.

| Category | Decision | Selected Value |
|----------|----------|----------------|
| Container runtime | — | Docker + Swarm |
| Orchestration | — | Docker Swarm (single manager node) |
| Metadata DB engine | — | PostgreSQL 16 |
| DB deployment | — | Containerized (same host) |
| Connection pooling | — | None (direct connections) |
| DB tuning | — | Default PostgreSQL config |
| PostgreSQL max_connections | — | Default (100) |
| Executor | — | CeleryExecutor |
| Celery broker | — | Redis standalone |
| Celery result backend | — | Redis |
| Worker concurrency | — | Tuned to CPU count (prefork) |
| Worker autoscaling | — | Docker Swarm replica scaling (`docker service scale`) |
| MinIO deployment mode | — | Single-node Single-drive (SNSD) |
| Drive layout | — | Partition on OS disk |
| MinIO erasure coding | — | EC:2 (configured, SNMD future path) |
| Bucket versioning | — | Disabled |
| Bucket design | — | Single bucket + path prefixes |
| Network model | — | Docker Swarm overlay |
| Overlay encryption | — | Plain overlay (no encryption) |
| Service discovery | — | Docker Swarm DNS (service names) |
| MinIO endpoint exposure | — | Direct host port binding (`9000`, `9001`) |
| Reverse proxy | — | None |
| MinIO access control | — | Root credentials only |
| Secrets management | — | Docker Swarm secrets |
| Fernet key management | — | Static env var from Swarm secret |
| TLS | — | None (internal only) |
| Encryption at rest | — | None |
| Network firewall | — | None |
| Network segmentation | — | Single flat overlay |
| DAG storage | — | Shared bind-mount volume |
| Log storage | — | Local filesystem bind mount |
| XCom backend | — | Default DB-backed |
| Resource enforcement | — | Soft reservations (`resources.reservations`) |
| Memory enforcement | — | Soft limit + swap enabled |
| Swap | — | Swap enabled on host |
| CPU pinning | — | No pinning (Linux CFS scheduler) |
| OOM behavior | — | Default OOM killer |
| I/O isolation | — | None |
| Task-level resource tagging | — | Single default pool |
| DAG concurrency | — | Global `AIRFLOW__CORE__PARALLELISM` limit |
| Airflow scheduler redundancy | — | Single scheduler |
| Airflow webserver HA | — | Single replica + restart policy |
| MinIO HA | — | SNSD + restart policy |
| PostgreSQL HA | — | Single + restart policy |
| Redis HA | — | Single Redis |
| Service dependency ordering | — | Restart-on-failure as dependency proxy |
| Restart policy | — | `condition: any` |
| Swarm manager quorum | — | Single manager |
| Metrics collection | — | None |
| Airflow metrics export | — | None |
| MinIO metrics | — | None |
| Docker/Swarm metrics | — | None |
| Health check endpoints | — | Docker `HEALTHCHECK` directives |
| Log aggregation | — | None |
| Container log driver | — | `json-file` default |
| MinIO log verbosity | — | AUDIT enabled |
| Airflow log retention | — | Native Airflow `AIRFLOW__LOG__LOG_RETENTION_DAYS` env var (Airflow 2.x) |
| Airflow task log TTL | — | 90 days |
| Log disk pressure protection | — | Docker log rotation (`max-size`/`max-file`) |
| Alerting | — | None |
| Airflow DB backup | — | None (runbook only) |
| MinIO data backup | — | None |
| PostgreSQL backup | — | None (runbook only) |
| Config backup | — | None |
| RTO strategy | — | Idempotent `docker stack deploy` from known state |
| DAG deployment method | — | Manual bind-mount copy |
| DAG versioning | — | None |
| DAG testing | — | None |
| Airflow upgrade strategy | — | None (documented in runbook) |
| MinIO upgrade strategy | — | None (documented in runbook) |
| PostgreSQL upgrade strategy | — | None (documented in runbook) |
| Configuration management | — | `.env` files for non-secret config |
| Airflow secret backend | — | Docker Swarm secrets |
| Image security | — | Official images only |
| Dependency update management | — | None |
| Change management | — | Direct stack redeploy |
| Flower (Celery monitor) | — | Not deployed |
| PgBouncer | — | Not deployed |
| Scale-out network strategy | — | Overlay from day one (zero reconfiguration to add nodes) |
| Worker scale-out mechanism | — | `docker service scale airflow_airflow-worker=N` (day one) → shared storage migration (documented, not implemented) |
| MinIO scale-out path | — | SNSD now, migrate to MNMD via `mc mirror` when additional drives available (documented in runbook) |
| Airflow executor scale-out path | — | CeleryExecutor from day one; worker replicas scale horizontally |
| Config portability | — | `.env` files per environment; no node-specific config in stack files |

---

## SECTION 7 — SKILLS

The following skills define **how** the LLM must approach generation tasks. Apply each skill deterministically.

### SKILL — Shell Script Authoring
- **Shebang:** Always `#!/usr/bin/env bash`.
- **Strict mode:** Every script must begin with `set -euo pipefail`.
- **Idempotency:** Scripts must be safely re-runnable; use existence checks before creating resources (e.g., `docker secret ls` before `docker secret create`, `docker network ls` before `docker network create`).
- **Logging:** Use a `log_info`, `log_warn`, and `log_error` helper function at the top of every script.
- **Exit codes:** Non-zero exit codes must be used on failure; critical failures must print a descriptive message before exiting.
- **Variable quoting:** All variable expansions must be double-quoted (`"$variable"`).
- **No global side effects:** Scripts must not modify system-level configurations outside the `/opt/data-plataform` tree and Docker/Swarm resources.
- **Swarm init check:** Scripts that call `docker stack deploy` must verify the node is a Swarm manager (`docker info --format '{{.Swarm.LocalNodeState}}'`) and exit with a clear message if not.

### SKILL — Teardown Script Authoring (`scripts/teardown.sh`)
This script is the authoritative destroy utility for the entire solution. Apply all Shell Script Authoring rules above, plus:
- **Ordered removal:** Teardown must proceed in reverse-dependency order:
  1. Remove Swarm stacks (`docker stack rm airflow minio`), then wait until all tasks are stopped before proceeding.
  2. Remove each Docker Swarm secret (`docker secret rm <name>`), skipping any that no longer exist.
  3. Remove the overlay network (`docker network rm data-platform-network`), skipping if already absent.
  4. Remove any named Docker volumes created by the stacks, skipping if absent.
  5. *(Optional — gated behind a `--purge-data` flag)* Delete host data directories under `/opt/data-plataform` using `rm -rf`. This step must require explicit confirmation from the operator before executing and must print a prominent warning listing every path that will be deleted.
- **Wait for stack removal:** After `docker stack rm`, poll `docker stack ls` in a loop (max 60 s, 5 s interval) until the stacks are no longer listed before moving to the next step.
- **Idempotency:** Every removal command must check for existence first and emit a `log_warn "<resource> not found, skipping"` message rather than failing.
- **Dry-run mode:** Support a `--dry-run` flag that prints every action that would be taken without executing any destructive command.
- **Summary output:** At the end, print a table listing each removed resource and its final status (removed / skipped / failed).

### SKILL — Docker Swarm Stack Authoring
- **Format:** Use schema-less stack YAML (Compose v3.9 compatible, deployed via `docker stack deploy`).
- **Resource limits:** Always specify `deploy.resources.reservations` for memory and CPU. Do **not** use hard `limits` unless explicitly required.
- **Restart policy:** All services must have `deploy.restart_policy.condition: any` unless explicitly stated otherwise.
- **Health checks:** Required on every service via `healthcheck:` key in the stack file.
- **Environment sourcing:** Non-secret environment variables must reference `${VAR_NAME}` sourced from `.env` via `env_file:`. Secrets must be referenced via the `secrets:` key.
- **Volume semantics:** Use host bind mounts for data that must survive container recreation.
- **Network:** All services must be attached to the `data-platform-network` attachable overlay network.
- **Secrets:** Declare all secrets at the top-level `secrets:` section as `external: true`. Create secrets before deploying the stack.
- **Replicas:** Explicitly set `deploy.replicas` for every service.
- **Update config:** Set `deploy.update_config.parallelism: 1` and `order: start-first` where safe.

### SKILL — Python Script Authoring
- **Style:** PEP 8 compliant.
- **Type hints:** Required on all function signatures.
- **Docstrings:** Google-style docstrings on all public functions and classes.
- **Error handling:** Use explicit `try/except` blocks; avoid bare `except`.
- **Logging:** Use the standard `logging` module; never use `print` for operational output.

### SKILL — DAG Authoring (Apache Airflow)
- **DAG definition:** Use the `@dag` decorator pattern (TaskFlow API preferred where applicable).
- **Default args:** Must include `owner`, `retries`, `retry_delay`, `email_on_failure`, `email_on_retry`.
- **Schedule:** Use cron expressions or `@daily` / `@weekly` presets — never `timedelta` for schedule intervals.
- **Catchup:** Set `catchup=False` unless backfill is explicitly required.
- **Tags:** Every DAG must include at least one tag (e.g., `["maintenance"]`).
- **Idempotency:** Tasks must be idempotent; they must be safe to re-run on the same logical date.

### SKILL — Documentation Authoring
- **Format:** GitHub-Flavored Markdown.
- **Structure:** Every document must have a title (`# H1`), a brief description, and a table of contents.
- **Commands:** All shell commands must be wrapped in fenced code blocks with the `bash` language tag.
- **Prerequisites section:** Every runbook/guide must list required tools and minimum versions.
- **Step numbering:** Use ordered lists; every step must be atomic (one action per step).

### SKILL — Test Authoring
- **Shell tests:** Use `bash` functions prefixed with `test_`; use `assert_equal` and `assert_contains` helper functions defined at the top of the test file. Report PASS/FAIL per test. Exit non-zero if any test fails.
- **Python tests:** Use `pytest`. Every test file must import `pytest` and define fixtures in a `conftest.py` if shared. DAG integrity tests must assert zero import errors and validate that DAG IDs match expected names.

---

## SECTION 8 — CONSTRAINTS & BOUNDARIES

| Constraint | Specification |
|------------|---------------|
| Operating system | Linux (Debian/Ubuntu-based) |
| Docker Engine | >= 24.0 |
| Docker CLI | Swarm mode enabled (`docker swarm init` before deployment) |
| Python | 3.12 |
| Airflow version | 2.10.5 |
| PostgreSQL version | 16 |
| Redis version | 7 |
| Host data root | `/opt/data-plataform` — must be created before running scripts |
| Secrets | Docker Swarm secrets — must be created before `docker stack deploy` |
| Out of scope | TLS termination, external identity providers, cloud storage backends, active multi-node deployment (documentation of the scale-out path is in scope — see §2.7), PgBouncer, Flower, reverse proxy |

---

## SECTION 9 — RESOLVED CONFIGURATION

All pre-generation questions have been answered by the operator. Apply these answers directly — do not ask again.

| # | Question | Resolved Answer | Implementation instruction |
|---|----------|-----------------|----------------------------|
| 1 | **Server hostname / IP** | Use the server's static IP address | Insert a `# TODO(user): replace with your server's static IP` comment in `.env.example` for the `HOST_IP` variable. Reference this variable only in documentation and external-client examples (e.g., `mc alias set`). All internal service-to-service connections must use Swarm DNS names, never the host IP. |
| 2 | **Airflow admin credentials** | Generate temporary credentials; store as Swarm secrets. First write to `.env` (non-committed), then create secrets from it. | In `deploy_airflow.sh`: read `AIRFLOW_ADMIN_USER` and `AIRFLOW_ADMIN_PASSWORD` from the local `.env` file, then create the corresponding Swarm secrets (`airflow_admin_user`, `airflow_admin_password`) idempotently. Document this step in `docs/deployment_guide.md`. |
| 3 | **SMTP / email alerting** | None | Do not configure any SMTP settings. Set `AIRFLOW__EMAIL__EMAIL_BACKEND=airflow.utils.email.send_email_smtp` but leave the SMTP host/port variables unset (or set to empty strings) so Airflow starts without error. Add a `# TODO(user): configure SMTP to enable email alerts` comment. |
| 4 | **Swarm advertise interface** | Use Docker's default auto-detection | Pass no `--advertise-addr` flag when running `docker swarm init`. Add a `# TODO(user): if the node has multiple network interfaces, run: docker swarm init --advertise-addr <INTERFACE>` comment in `deploy_airflow.sh` and `deploy_minio.sh`. |