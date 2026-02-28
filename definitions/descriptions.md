# Production Architecture: Airflow & MinIO Decision Matrix

> **On-Premise & Docker Swarm — Detailed Decision Points**


---

## Storage Backend & Drivers

### Docker volume driver for MinIO data

  - **Local bind mount (`/mnt/data:/data`)**
    - **Pros**: Maximum I/O throughput, zero driver overhead, easiest path to direct disk tuning (noatime, ext4 tune2fs)
    - **Cons**: Tied to host path, no portability between nodes, manual dir permissions, invisible to `docker volume ls`

  - **Named Docker volume (`docker volume create`)**
    - **Pros**: Managed by Docker daemon, shows in `docker volume ls/inspect`, slightly more portable
    - **Cons**: Still single-host, harder to migrate data without explicit copy, stored under `/var/lib/docker/volumes` mixing with other app data

  - **NFS-backed volume (Docker NFS volume plugin)**
    - **Pros**: Shared across future Swarm nodes, enables MinIO MNMD over NFS, zero code change on scale-out
    - **Cons**: NFS server is a new SPOF, adds network I/O latency (~0.5–2ms vs <0.1ms local), NFS locking issues under high concurrency

  - **GlusterFS / Ceph plugin**
    - **Pros**: True distributed block/object storage, replication built-in, survives node loss
    - **Cons**: Requires 3+ nodes minimum for quorum, 1–2 GB RAM overhead per node for daemons, overkill and operationally expensive on a single server

### MinIO deployment mode

  - **Single-node single-drive (SNSD)**
    - **Pros**: Zero configuration, fastest startup, lowest resource overhead (~50MB RAM idle), works on any single disk
    - **Cons**: No erasure coding, no self-healing, any bit-rot or disk error causes silent data corruption, not upgradeable to erasure-coded mode without full data migration

  - **Single-node multi-drive (SNMD, e.g., 4 drives minimum)**
    - **Pros**: Erasure coding enabled (EC:2+), survives drive failure, self-healing background scan, readable even while degraded
    - **Cons**: Requires at minimum 4 separate mount points or 4 separate physical/virtual drives, capacity reduced by parity overhead

  - **Multi-node multi-drive (MNMD)**
    - **Pros**: Full production HA, survives node failure, horizontal scale-out by adding nodes, consistent hashing for object placement
    - **Cons**: Requires multiple physical hosts right now, complex initial setup, not feasible as day-one single-server deployment

### MinIO erasure coding parity (EC level)

  - **EC:0 (no parity)**
    - **Pros**: 100% of raw disk usable, maximum write throughput
    - **Cons**: Zero redundancy — any single drive failure causes complete data loss, not acceptable for production data

  - **EC:2 (default recommendation)**
    - **Pros**: Survives 2 simultaneous drive failures, balanced capacity vs durability, MinIO default for 4-drive SNMD
    - **Cons**: Loses 2-drives-worth of usable capacity from total pool

  - **EC:4**
    - **Pros**: Extremely high durability, survives 4 simultaneous drive failures
    - **Cons**: Requires minimum 8 drives for EC:4 to function, significant capacity loss (50% overhead), diminishing returns for most workloads

### Airflow metadata DB storage backend

  - **Local bind mount (`/mnt/postgres:/var/lib/postgresql/data`)**
    - **Pros**: Best possible I/O latency, no abstraction layer, supports direct filesystem tuning (ext4, XFS with `noatime`)
    - **Cons**: Host path hardcoded, not portable between nodes, accidental host directory deletion destroys DB

  - **Named Docker volume**
    - **Pros**: Docker-managed lifecycle, volume backup via `docker run --volumes-from`, visible in Docker CLI
    - **Cons**: Still single-host, path lives inside `/var/lib/docker` which may be on the OS disk, no I/O isolation from other volumes

  - **Dedicated physical disk or partition mounted to DB path**
    - **Pros**: Complete I/O isolation — MinIO heavy writes cannot starve the Airflow DB, predictable IOPS, better for WAL-heavy write patterns
    - **Cons**: Requires hardware planning upfront, more host-level setup (fstab, mkfs, mount)

### Log storage backend

  - **Local filesystem (bind mount to `/opt/airflow/logs`)**
    - **Pros**: Zero latency log writes, no external dependency, works immediately out of the box
    - **Cons**: Logs not accessible to other workers in multi-node, fills disk silently without rotation policy, not centralized across services

  - **Remote logging to MinIO (S3-compatible, via `airflow.cfg` `[logging] remote_log_conn_id`)**
    - **Pros**: Logs survive container restarts, browsable from Airflow UI (pre-signed URLs), shared across scheduler and all workers, leverages existing MinIO infrastructure
    - **Cons**: Requires Airflow S3 connection config, log writes now network I/O, MinIO downtime blocks log retrieval (reads), small latency added per task log flush

  - **Remote logging to Elasticsearch**
    - **Pros**: Full-text search across all task logs, Kibana dashboards, pattern-based alerting on error keywords
    - **Cons**: Elasticsearch minimum viable deployment requires ~2GB RAM, significant CPU for indexing, heavy operational burden on already-constrained hardware

### DAG storage backend

  - **Git-sync sidecar container (e.g., `k8s-sidecar` or `git-sync`)**
    - **Pros**: True GitOps — every DAG deploy is a Git commit, automatic sync interval (e.g., 60s), rollback = `git revert`, works with private repos via SSH key
    - **Cons**: Extra sidecar container consuming RAM (~50MB), sidecar must share volume with scheduler and all workers, SSH key or token must be managed as a secret

  - **Shared NFS/bind mount with manual copy**
    - **Pros**: Simplest possible approach — just copy `.py` files to a directory
    - **Cons**: No version control integration, no audit trail, human error risk (wrong file deployed), stale DAGs linger unless manually deleted

  - **MinIO bucket + sync cron (`mc mirror` on a schedule)**
    - **Pros**: Reuses existing MinIO, DAGs stored as objects with versioning possible, no extra services beyond what already exists
    - **Cons**: Sync is periodic (eventual consistency), short lag between upload and DAG appearing in scheduler, `mc` cron is an additional scheduled process to manage


---

## Database Selection & Tuning

### Airflow metadata DB engine

  - **PostgreSQL**
    - **Pros**: Officially recommended by Apache Airflow for production, full SQL feature set, supports dual-scheduler HA mode (SELECT FOR UPDATE SKIP LOCKED), active community, strong JSONB support for XCom
    - **Cons**: Heavier than SQLite (~30–50MB RAM idle), requires explicit connection pooling under load

  - **MySQL / MariaDB**
    - **Pros**: Widely known by ops teams, reasonable performance for Airflow workloads
    - **Cons**: Airflow has historically had MySQL-specific bugs (timezone `DATETIME` vs `TIMESTAMP`, `explicit_defaults_for_timestamp` required), `utf8mb4` charset must be explicitly configured, some Airflow features may lag MySQL support

  - **SQLite**
    - **Pros**: Zero setup, no separate process
    - **Cons**: Explicitly documented as unsupported for production by Apache Airflow, no concurrent write support, scheduler deadlocks under parallelism, never use beyond local development

### PostgreSQL deployment mode

  - **Containerized Docker Swarm service**
    - **Pros**: Consistent lifecycle with rest of stack, version-controlled in stack YAML, easy to upgrade by changing image tag
    - **Cons**: Storage volume management is critical — container removal without volume preservation = data loss, container overhead adds ~5–10% I/O latency vs bare metal

  - **Host-installed (bare metal, `apt install postgresql`)**
    - **Pros**: Maximum I/O performance, OS-level tuning via `sysctl`, managed by systemd for reliability, completely independent of Docker failures
    - **Cons**: Outside Docker lifecycle, version managed separately, adds OS-level dependency, harder to include in stack-based deployment automation

  - **Containerized with pgBouncer sidecar in same Swarm service**
    - **Pros**: Connection pooling co-located with DB, reduces DB `max_connections` requirement dramatically, transparent to Airflow (same connection string)
    - **Cons**: Additional container, pgBouncer config file must be mounted, `PREPARE` and `SET` statements require session mode (less efficient)

### PostgreSQL connection pooling

  - **PgBouncer in transaction mode**
    - **Pros**: Most efficient — connections returned to pool between SQL statements, supports hundreds of Airflow workers with a small DB `max_connections` (e.g., 20 pool → 200 workers)
    - **Cons**: Incompatible with `PREPARE`/`DEALLOCATE`, `SET LOCAL`, `LISTEN/NOTIFY` — Airflow's SQLAlchemy must use `pool_pre_ping=True` and avoid prepared statements

  - **PgBouncer in session mode**
    - **Pros**: Full SQL feature compatibility, simpler to reason about, no prepared statement restrictions
    - **Cons**: Much less efficient pooling — one pool connection per app connection for entire session duration, minimal benefit over no pooling for connection spike scenarios

  - **No connection pooling (direct connections)**
    - **Pros**: Zero extra configuration, no additional hop in query path
    - **Cons**: Each Airflow worker thread opens a dedicated DB connection; with 8 workers × 4 threads = 32 connections minimum, spikes during task scheduling can easily hit `max_connections` and cause `FATAL: too many connections` errors

### PostgreSQL HA strategy

  - **Single primary, no replica**
    - **Pros**: Zero operational overhead, simple backup story, fits single-server constraint
    - **Cons**: DB crash = full Airflow downtime; Docker Swarm restart adds ~15–30s delay; no failover possible

  - **Primary + streaming replica with Patroni**
    - **Pros**: Automatic failover on primary failure (~30s), read replicas offload reporting queries, Patroni exposes REST API for health status
    - **Cons**: Patroni requires etcd or Consul for distributed lock (another service), both primary and replica on same physical server means hardware failure kills both, significant operational complexity

  - **Primary + WAL-G continuous archiving to MinIO**
    - **Pros**: Point-in-time recovery (PITR) to any second in history, archives go to MinIO (reuses existing infrastructure), low overhead on primary (~2–5% I/O for WAL shipping)
    - **Cons**: No automatic failover — recovery requires manual `WAL-G restore` + Airflow restart, recovery time depends on WAL volume (RPO near-zero, RTO 15–60 min)

### PostgreSQL `max_connections` tuning

  - **Default (100)**
    - **Pros**: Safe baseline, prevents connection exhaustion by default
    - **Cons**: With pgBouncer-less setup and many Airflow workers, easily exhausted during scheduler bursts, causes hard failures

  - **Tuned to `(worker_count × threads_per_worker) + 20 overhead`**
    - **Pros**: Right-sized for actual workload, avoids over-allocation of shared memory (each connection costs ~5–10MB RAM)
    - **Cons**: Requires capacity planning, must be recalculated if worker count changes

  - **Dynamic via pgBouncer pool_size**
    - **Pros**: DB sees only `pool_size` connections regardless of how many Airflow workers exist, effectively decouples app scale from DB connection limit
    - **Cons**: Requires pgBouncer to be correctly sized (`pool_size` × `max_db_connections` must stay under DB `max_connections`)

### PostgreSQL `shared_buffers` tuning

  - **Default (128MB)**
    - **Pros**: Safe, conservative, leaves RAM for OS page cache
    - **Cons**: Severely under-utilizes available RAM on a 32GB server, results in excessive disk I/O for frequently accessed catalog data

  - **25% of allocated DB RAM (e.g., 1GB if DB gets 4GB)**
    - **Pros**: PostgreSQL official recommendation, well-tested sweet spot, leaves 75% for OS cache which also benefits PG reads
    - **Cons**: May still be conservative for write-heavy Airflow workloads with large XCom data

  - **50%+ of allocated DB RAM**
    - **Pros**: Maximizes buffer cache hits, reduces disk I/O significantly for large metadata tables
    - **Cons**: Leaves less for OS page cache (which PG also uses), may cause OS-level memory pressure if other processes spike

### Airflow result backend (CeleryExecutor)

  - **Redis**
    - **Pros**: Sub-millisecond task state reads/writes, purpose-built for ephemeral state, minimal RAM (~30MB idle), `EXPIRE` TTL on results auto-cleans stale state
    - **Cons**: Additional service to deploy, monitor and back up; data lost on Redis restart without AOF/RDB persistence

  - **PostgreSQL (same Airflow metadata DB instance)**
    - **Pros**: No extra service — result backend reuses existing DB, simplifies architecture
    - **Cons**: Adds load to already-critical metadata DB, task result polling creates high-frequency short queries that can spike connection count, slower than Redis

  - **RabbitMQ**
    - **Pros**: Persistent queues survive restarts by default, rich routing (exchanges, bindings), supports task priority queues natively
    - **Cons**: Highest RAM/CPU of all broker options (~100–200MB RAM idle), management UI adds another exposed port, operational complexity far exceeds benefit for a single-node deployment


---

## Executor Type & Worker Pools

### Airflow executor selection

  - **LocalExecutor**
    - **Pros**: No broker, no result backend, no extra services — scheduler spawns subprocesses directly, ideal for single-node with limited resources, supports parallelism via `max_parallelism` config
    - **Cons**: Workers run in same container as scheduler (no isolation), cannot scale workers to other nodes, scheduler process is a bottleneck for very high task throughput

  - **CeleryExecutor**
    - **Pros**: Workers are independent Swarm services — can be scaled (`docker service scale airflow_worker=N`), tasks isolated from scheduler crash, supports multiple worker queues for task routing
    - **Cons**: Requires broker (Redis/RabbitMQ) + result backend, minimum 3 extra services (broker, result backend, flower optionally), ~200–400MB additional RAM overhead

  - **KubernetesExecutor**
    - **Pros**: Pod-per-task isolation — each task gets its own container with dedicated resources, no persistent workers wasting RAM between tasks
    - **Cons**: Requires Kubernetes — completely incompatible with Docker Swarm, requires K8s API access from Airflow scheduler, significant infrastructure prerequisite

  - **CeleryKubernetesExecutor**
    - **Pros**: Route some tasks to Celery workers (fast, warm) and others to K8s pods (isolated, resource-intensive)
    - **Cons**: Requires both Celery infrastructure AND Kubernetes simultaneously, maximum complexity, not applicable to Docker Swarm environment

  - **LocalExecutor with high `parallelism` (recommended for this scenario)**
    - **Pros**: Best resource efficiency for single-node 4 CPU / 16GB Airflow budget, zero broker overhead, scheduler + workers share context
    - **Cons**: Must migrate to CeleryExecutor when scaling to multi-node, no cross-host task distribution, all task logs local to single container

### Celery broker selection

  - **Redis (with default RDB persistence)**
    - **Pros**: Lightweight (~30MB RAM), extremely fast pub/sub, simple config (single env var for `CELERY_BROKER_URL`), built-in key expiry for dead task cleanup
    - **Cons**: Message queue lost on crash if only RDB (periodic snapshot) — tasks in-flight between snapshots are lost

  - **RabbitMQ**
    - **Pros**: Persistent queues by default (messages written to disk), native dead-letter queues for failed task routing, management HTTP API with browser UI
    - **Cons**: ~100–200MB RAM overhead, requires AMQP protocol knowledge for debugging, vhost/user configuration overhead

  - **Redis with AOF persistence (append-only file)**
    - **Pros**: Near-durability of RabbitMQ at Redis performance — every write fsynced to disk, recoverable queue on crash, familiar Redis tooling
    - **Cons**: ~10–15% write latency increase vs default Redis, AOF file can grow large and requires periodic rewrite (`BGREWRITEAOF`)

### Celery worker concurrency model

  - **Prefork (default, multiprocessing)**
    - **Pros**: True process isolation — one hung task cannot block others, independent memory space per task, battle-tested for CPU-bound and mixed workloads
    - **Cons**: Each worker process has full Python memory footprint (~150–300MB RAM per process), higher RAM consumption than thread-based models

  - **Gevent (cooperative coroutines)**
    - **Pros**: Handles hundreds of concurrent I/O-bound tasks (HTTP calls, MinIO reads) with minimal RAM — one process, many coroutines
    - **Cons**: CPU-bound tasks block the event loop and starve other coroutines, monkey-patching can break non-gevent-aware libraries

  - **Eventlet**
    - **Pros**: Similar I/O concurrency benefits to gevent
    - **Cons**: Smaller community than gevent, fewer maintained integrations, less reliable with complex DAG dependencies, same CPU-bound blocking issue as gevent

### Worker autoscaling

  - **`--autoscale min,max` (Celery autoscale)**
    - **Pros**: Worker spawns/reaps child processes based on queue depth, no external trigger needed, responds within seconds
    - **Cons**: Max process count must stay within CPU/RAM limits (risk of OOM if max set too high), unpredictable resource usage makes capacity planning harder

  - **Fixed concurrency (`--concurrency N`)**
    - **Pros**: Completely predictable resource envelope — N processes × known RAM per process = known total, easy to align with Docker resource limits
    - **Cons**: May waste allocated CPUs when queue is empty, may queue tasks unnecessarily when queue spikes

  - **Docker Swarm service replicas scaling (`docker service scale`)**
    - **Pros**: Whole worker containers scale in/out — each with fixed concurrency, clean resource model, can be triggered by external metrics (Prometheus → custom scaler)
    - **Cons**: Scale-out has ~10–30s startup delay (container pull + Python startup), not reactive enough for short burst workloads, manual trigger unless external autoscaler is built

### Task-level resource tagging (Airflow Pools)

  - **Airflow Pools per resource type (e.g., `minio_pool`, `db_pool`)**
    - **Pros**: Prevents any single resource (MinIO, external DB) from being overwhelmed by too many simultaneous tasks, pool slots visible in Airflow UI, adjustable at runtime without code changes
    - **Cons**: Every DAG task accessing a shared resource must explicitly declare `pool=`, easy to forget and bypass the limit

  - **Single default pool (`default_pool`)**
    - **Pros**: Zero DAG annotation required, works out of the box
    - **Cons**: All tasks compete for same pool regardless of which resource they use — 10 MinIO-heavy tasks + 10 CPU tasks all treated equally, no per-resource throttling

  - **Pool per external system + per pipeline priority pool**
    - **Pros**: Maximum control — throttle MinIO at 5 concurrent tasks, DB at 3, CPU at 8, plus priority pools ensuring SLA DAGs always get slots first
    - **Cons**: High configuration overhead, requires discipline across all DAG authors, pool exhaustion debugging is non-trivial

### DAG concurrency limits

  - **Global `AIRFLOW__CORE__PARALLELISM`**
    - **Pros**: Hard ceiling on total simultaneous task instances across all DAGs — protects system from overcommit
    - **Cons**: A single large DAG can consume all slots and starve other DAGs

  - **Per-DAG `max_active_tasks` in DAG definition**
    - **Pros**: Each DAG has its own ceiling, prevents one DAG monopolizing global parallelism
    - **Cons**: Must be set in every DAG file — new DAGs without this setting have no cap, code review discipline required

  - **No concurrency limit**
    - **Pros**: Maximum possible throughput, no artificial throttling
    - **Cons**: Burst of tasks can exhaust CPU/RAM, trigger OOM killer, crash workers — cascading failure risk

### Airflow scheduler redundancy

  - **Single scheduler**
    - **Pros**: Simple, low resource usage (~500MB RAM for scheduler process), default configuration
    - **Cons**: Scheduler crash = no new task instances scheduled until Swarm restarts it (~15–30s gap), running tasks continue to completion but nothing new launches

  - **Dual schedulers (Airflow 2.x HA mode)**
    - **Pros**: Two scheduler processes race to schedule tasks (leader election via DB row locking), one crash has zero visible impact, scheduling continues uninterrupted
    - **Cons**: Requires PostgreSQL (not MySQL/SQLite) for `SELECT FOR UPDATE SKIP LOCKED`, ~doubled scheduler RAM consumption, slightly higher DB CPU from concurrent scheduler queries


---

## Networking & Service Discovery

### Docker Swarm network type

  - **Overlay network (recommended)**
    - **Pros**: Multi-host native — zero reconfiguration when adding Swarm nodes, all services on same logical network regardless of which host they run on, built-in VIP load balancing
    - **Cons**: ~0.2–0.5ms added latency per hop vs bridge, VXLAN encapsulation adds ~50-byte overhead per packet, requires kernel `ip_vs` module loaded

  - **Bridge network**
    - **Pros**: Lower latency than overlay (~0.05ms), simpler networking model for single-host, no VXLAN overhead
    - **Cons**: Not portable — services only reachable within same Docker host, must manually reconfigure if scaling to multi-node Swarm

  - **Host network**
    - **Pros**: Zero network overhead — container uses host's NIC directly, maximum bandwidth and minimum latency
    - **Cons**: No network isolation between containers, port conflicts between services become real, completely non-portable to multi-node, breaks Swarm service VIP load balancing

### Service discovery method

  - **Docker Swarm internal DNS (`http://minio:9000`, `postgresql:5432`)**
    - **Pros**: Zero configuration — Swarm automatically registers every service by name in embedded DNS, works immediately, no extra services
    - **Cons**: Only resolves within the same overlay network, no health-aware routing (unhealthy service still gets DNS responses until Swarm marks it stopped)

  - **Consul service discovery**
    - **Pros**: Health-check-aware DNS — only routes to healthy instances, supports multi-DC, rich KV store for config, works across Docker and bare metal
    - **Cons**: Requires dedicated Consul cluster (3 nodes for quorum) or single-node Consul (new SPOF), adds ~50–100MB RAM, significant operational complexity

  - **Traefik service mesh with labels**
    - **Pros**: Dynamic auto-discovery via Docker label annotations, no DNS config needed, service-to-service routing with retries and circuit breakers
    - **Cons**: All service mesh traffic routes through Traefik (central bottleneck), latency added per internal call, complex label-based configuration

### Reverse proxy / ingress

  - **Traefik (Docker Swarm provider)**
    - **Pros**: Reads Docker service labels dynamically — no manual config file updates when adding services, automatic Let's Encrypt TLS renewal, dashboard for routing visibility, native Swarm-aware
    - **Cons**: Extra container (~50MB RAM), requires understanding label-based configuration, routing bugs require Traefik log debugging

  - **Nginx**
    - **Pros**: Extremely battle-tested, vast documentation, predictable behavior under load, familiar to most ops teams, high-performance static file serving for Airflow static assets
    - **Cons**: Config file (`nginx.conf`) requires manual update for every new service or route, no automatic service discovery, `nginx -s reload` required after changes

  - **Caddy**
    - **Pros**: Automatic HTTPS via Let's Encrypt with zero configuration (just specify domain), human-readable Caddyfile syntax, HTTP/2 and HTTP/3 support out of the box
    - **Cons**: Less commonly used in enterprise on-prem deployments, fewer battle-tested patterns for complex upstream routing, smaller ecosystem of Swarm-specific examples

  - **No reverse proxy (direct port binding)**
    - **Pros**: Absolutely simplest — just expose port 8080 for Airflow, 9001 for MinIO console
    - **Cons**: No TLS termination (traffic in plaintext), no centralized auth/rate limiting, port numbers exposed to users, no path-based routing possible

### MinIO endpoint exposure

  - **Internal overlay only (Airflow → MinIO on overlay network, no external port)**
    - **Pros**: Most secure — MinIO API accessible only to services on same overlay network, no external attack surface, no firewall rule required
    - **Cons**: External tools (local `mc` CLI, developer S3 browsers, data ingestion from outside) cannot reach MinIO without VPN or jump host

  - **Exposed via reverse proxy with TLS termination**
    - **Pros**: External clients can access MinIO via HTTPS with valid cert, proxy can add auth layer or rate limiting, single ingress point
    - **Cons**: Reverse proxy becomes SPOF for external access, proxy config must correctly forward `Host` header for MinIO virtual-hosted bucket style

  - **Direct host port binding (`-p 9000:9000`)**
    - **Pros**: Simple — any client can `mc alias set` directly to `http://host-ip:9000`
    - **Cons**: No TLS without extra config, port directly exposed to network, no access logging at proxy layer

### Airflow Webserver exposure

  - **Behind reverse proxy with TLS (HTTPS on port 443)**
    - **Pros**: Encrypted access, valid certificate removes browser warnings, proxy can enforce HTTPS redirect, rate limiting on login endpoint
    - **Cons**: Reverse proxy setup required, certificate management overhead

  - **Direct port binding (e.g., `http://host:8080`)**
    - **Pros**: Zero proxy config — works immediately after stack deploy
    - **Cons**: Plaintext HTTP, credentials transmitted unencrypted, unacceptable for production with any real users

  - **VPN-only access (no external port, requires WireGuard/OpenVPN)**
    - **Pros**: Maximum security — Airflow UI unreachable without VPN authentication, no port exposed to internet
    - **Cons**: VPN infrastructure required, all users need VPN client, harder for external integrations (CI/CD webhooks)

### Inter-service communication encryption

  - **Docker overlay with `--opt encrypted=true`**
    - **Pros**: AES-128 GCM encryption for all VXLAN traffic between containers, transparent to applications, one-line configuration in `docker network create`
    - **Cons**: ~10% CPU overhead on encryption/decryption, particularly noticeable for MinIO high-throughput data transfers, encryption is node-to-node (not end-to-end at TLS layer)

  - **Plain overlay (no encryption)**
    - **Pros**: Zero CPU overhead, maximum network throughput
    - **Cons**: Traffic between containers on same host is unencrypted on the VXLAN, if multiple physical hosts added later, inter-host traffic travels in plaintext on the LAN

  - **TLS at application layer (MinIO TLS + Airflow connection TLS)**
    - **Pros**: True end-to-end encryption independent of network layer, mutual TLS possible for service identity verification, certificates provide an audit trail
    - **Cons**: Certificate management for internal services (rotation, distribution, trust chain), slight CPU overhead for TLS handshakes, `airflow.cfg` and connection strings must reference `https://` not `http://`

### Port conflict management

  - **Manual port namespace (each service gets unique port, documented)**
    - **Pros**: Simple, human-readable — no extra tooling
    - **Cons**: Requires documentation discipline, human error risk when adding new services, port collision only discovered at deploy time

  - **Traefik/Nginx hostname-based routing (all on port 80/443)**
    - **Pros**: No port conflicts possible — routing by `Host:` header means infinite services on same ports, clean URLs
    - **Cons**: Requires DNS or `/etc/hosts` entries for each service hostname, reverse proxy must be running before any service is accessible


---

## Security & Access Control

### MinIO access model

  - **Root credentials only (`MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`)**
    - **Pros**: Zero IAM configuration, immediate access, single credential pair to manage
    - **Cons**: Root credentials have unrestricted access to all buckets/operations — exposure = full data loss, no auditability of which system did what, cannot scope Airflow to specific buckets

  - **IAM users per environment (e.g., `airflow-prod`, `airflow-dev`)**
    - **Pros**: Least-privilege principle — Airflow user gets only read/write on its specific buckets, root credentials stay in vault, audit log differentiates user actions
    - **Cons**: MinIO IAM configuration required (`mc admin user add`, `mc admin policy attach`), more credentials to rotate

  - **Service accounts per DAG / pipeline (MinIO service account tokens)**
    - **Pros**: Maximum isolation — each pipeline has its own credential, compromise of one DAG's credentials doesn't expose other buckets, per-service-account audit trail
    - **Cons**: Many credentials to create and rotate, DAG code must load correct credential per pipeline, credential sprawl risk

### MinIO bucket policy strategy

  - **Single bucket, broad read/write policy for Airflow**
    - **Pros**: Zero bucket management overhead, simple connection config (one bucket name everywhere)
    - **Cons**: All DAGs share the same bucket — one buggy DAG can delete another's data, no cost attribution per pipeline, no data classification boundary

  - **Per-pipeline buckets with scoped IAM policies**
    - **Pros**: Complete data isolation between pipelines, `mc admin policy` scopes each IAM user to its own bucket, enables per-bucket lifecycle/retention rules
    - **Cons**: Bucket proliferation (10 pipelines = 10 buckets), each new pipeline requires bucket + policy + IAM user setup

  - **Prefix-based policies in shared bucket (`pipeline-a/*`, `pipeline-b/*`)**
    - **Pros**: Middle ground — single bucket, IAM policies scoped to path prefix, logical separation without bucket overhead
    - **Cons**: Policy conditions more complex (`s3:prefix` conditions in JSON), harder to set per-prefix lifecycle rules (MinIO lifecycle applies to bucket level), prefix discipline required in all DAG code

### MinIO TLS

  - **Self-signed certificate**
    - **Pros**: Zero cost, works immediately, no domain required
    - **Cons**: All clients must explicitly trust the CA cert (`mc --insecure` or distribute CA to trust store), browser shows warning for MinIO console, cert rotation is manual

  - **Let's Encrypt via certbot**
    - **Pros**: Free, globally trusted certificate, automated renewal via certbot cron/hook, works with any S3 client without cert distribution
    - **Cons**: Requires a publicly resolvable domain name (FQDN) pointing to the server, not feasible for fully air-gapped or private-IP-only environments

  - **Internal CA (e.g., `step-ca`, HashiCorp Vault PKI)**
    - **Pros**: Full TLS with short-lived certs, automated renewal, trusted internally without global exposure, works on private IPs
    - **Cons**: Must run and maintain an internal CA service, distribute root CA cert to all clients and containers, OCSP/CRL for revocation

  - **No TLS (plain HTTP)**
    - **Pros**: Simplest possible setup, no cert management
    - **Cons**: All data (including access credentials and file content) transmitted in plaintext, completely unacceptable for any production deployment handling non-trivial data

### Airflow Webserver authentication

  - **FAB default (username/password stored in Airflow DB)**
    - **Pros**: Zero external dependencies, `airflow users create` CLI to bootstrap, role-based (Admin/Viewer/Op/User) out of the box
    - **Cons**: Passwords stored in Airflow DB (Fernet-encrypted), no SSO, each user must be created manually, no 2FA support

  - **LDAP / Active Directory integration**
    - **Pros**: Centralized identity — users, groups and roles managed in existing org directory, account deactivation propagates automatically
    - **Cons**: LDAP server required (either existing corp LDAP or self-hosted OpenLDAP), LDAP connection string + bind DN config in `airflow.cfg`, TLS for LDAP (`ldaps://`) adds cert complexity

  - **OAuth2 / OIDC (Google Workspace, GitHub, Keycloak)**
    - **Pros**: Modern SSO — no password managed by Airflow, 2FA inherited from IdP, `@company.com` email domain restriction, audit trail in IdP
    - **Cons**: External IdP required (Google = data leaves premises, GitHub = developer-only), callback URL must be accessible from browser (not just overlay network)

  - **Self-hosted Keycloak**
    - **Pros**: Full SSO on-premise, supports SAML + OIDC, user federation to LDAP, fine-grained authorization, no data leaving server
    - **Cons**: Keycloak minimum deployment ~512MB RAM (JVM-based), requires its own DB (PostgreSQL), significant configuration complexity, another service to operate

### Airflow secret backend

  - **Environment variables in Docker Swarm stack**
    - **Pros**: Simplest possible — set `AIRFLOW_CONN_MINIO=...` in environment, Airflow reads it automatically via URI format
    - **Cons**: Secrets visible in `docker inspect <container>`, in `docker service inspect` and potentially in CI/CD logs — not secure for production credentials

  - **Airflow metastore (Variables + Connections via UI/CLI)**
    - **Pros**: Built-in, Fernet-encrypted at rest in DB, manageable via Airflow UI and `airflow connections` CLI, accessible to all workers via DB
    - **Cons**: Secrets tied to Airflow DB — DB dump = secrets dump, no external rotation workflow, Fernet key must be separately protected

  - **HashiCorp Vault (KV secrets engine)**
    - **Pros**: Industry-standard secrets management, dynamic secrets (short-lived credentials), full audit log of every secret access, `vault agent` for automatic renewal
    - **Cons**: Vault requires ~256–512MB RAM, must be initialized and unsealed, Vault HA requires etcd or Consul — significant operational overhead for this constraint

  - **Docker Swarm secrets (`docker secret create`)**
    - **Pros**: Secrets encrypted at rest in Swarm Raft store, only mounted into specified services as tmpfs files (never written to disk), not visible in `docker inspect`
    - **Cons**: Swarm-only mechanism (not portable to bare metal or K8s), secrets are static (no dynamic rotation), Airflow must read secrets from file paths, requires custom secret backend or init script

### Fernet key management

  - **Single static Fernet key as environment variable**
    - **Pros**: Zero config, single value to manage, works immediately
    - **Cons**: Key visible in `docker inspect`, rotation requires decrypting and re-encrypting every connection and variable in the DB, exposure = all encrypted secrets compromised

  - **Fernet key from Docker Swarm secret**
    - **Pros**: Not visible in `docker inspect` or `docker service inspect`, mounted as file, harder to accidentally expose in logs
    - **Cons**: Still static (requires manual rotation), Airflow must be configured to read key from file path via `AIRFLOW__CORE__FERNET_KEY_FILE`

  - **Scheduled Fernet key rotation (e.g., quarterly)**
    - **Pros**: Limits exposure window if key is leaked, best security practice
    - **Cons**: Requires `airflow rotate-fernet-key` CLI command during a maintenance window, all running workers must be restarted with new key simultaneously, operationally risky if not coordinated

### MinIO encryption at rest

  - **No encryption**
    - **Pros**: Maximum I/O throughput, zero CPU overhead, zero config
    - **Cons**: Data readable by anyone with physical access to disk or filesystem mount, non-compliant with most data security frameworks

  - **SSE-S3 (MinIO-managed keys, `x-amz-server-side-encryption: AES256`)**
    - **Pros**: Transparent to clients, zero extra infrastructure, keys managed by MinIO automatically, each object encrypted with unique data encryption key
    - **Cons**: Encryption keys stored on the same server as the data — physical disk theft still compromises both data and keys, not suitable for high-compliance environments

  - **SSE-KMS (external KMS, e.g., HashiCorp Vault KMS, AWS KMS)**
    - **Pros**: Keys physically separated from data — disk theft only gets encrypted ciphertext, key rotation handled by KMS, audit trail of every key access
    - **Cons**: Requires running and maintaining a KMS service (Vault adds ~256MB RAM), every MinIO read/write requires a KMS call (latency overhead), KMS downtime = MinIO cannot decrypt data

### Docker image security

  - **Official images only (`apache/airflow:2.x.x`, `minio/minio:RELEASE...`)**
    - **Pros**: Trusted provenance from official maintainers, widely reviewed, documented
    - **Cons**: May lag on CVE patches between releases, no ability to add custom Python packages or OS deps without a child image

  - **Custom images built from official base (`FROM apache/airflow:2.x.x`)**
    - **Pros**: Add custom providers, Python packages, certificates, OS packages while inheriting official image security baseline
    - **Cons**: Custom Dockerfile must be maintained, rebuilt and tested on upstream upgrades, image build pipeline required

  - **Image scanning in CI (Trivy, Grype, or Snyk)**
    - **Pros**: CVEs caught before images are pushed to production registry, scannable at build time and periodically on registry images, integrates with GitHub Actions / GitLab CI
    - **Cons**: Scanning adds 30–120s to CI pipeline, false positives require suppression configuration, CI/CD pipeline must exist

### Secrets in Docker Compose / Swarm stack file

  - **Environment variables directly in `docker-compose.yml` or `stack.yml`**
    - **Pros**: Simple, readable, works everywhere
    - **Cons**: Plaintext secrets in version-controlled YAML = credential exposure in Git history, `docker inspect` shows values

  - **Docker Swarm secrets reference (`secrets: - minio_root_password`)**
    - **Pros**: Secret values never in YAML file — only references, encrypted in Raft store, mounted as `tmpfs` in container
    - **Cons**: Swarm-only, secrets created separately from stack file, requires coordination between secret creation and stack deploy

  - **External injection at CI/CD deploy time (e.g., `sops`, `vault`, `envsub`)**
    - **Pros**: Secrets never committed to Git, injected only at deploy time, full audit trail in CI/CD system, works with any secret store
    - **Cons**: Requires CI/CD pipeline, secret values exist momentarily in CI/CD environment variables (still sensitive), pipeline must be secured

### Network segmentation

  - **Single flat overlay network for all services**
    - **Pros**: Zero extra configuration, all services discover each other by name, simplest mental model
    - **Cons**: If any one container is compromised, it can attempt connections to all other services (Airflow → PostgreSQL → attempt brute force, MinIO → attempt root credential spray)

  - **Tiered overlay networks (e.g., `frontend-net` for webserver+proxy, `backend-net` for scheduler+workers+postgres, `data-net` for MinIO+workers)**
    - **Pros**: Defense in depth — a compromised webserver cannot directly reach PostgreSQL, containers only on the networks they legitimately need
    - **Cons**: Every service must be attached to the correct named network(s), Docker Swarm multi-network config is more verbose, cross-network routing must be explicitly designed


---

## Log Management

### Airflow log storage location

  - **Local filesystem bind mount (`/opt/airflow/logs` → host path)**
    - **Pros**: Zero latency, no external dependency, works without any additional config
    - **Cons**: Each task's logs stored on whichever host's worker ran it — with multi-node, logs are not centralized and Airflow UI can only show logs from its own worker, silent disk-fill risk

  - **Remote logging to MinIO via S3 (`remote_base_log_folder = s3://airflow-logs/`)**
    - **Pros**: Centralized log storage accessible to any worker/scheduler regardless of which host they run on, Airflow UI fetches logs via pre-signed MinIO URLs, logs persist after container restart, leverages existing MinIO
    - **Cons**: Every task log write is now a network call to MinIO, Airflow connection `AIRFLOW_CONN_AWS_DEFAULT` or `AIRFLOW_CONN_MINIO` must be configured, MinIO downtime makes historical logs temporarily unretrievable in UI

  - **Remote logging to Elasticsearch**
    - **Pros**: Full-text search across all task logs from all time, Kibana for log visualization, alerting on error keywords
    - **Cons**: Elasticsearch minimum viable heap is 1–2GB RAM — significant resource cost on already-constrained hardware, Kibana adds another ~512MB, complex ILM (Index Lifecycle Management) required to prevent unbounded index growth

### Log retention and auto-cleanup

  - **`airflow db clean --clean-before-timestamp` scheduled as Airflow DAG**
    - **Pros**: Self-contained within Airflow ecosystem, configurable retention window, cleans both DB records and associated local log files, no external tooling
    - **Cons**: Dependent on scheduler being running to execute the cleanup DAG, if scheduler is down during scheduled cleanup, logs and DB records accumulate

  - **Logrotate on host (`/etc/logrotate.d/airflow`)**
    - **Pros**: OS-native, independent of Airflow health, simple `daily/weekly + rotate N + compress` config, runs via cron/anacron
    - **Cons**: Logrotate doesn't understand Airflow's DAG/run/task log directory hierarchy — rotates by file modification time, not by task semantics, may break Airflow UI log retrieval mid-rotation

  - **MinIO lifecycle rules (if using remote logging)**
    - **Pros**: S3-native automatic expiry — objects older than N days deleted automatically by MinIO lifecycle engine, zero operational overhead after initial setup, per-bucket granularity
    - **Cons**: Only applicable if remote logging to MinIO is configured, lifecycle engine runs asynchronously (eventual deletion, not immediate)

### `airflow db clean` scheduling

  - **Scheduled as an Airflow DAG (`@daily`, `--clean-before-timestamp 30 days ago`)**
    - **Pros**: Fully self-contained, visible in Airflow UI as a pipeline, easy to monitor for failures, can send alerts on failure via standard Airflow alerting
    - **Cons**: Circular dependency — the cleanup DAG requires a healthy scheduler, but DB bloat can slow the scheduler, bootstrapping problem if DB is severely bloated

  - **Host cron job (`0 2 * * * docker exec airflow_scheduler airflow db clean ...`)**
    - **Pros**: Independent of Airflow scheduler health, runs on OS schedule even if Airflow is partially degraded
    - **Cons**: Requires host cron access, hardcoded container name or ID (brittle if container restarts with new name), must handle case where container is not running

### Log aggregation stack

  - **No aggregation (per-service `docker logs` only)**
    - **Pros**: Zero overhead, no extra services
    - **Cons**: Correlating events across Airflow + MinIO + PostgreSQL requires logging into each container separately, no searchable historical logs beyond Docker's JSON file rotation window

  - **Promtail + Loki + Grafana (PLG stack)**
    - **Pros**: Lightweight (~100MB RAM for Loki + Promtail), integrates with existing Grafana (if deployed for metrics), LogQL for label-based filtering, long-term log storage to local filesystem or S3
    - **Cons**: Three extra services, Loki requires storage configuration to avoid unbounded local disk use, LogQL learning curve

  - **Fluent Bit (lightweight) → Elasticsearch**
    - **Pros**: Fluent Bit uses ~10MB RAM vs Fluentd's ~200MB, routes structured logs to Elasticsearch for full-text indexing
    - **Cons**: Still requires Elasticsearch (~1-2GB RAM), adds Kibana for UI — total RAM cost is high for this constrained environment

### Container log driver

  - **`json-file` (Docker default)**
    - **Pros**: Zero config, works everywhere, `docker logs <container>` works out of the box
    - **Cons**: No built-in rotation — log files grow unboundedly without `max-size`/`max-file` config, stored in `/var/lib/docker/containers/` on OS disk

  - **`json-file` with `max-size: "100m"` + `max-file: "5"`**
    - **Pros**: Simple rotation, prevents disk exhaustion from runaway containers (e.g., debug-mode Airflow scheduler), set once in Docker daemon config
    - **Cons**: Oldest log entries silently dropped when rotation occurs, total log history limited to `max-size × max-file = 500MB` per container

  - **`journald`**
    - **Pros**: systemd integration, logs queryable via `journalctl`, automatic systemd log rotation, structured metadata (unit name, container ID)
    - **Cons**: Host-specific (systemd-only), not portable to non-systemd environments, `docker logs` command may not work depending on Docker version

  - **`fluentd` log driver**
    - **Pros**: Logs shipped directly to Fluentd aggregator on every write — no local buffering risk
    - **Cons**: Fluentd must be running before any container starts, if Fluentd is down containers may fail to start or block on log writes, `async` mode reduces blocking but risks log loss

### MinIO server log verbosity

  - **Default INFO level**
    - **Pros**: Balanced verbosity — startup, config, errors and access attempts logged
    - **Cons**: High-throughput deployments generate significant log volume at INFO level (~1GB/day under heavy load)

  - **ERROR only**
    - **Pros**: Minimal log noise, low disk usage
    - **Cons**: Access audit trail absent — cannot detect unauthorized access attempts, data exfiltration, or misconfigured bucket policies post-incident

  - **AUDIT log enabled (`MINIO_AUDIT_WEBHOOK_ENABLE=on`)**
    - **Pros**: Every API call (PUT, GET, DELETE) logged with requester IP, bucket, object, timestamp — essential for compliance and forensics
    - **Cons**: Very high log volume (one log entry per object operation), requires webhook endpoint or log aggregator to handle volume without disk exhaustion

### Log-induced disk pressure protection

  - **Docker log rotation limits (per-service `logging: options: max-size/max-file`)**
    - **Pros**: Prevents any single container's logs from filling the OS disk, set declaratively in stack file
    - **Cons**: Applies only to Docker-managed container logs, not to application log files written directly to bind-mounted volumes

  - **Disk usage alert threshold (Prometheus `node_filesystem_avail_bytes` alert at 80% full)**
    - **Pros**: Early warning before disk fills completely, time to investigate and clean up
    - **Cons**: Alert is reactive (warns after filling starts), not preventive, requires monitoring stack to be running

  - **tmpfs for transient container logs (`tmpfs: /tmp/airflow/logs` for truly ephemeral)**
    - **Pros**: Log writes go to RAM (tmpfs), never hit disk at all — zero disk I/O overhead for transient logs
    - **Cons**: All logs lost on container restart, completely incompatible with log retention or post-mortem debugging, only appropriate for throw-away debug logs


---

## Resource Isolation & Enforcement

### Docker resource limits enforcement

  - **Hard limits (`resources.limits.cpus` + `resources.limits.memory` in stack file)**
    - **Pros**: Strictly enforced by Linux cgroups — container cannot consume more than limit, prevents noisy-neighbor starvation (MinIO write burst cannot steal Airflow's CPUs)
    - **Cons**: Requires careful tuning — too tight and tasks get OOM-killed or CPU-throttled, too loose and limits provide no protection

  - **Soft reservations (`resources.reservations.cpus` + `resources.reservations.memory`)**
    - **Pros**: Swarm scheduler uses reservations for placement decisions — ensures a node has enough capacity before scheduling a service, allows bursting above reservation if capacity is available
    - **Cons**: No enforcement — a service can exceed its reservation and starve neighbors, reservations only affect scheduling placement not runtime behavior

  - **No limits configured**
    - **Pros**: Absolutely zero configuration overhead
    - **Cons**: Any single service (e.g., MinIO rebalancing, Airflow task burst) can consume 100% of CPU/RAM and cause OOM or CPU starvation for all other services — unacceptable for production

### Memory limit enforcement mode

  - **Hard `mem_limit` (no swap)**
    - **Pros**: Completely predictable — container cannot exceed limit, OOM killer invoked immediately if exceeded, no silent performance degradation from swapping
    - **Cons**: Any task requiring more RAM than limit (e.g., large Pandas dataframe) is killed immediately with OOM, requires accurate limit sizing

  - **Soft `mem_limit` + `memswap_limit` (allow swap overflow)**
    - **Pros**: Occasional RAM spikes handled gracefully via swap rather than immediate kill, more forgiving for unpredictable workloads
    - **Cons**: Swap on SSD causes dramatic latency spikes (10–100× RAM latency), sustained swapping degrades all services on host, masks need to properly right-size limits

### Swap configuration

  - **Swap enabled on host (systemd/fstab swapfile)**
    - **Pros**: OS-level safety valve — prevents OOM cascade killing unrelated processes during memory pressure, enables containers with `memswap_limit` to overflow
    - **Cons**: Swap on HDD = severe latency, swap on SSD = moderate latency but SSD wear, sustained swapping indicates under-provisioning that should be fixed

  - **Swap disabled (`vm.swappiness=0` or no swap partition)**
    - **Pros**: Completely predictable performance — no hidden latency from swap I/O, forces proper capacity planning
    - **Cons**: OOM killer becomes aggressive under memory pressure, kernel may kill processes at seemingly random priorities if `oom_score_adj` not tuned

  - **Swappiness tuning (`sysctl vm.swappiness=10`)**
    - **Pros**: Kernel strongly prefers RAM over swap, uses swap only as last resort, best of both worlds for transient spikes
    - **Cons**: Requires `sysctl` tuning (host-level), default is 60 which is too aggressive for DB+application server mixed workloads

### CPU pinning and affinity

  - **No pinning (Linux CFS scheduler decides)**
    - **Pros**: Zero configuration, kernel handles CPU balancing automatically
    - **Cons**: Tasks may migrate between NUMA nodes causing cache invalidation, CPU-intensive MinIO hashing and Airflow task execution compete on same physical cores

  - **`cpuset` constraint per service (`--cpuset-cpus 0-3` for Airflow, `4-5` for MinIO)**
    - **Pros**: Dedicated CPU cores per service — MinIO cannot steal Airflow scheduler CPU, cache locality improved, predictable latency
    - **Cons**: CPUs sit idle in their assigned set even if another service is starving, requires NUMA topology knowledge to assign correctly

  - **cgroups v2 (automatic on Linux 5.8+ kernels, modern Docker)**
    - **Pros**: Better CPU scheduling fairness with `cpu.weight`, improved memory accounting, supports `memory.oom.group` for OOM behavior
    - **Cons**: Some older Docker Compose v2 features use cgroups v1 syntax (`--cpus`, `--memory`) which maps differently on v2-only hosts, kernel version dependency

### OOM kill behavior

  - **Default OOM killer (kernel decides based on memory footprint × heuristics)**
    - **Pros**: Automatic, no configuration needed
    - **Cons**: Kernel may kill PostgreSQL (large RSS footprint) instead of a runaway Airflow task — catastrophic if DB is killed unexpectedly

  - **`oom_score_adj` tuning (Docker `--oom-score-adj` per service)**
    - **Pros**: Explicitly tell kernel which processes are expendable (`oom_score_adj = 1000` = kill first) vs critical (`oom_score_adj = -1000` = kill last), protect PostgreSQL from OOM kill
    - **Cons**: Per-service configuration in stack file, must be explicitly set for every service, easy to forget for new services

  - **Alerting on OOM events (`dmesg | grep "oom-kill"` + Prometheus alert)**
    - **Pros**: Detect OOM kills before they cascade into visible outages, trigger investigation
    - **Cons**: Reactive — alert fires after OOM kill has already happened, requires monitoring stack

### Disk I/O throttling

  - **No I/O limits**
    - **Pros**: Maximum throughput for all services
    - **Cons**: MinIO large-file PUT operations can saturate disk bandwidth, causing PostgreSQL WAL writes to queue and Airflow DB transactions to timeout

  - **`blkio_weight` per service (Docker `--blkio-weight`)**
    - **Pros**: Relative I/O prioritization — PostgreSQL at weight 800, MinIO at weight 200, ensures DB gets priority during contention
    - **Cons**: `blkio_weight` is deprecated in cgroups v2 (replaced by `io.weight` in `io` controller), may not work on modern kernels

  - **Separate physical disks per workload (MinIO data disk, PostgreSQL data disk, OS disk)**
    - **Pros**: True I/O isolation — each disk has independent I/O queue, no contention possible, predictable latency per service
    - **Cons**: Hardware cost and planning, multiple disks to monitor for health, requires partitioning strategy at server setup time

### Airflow worker slot limits

  - **`AIRFLOW__CORE__PARALLELISM` (global max concurrent task instances)**
    - **Pros**: System-wide ceiling — regardless of how many DAGs are running, total tasks never exceed this, protects CPU/RAM from overcommit
    - **Cons**: Single large DAG backfill can consume all global slots, starving all other DAGs

  - **`AIRFLOW__CORE__MAX_ACTIVE_TASKS_PER_DAG`**
    - **Pros**: Per-DAG fairness — each DAG bounded independently, no single DAG monopolizes global parallelism
    - **Cons**: Must be set appropriately for DAGs with legitimate high parallelism (e.g., parallel data partition processing), too low throttles intentional parallelism

  - **Pool-based slot management (Airflow Pools per resource category)**
    - **Pros**: Most granular control — `minio_pool=5` means at most 5 tasks read/write MinIO simultaneously regardless of how many DAGs are running, prevents MinIO CPU/bandwidth saturation from Airflow side
    - **Cons**: Every DAG task must annotate with `pool=`, new DAGs from new team members may bypass pools without explicit code review enforcement


---

## High Availability on a Single Node

### Airflow Webserver HA

  - **Single replica (`replicas: 1`)**
    - **Pros**: Simple, default, uses minimal RAM, Swarm auto-restarts on crash (~15–30s recovery)
    - **Cons**: Active users see 503 during restart, any mid-form-submission action is lost, Swarm health check → restart is not instant

  - **Multiple replicas behind Docker Swarm VIP load balancer (`replicas: 2+`)**
    - **Pros**: Zero-downtime webserver crashes — VIP routes around unhealthy replica, rolling updates possible without downtime
    - **Cons**: Airflow webserver sessions must be stateless — JWT tokens work, but default cookie-based sessions with `AUTH_ROLE_SYNC_AT_RUNTIME=True` may have sticky session issues

  - **Multiple replicas + Redis for shared session storage**
    - **Pros**: Fully stateless webserver — any replica handles any request, session survives individual webserver restarts
    - **Cons**: Requires Redis (`AIRFLOW__WEBSERVER__SECRET_KEY` + Flask-Session + Redis backend), adds dependency on Redis for UI access

### Airflow Scheduler HA

  - **Single scheduler**
    - **Pros**: Zero extra config, default Airflow behavior, ~500MB RAM for scheduler process
    - **Cons**: Scheduler crash = ~15–30s gap where no tasks are scheduled (running tasks continue, but new task instances for pending DAG runs are not created during gap)

  - **Dual schedulers (Airflow 2.x `scheduler.num_runs` + DB locking)**
    - **Pros**: Both schedulers run concurrently, DB `SELECT FOR UPDATE SKIP LOCKED` ensures no double-scheduling, one crash has zero impact on scheduling continuity
    - **Cons**: Requires PostgreSQL (strict requirement, MySQL/SQLite not supported), ~doubled scheduler RAM (~1GB total), slightly higher DB CPU from two schedulers polling simultaneously

### MinIO HA on single node

  - **SNSD (single drive, single node)**
    - **Pros**: Zero config, works on any disk
    - **Cons**: No erasure coding, no redundancy, drive failure = data loss, Swarm auto-restart recovers process but not data

  - **SNMD with 4+ drives/partitions**
    - **Pros**: Erasure coding active (EC:2 or higher), survives drive failure, self-healing background scanner detects and repairs bit rot
    - **Cons**: Requires 4+ separately mounted drives or partitions — /mnt/disk1, /mnt/disk2, /mnt/disk3, /mnt/disk4 must exist on server setup

  - **Warm standby via `mc mirror` to secondary location**
    - **Pros**: Secondary copy of all objects, can be promoted if primary fails
    - **Cons**: `mc mirror` is near-realtime but not synchronous — RPO is nonzero (seconds to minutes of potential data loss), manual promotion required (no automatic failover)

### PostgreSQL HA on single node

  - **Single containerized PostgreSQL + Swarm restart policy**
    - **Pros**: Default behavior, Swarm restarts container on crash, `restart_policy: condition: any, delay: 5s`
    - **Cons**: ~15–30s downtime during restart, in-flight transactions rolled back, Airflow scheduler and workers will get `OperationalError` connection failures until DB recovers

  - **Primary + streaming replica (Patroni) on same host**
    - **Pros**: Automatic failover from primary to replica, zero-downtime PostgreSQL failure recovery
    - **Cons**: Same physical server means a host kernel panic kills both primary AND replica simultaneously, defeating the purpose — only protects against process crash, not hardware failure

  - **WAL-G continuous archiving to MinIO (`WALG_S3_PREFIX=s3://pg-wal-archive/`)**
    - **Pros**: PITR capability to any second in history, archives stored in existing MinIO, relatively low primary overhead (~5% I/O for WAL shipping)
    - **Cons**: Recovery requires manual intervention (`WAL-G backup-fetch` + `recovery.conf`), recovery time depends on backup age + WAL volume (RTO: 15–60 min typically)

### Docker Swarm restart policies

  - **`restart_policy: condition: any`**
    - **Pros**: Absolute guarantee — service always restarted on any exit (crash, OOM, `exit 0`), maximum availability
    - **Cons**: Masks repeated crash loops — a misconfigured service restarts forever, consuming resources and flooding logs without operator awareness

  - **`restart_policy: condition: on-failure, max_attempts: 3, window: 120s`**
    - **Pros**: Allows brief recovery from transient failures while preventing infinite restart loops, Swarm marks service as failed after max_attempts
    - **Cons**: Service may stay down if root cause (bad config, missing secret) isn't fixed — operator must investigate and re-deploy

  - **Restart policy + Docker HEALTHCHECK dependency**
    - **Pros**: Swarm only marks service healthy after health check passes, downstream services configured with `condition: service_healthy` get correct startup ordering
    - **Cons**: `condition: service_healthy` depends_on is only native in Compose v3, requires careful health check timeout tuning

### Swarm manager quorum

  - **Single manager node**
    - **Pros**: Simplest possible — all management operations go to one node, no quorum logic
    - **Cons**: Manager crash = no `docker service` commands possible (existing services continue running on workers, but no new deployments or scaling until manager recovers)

  - **3 manager nodes (requires 3 physical hosts)**
    - **Pros**: Tolerates 1 manager failure while maintaining quorum (`(3-1)/2 = 1 failure tolerance`), standard Swarm HA recommendation
    - **Cons**: Not feasible on a single physical server, requires multi-host infrastructure

### Redis HA (if CeleryExecutor)

  - **Single Redis container**
    - **Pros**: Simple, low resource, default
    - **Cons**: Redis crash = all Celery workers lose broker connection, in-flight task messages may be lost if not using AOF, ~15–30s gap until Swarm restarts Redis

  - **Redis Sentinel (3 sentinel processes + primary + replica)**
    - **Pros**: Automatic failover — sentinels detect primary failure and promote replica, workers reconnect to new primary automatically
    - **Cons**: Requires 3 sentinel containers + primary + replica = 5 containers minimum, all on same host (physical failure kills all), operationally complex

  - **Redis Cluster (3 primaries + 3 replicas = 6 nodes minimum)**
    - **Pros**: True horizontal scale + HA, automatic resharding
    - **Cons**: Overkill for single-node task brokering, 6 Redis containers consuming significant RAM, requires cluster-aware Celery broker URL format

### Service dependency ordering

  - **Docker healthchecks + `condition: service_healthy` (Compose v3 only)**
    - **Pros**: Explicit dependency graph — Airflow scheduler won't start until PostgreSQL passes health check, workers wait for scheduler
    - **Cons**: Native `depends_on: condition: service_healthy` not enforced in Docker Swarm mode (only in `docker compose up`), Swarm starts services independently of depends_on

  - **Retry loop in entrypoint script (`until pg_isready; do sleep 2; done`)**
    - **Pros**: Service handles its own dependency wait, works in both Swarm and Compose
    - **Cons**: Retry logic in entrypoint is a script (outside the no-scripts constraint here, noted for awareness)

  - **Restart-on-failure as dependency proxy**
    - **Pros**: Services that start before dependencies naturally fail and get restarted until dependencies are available, Swarm restart policy handles eventual convergence
    - **Cons**: Race condition window where all services start simultaneously, potential thundering herd of reconnection attempts stressing PostgreSQL startup


---

## Monitoring & Health Checks

### Metrics collection stack

  - **Prometheus + Grafana**
    - **Pros**: De facto industry standard for containerized environments, rich ecosystem of pre-built dashboards (Grafana.com), long-term metrics storage via Prometheus TSDB, alerting via Alertmanager
    - **Cons**: ~300–500MB RAM (Prometheus ~200MB + Grafana ~150MB), Prometheus TSDB disk usage grows over time without retention policy config

  - **Prometheus + Alertmanager + Grafana (full observability)**
    - **Pros**: Complete alerting pipeline — fire → route → silence → inhibit → notify, PagerDuty/Slack/email integrations
    - **Cons**: ~450–650MB total RAM for 3 services, Alertmanager routing config has learning curve

  - **Datadog agent (SaaS)**
    - **Pros**: Minimal local footprint (~100MB agent), hosted dashboards and alerting, auto-discovery of Docker containers, APM tracing
    - **Cons**: Subscription cost, telemetry data transmitted to Datadog servers (data sovereignty concern for on-prem deployments), vendor lock-in

  - **Netdata (open-source, low resource)**
    - **Pros**: ~50–80MB RAM, real-time per-second metrics, auto-discovers Docker containers without config, attractive built-in UI
    - **Cons**: Limited long-term storage in free version, less ecosystem integration vs Prometheus, alerting less mature than Alertmanager

### Airflow metrics export

  - **StatsD → `statsd_exporter` → Prometheus scrape**
    - **Pros**: Airflow has native StatsD support (`statsd_on=True`), sends scheduler heartbeat, task success/failure counters, DAG parsing time, executor metrics
    - **Cons**: Requires `statsd_exporter` sidecar container (~20MB RAM) to translate StatsD UDP to Prometheus metrics, UDP loss possible under extreme load

  - **OpenTelemetry (Airflow 2.7+ native support)**
    - **Pros**: Modern standard, vendor-neutral, single exporter supports Prometheus, Jaeger, Zipkin, OTLP
    - **Cons**: Newer feature with less community examples than StatsD path, OpenTelemetry Collector adds another service

### MinIO metrics export

  - **Native Prometheus endpoint (`/minio/v2/metrics/cluster`, `/minio/v2/metrics/node`)**
    - **Pros**: Built-in, zero extra services, exposes bucket-level metrics (object count, storage used), throughput (bytes read/written), API latency histograms
    - **Cons**: Endpoint must be scraped by Prometheus (requires `bearer_token` auth if MinIO requires it), metrics endpoint should not be publicly exposed

### Docker/Swarm metrics

  - **cAdvisor**
    - **Pros**: Per-container CPU, RAM, network, disk I/O metrics as Prometheus metrics, native Docker container label discovery
    - **Cons**: ~100MB RAM overhead, can itself generate significant CPU under high container churn

  - **Docker stats API (raw `docker stats` JSON)**
    - **Pros**: Zero extra services — built into Docker daemon
    - **Cons**: Not natively Prometheus-compatible, requires adapter or custom exporter, no historical storage

  - **Node Exporter (Prometheus community)**
    - **Pros**: Host-level metrics — filesystem space, CPU usage, RAM, network interfaces, disk I/O — all as Prometheus metrics, very lightweight (~10MB RAM)
    - **Cons**: Container-level metrics not included (use cAdvisor for container metrics alongside Node Exporter for host)

### Health check endpoints

  - **Airflow Webserver `/health` (returns JSON with `metadatabase` and `scheduler` status)**
    - **Pros**: Single endpoint reveals DB connectivity + scheduler heartbeat — catches common failure modes
    - **Cons**: Only checks webserver + its DB connection + scheduler heartbeat timestamp, doesn't verify workers are processing tasks

  - **MinIO `/minio/health/live` (liveness) + `/minio/health/ready` (readiness with quorum check)**
    - **Pros**: Separate live vs ready probes — liveness for restart trigger, readiness for traffic routing (Swarm VIP update health), quorum check verifies erasure coding is healthy
    - **Cons**: No auth required for health endpoints (minor security note: health endpoint must not leak sensitive info)

  - **PostgreSQL `pg_isready -h localhost -p 5432`**
    - **Pros**: Built-in CLI, returns exit code 0 on success, used in Docker HEALTHCHECK directly
    - **Cons**: Only checks if PostgreSQL accepts connections, doesn't verify it can execute queries, WAL replay lag on replica not visible

### Alerting channels

  - **Alertmanager → Email (SMTP)**
    - **Pros**: Universal, no external service dependency, everyone has email
    - **Cons**: Email may be delayed or filtered to spam, no mobile push, easy to miss during off-hours

  - **Alertmanager → Slack/Teams webhook**
    - **Pros**: Real-time team notification, threads for discussion, mobile app push notification, channel-based routing by severity
    - **Cons**: Requires Slack/Teams workspace and webhook token, vendor-dependent (Slack outage = silent alerts)

  - **Alertmanager → PagerDuty**
    - **Pros**: On-call rotation management, escalation policies, 24/7 coverage for critical alerts, integrates with incident management workflows
    - **Cons**: Subscription cost per user, external dependency, overkill for small teams

  - **Grafana built-in alerts (no Alertmanager)**
    - **Pros**: Single tool — dashboards and alerting in same UI, no Alertmanager to configure
    - **Cons**: Less powerful routing/grouping/silencing than Alertmanager, contact point configuration less flexible, alert state stored in Grafana DB

### Uptime and blackbox monitoring

  - **Blackbox Exporter (Prometheus HTTP/TCP probe)**
    - **Pros**: Probes services from outside (as a client would), catches cases where service is up but Prometheus is scraping incorrectly, supports TLS certificate expiry checks
    - **Cons**: Additional service (~20MB RAM), probes from within same network (not truly external perspective)

  - **External SaaS (UptimeRobot, BetterUptime, Freshping)**
    - **Pros**: Genuinely external — detects if server is unreachable from internet, notifies even if local monitoring stack is down
    - **Cons**: Requires exposing at least one health endpoint to internet (or VPN), telemetry to external provider

  - **No external probing**
    - **Pros**: Zero configuration
    - **Cons**: Cannot detect failure of the monitoring stack itself — if Prometheus crashes, all alerts stop silently


---

## Backup & Disaster Recovery

### PostgreSQL backup strategy

  - **`pg_dump` cron → local file**
    - **Pros**: Simple, no external dependencies, `pg_dump` is consistent (MVCC snapshot)
    - **Cons**: Local file lost if server disk fails, backup on same physical media as data provides no protection against hardware failure

  - **`pg_dump` cron → MinIO bucket (`mc cp` or `aws s3 cp`)**
    - **Pros**: Off-host — backup survives server disk failure as long as MinIO uses separate drive, S3-versioning protects against accidental overwrite
    - **Cons**: MinIO must be healthy for backup to succeed — if MinIO is down during backup window, backup silently skips, requires separate monitoring of backup job success

  - **WAL-G continuous archiving to MinIO**
    - **Pros**: PITR to any second, low backup overhead (only WAL segments shipped continuously, base backup weekly), backup interruption doesn't lose progress (resumes WAL shipping), standard in production PostgreSQL
    - **Cons**: WAL-G configuration complexity (`WALG_S3_PREFIX`, `WALG_COMPRESSION_METHOD`, `WALG_RETENTION_FULL_BACKUPS`), restore process requires understanding WAL replay

  - **Barman (Backup and Recovery Manager)**
    - **Pros**: Full-featured backup orchestration, incremental backups, backup catalog management, pre/post backup hooks, replication management
    - **Cons**: New service to run and maintain, ~100MB RAM, Python-based, significant operational learning curve, may be over-engineered for single-server deployment

### PostgreSQL backup frequency

  - **Daily full `pg_dump`**
    - **Pros**: Simple schedule, single file per day, easy to understand retention
    - **Cons**: Up to 24 hours of data loss possible (RPO = 24h), dump of large Airflow metadata DB can take minutes and load DB during business hours

  - **Hourly incremental (WAL-G or pg_basebackup incremental)**
    - **Pros**: RPO reduced to 1 hour, smaller individual backup sizes
    - **Cons**: Restore requires applying incremental chain (more complex), more backup storage consumed

  - **Continuous WAL shipping (WAL-G WAL archive every 60s)**
    - **Pros**: RPO near-zero (seconds), no scheduled backup window needed, PITR to any point
    - **Cons**: Requires WAL-G setup, steady-state MinIO write traffic from WAL segments (low volume ~1–10MB/min depending on write workload)

### MinIO data backup

  - **`mc mirror <source> <destination>` to secondary location**
    - **Pros**: Native MinIO tooling, mirrors bucket structure including metadata, can run as continuous background sync or scheduled
    - **Cons**: Secondary location must exist (another disk, another server, NAS), eventually consistent (not synchronous), requires secondary MinIO or S3-compatible target

  - **Restic to external target (external NAS, cloud storage, another server)**
    - **Pros**: Deduplication reduces backup size significantly for datasets with repeated objects, AES-256 encryption built-in, content-addressable storage, `restic check` verifies backup integrity
    - **Cons**: Extra tool to install and configure, snapshot management (pruning) required, restore process differs from standard S3 copy

  - **No backup (MinIO used only for ephemeral/staging data)**
    - **Pros**: Zero operational overhead
    - **Cons**: Only valid architectural decision if MinIO objects are 100% reproducible from source systems (e.g., raw data always re-ingestible), any persistent processed output must be backed up

### Backup retention policy

  - **GFS (Grandfather-Father-Son): 7 daily + 4 weekly + 12 monthly**
    - **Pros**: Industry-standard, covers both recent recovery (daily) and long-term audit/compliance (monthly), well-understood by ops teams
    - **Cons**: Higher storage consumption than flat retention, requires backup tool support for GFS rotation logic

  - **30-day flat daily retention**
    - **Pros**: Simple to implement and reason about, covers most recovery scenarios
    - **Cons**: No backups older than 30 days — accidental data corruption discovered after 30 days has no backup to recover from

  - **MinIO lifecycle rules (if backup target is MinIO bucket)**
    - **Pros**: S3-native automatic deletion of objects older than N days, zero ongoing maintenance
    - **Cons**: Only works if backup destination is an S3-compatible bucket, lifecycle rules apply to prefix patterns not GFS semantics — GFS requires scripted rotation

### Backup encryption

  - **Unencrypted backups**
    - **Pros**: Simplest, no key management
    - **Cons**: `pg_dump` files contain all Airflow connection passwords, Fernet keys, Variable values in plaintext — backup theft = credential compromise

  - **GPG symmetric encryption before upload (`gpg --symmetric --cipher-algo AES256`)**
    - **Pros**: Strong encryption, portable (GPG available everywhere), encrypted file usable on any system with passphrase
    - **Cons**: Passphrase management (where is it stored?), GPG adds CPU overhead for large dumps, manual process if not scripted

  - **Restic built-in AES-256 encryption**
    - **Pros**: Transparent — every Restic backup is always encrypted, no extra steps, passphrase stored in password manager or Docker secret
    - **Cons**: Restic-specific format (not a raw `.sql` file), must use `restic restore` to access backup, losing passphrase = permanent data loss

### Disaster recovery RTO target

  - **RTO < 1 hour**
    - **Pros**: Minimal business disruption, achievable with pre-staged restore playbooks and PITR
    - **Cons**: Requires documented and tested runbooks, potentially warm standby or pre-provisioned recovery environment

  - **RTO < 4 hours**
    - **Pros**: Achievable with `pg_dump` + MinIO restore + config re-application from Git
    - **Cons**: 4-hour downtime may be unacceptable for pipelines with tight SLAs, assumes backup is accessible and healthy

  - **RTO < 24 hours**
    - **Pros**: Minimal infrastructure investment required, allows time for thorough recovery
    - **Cons**: Full-day outage of data pipelines likely unacceptable in most production contexts

### Backup validation

  - **Monthly restore drill (restore to isolated test environment, verify DB connectivity + Airflow startup)**
    - **Pros**: Only way to confirm backups are actually restorable, reveals config drift, builds operator muscle memory
    - **Cons**: Time-consuming (~2–4 hours monthly), requires a test environment that mirrors production

  - **Automated checksum verification (`sha256sum` of backup files or `restic check`)**
    - **Pros**: Fast, automated, detects bit-rot or incomplete uploads
    - **Cons**: Confirms file integrity but not restorability — a structurally corrupt but bit-perfect dump file would pass checksum

  - **No validation**
    - **Pros**: Zero effort
    - **Cons**: Backups may be silently corrupt for months, only discovered during a real disaster when recovery fails

### Config and secrets backup

  - **Docker Swarm secrets backed up manually (export from Swarm Raft store periodically)**
    - **Pros**: Protects against secret loss if Swarm manager is lost
    - **Cons**: Swarm secrets cannot be exported via standard API — requires custom tooling or separate storage in Vault

  - **All non-secret configuration in Git (stack files, Airflow config, MinIO policies)**
    - **Pros**: Version history, rollback, peer review for all config changes, rebuild from scratch possible from Git
    - **Cons**: Secrets must never enter Git — `.env` files with credentials must be explicitly gitignored, discipline required

  - **No explicit config backup**
    - **Pros**: Zero effort
    - **Cons**: Disaster recovery requires reconstructing all configuration from memory — operator dependency, config drift undocumented


---

## DAG Lifecycle & CI/CD

### DAG deployment strategy

  - **Git-sync sidecar (`git-sync` container sharing volume with scheduler + workers)**
    - **Pros**: Continuous sync from Git repository, every DAG is a reviewed commit, rollback = `git revert` + push, no manual copy steps, supports private repos via SSH deploy key
    - **Cons**: Sidecar container runs continuously (~50MB RAM), volume must be shared between scheduler and all worker containers (Swarm named volume or NFS), SSH key or Git token managed as Docker secret

  - **CI/CD pipeline `rsync` or `mc cp` to shared volume on deploy**
    - **Pros**: Controlled deployments — only tested DAGs deploy, CI pipeline can run `airflow dags test` before deploy
    - **Cons**: Requires CI/CD infrastructure (GitHub Actions, GitLab CI, Jenkins), deploy trigger is explicit push/merge rather than automatic

  - **Direct bind mount to host directory (manual file copy)**
    - **Pros**: Absolutely zero tooling required — `scp dag.py airflow-server:/opt/airflow/dags/`
    - **Cons**: No version control integration, no audit trail, stale/broken DAGs accumulate without review, human error risk

### DAG versioning

  - **Git tags per release (`v1.2.3` on merge to main)**
    - **Pros**: Clear version history, auditable, can pin git-sync to a specific tag for controlled rollouts
    - **Cons**: Requires Git tagging discipline, semantic versioning policy must be agreed upon

  - **DAG file modification timestamp (implicit versioning)**
    - **Pros**: Zero extra process
    - **Cons**: No explicit version identifiers, hard to correlate a deployed DAG version with a specific code review or JIRA ticket

  - **Airflow serialized DAGs in DB (Airflow stores DAG structure in DB on parse)**
    - **Pros**: DAG structure queryable from DB without filesystem access, version history via DB migrations
    - **Cons**: Not a versioning system — only reflects last-parsed state, no rollback capability from serialized DAGs alone

### DAG testing before deployment

  - **`airflow dags test <dag_id> <execution_date>` in CI**
    - **Pros**: Runs DAG against real task code in an isolated environment, catches import errors, operator misconfiguration and connection issues early
    - **Cons**: Requires Airflow + dependencies installed in CI environment, slow for DAGs with many tasks, cannot test against production data without real connections

  - **pytest unit tests on DAG structure (`dag.test_cycle()`, `dag.get_task()` assertions)**
    - **Pros**: Fast, pure Python tests with no Airflow DB needed, validates DAG topology without executing tasks, can run in lightweight CI
    - **Cons**: Only validates DAG structure and imports, doesn't catch runtime errors within operators

  - **No pre-deployment testing**
    - **Pros**: Zero CI/CD setup required
    - **Cons**: Parse errors and broken imports hit production scheduler, DAG appears as `Import Error` in Airflow UI, other DAGs may be unaffected but broken DAG occupies an import error slot

### Broken DAG handling

  - **`dagbag_import_error_tracebacks_truncate_length = 0` (full traceback in UI)**
    - **Pros**: Full error visible in Airflow UI without log diving
    - **Cons**: Default behavior, no active alerting — error silently sits in UI until operator notices

  - **Prometheus/StatsD alert on `dagbag_import_errors` counter > 0**
    - **Pros**: Proactive notification — operator alerted immediately when any DAG breaks, SLA on fix response possible
    - **Cons**: Requires StatsD/OpenTelemetry metrics export + Prometheus + Alertmanager to be configured

  - **Automated rollback on import error detection**
    - **Pros**: Broken DAG automatically reverted to last known good version
    - **Cons**: Requires custom watcher logic (a script or DAG that monitors dagbag errors and triggers git-sync rollback) — complex to implement correctly

### DAG rollback strategy

  - **Git revert + push (git-sync picks up automatically)**
    - **Pros**: Standard GitOps — revert commit, push to main, git-sync detects new HEAD within sync interval (60s)
    - **Cons**: Revert takes ~2–5 minutes from decision to deployed, broken DAG causes missed task instances during that window

  - **Keep `.backup` copy of previous DAG file on deploy**
    - **Pros**: Instant rollback — rename `.backup` to `.py`
    - **Cons**: Manual discipline required, `.backup` files must be cleaned up regularly, no semantic versioning

  - **Blue/green DAG directories (`/dags/blue/`, `/dags/green/` with symlink swap)**
    - **Pros**: Atomic switch between versions, both versions available simultaneously during testing
    - **Cons**: Swarm volume mount must handle symlink updates, Airflow DAG folder must include both directories, DAG IDs must be unique across directories


---

## Scalability & Future-Proofing

### Path from single-node to multi-node Swarm

  - **Overlay network from day one (even on single node)**
    - **Pros**: Zero reconfiguration required when adding nodes — new nodes join Swarm, services automatically distribute, no service interruption
    - **Cons**: Minimal extra latency on single node (~0.2ms vs bridge), VXLAN overhead negligible on modern 10GbE networks

  - **Bridge network now, migrate to overlay when scaling**
    - **Pros**: Slightly simpler day-one setup, marginally lower latency
    - **Cons**: Migration to overlay requires taking services down, reconfiguring network attachments, potential downtime and risk of misconfiguration

  - **Plan for Kubernetes migration instead of Swarm scale-out**
    - **Pros**: K8s has a richer ecosystem (HPA, KEDA, KubernetesExecutor for Airflow), more hiring pool familiar with K8s
    - **Cons**: Completely different toolchain, K8s learning curve, Swarm → K8s is a full migration not an upgrade

### MinIO scale-out path

  - **Start SNSD, migrate to MNMD when more drives available**
    - **Pros**: Minimal day-one complexity, SNSD → MNMD migration supported via `mc mirror` to new MNMD cluster + DNS cutover
    - **Cons**: Migration requires full data copy (proportional to data volume), downtime window or read-only mode during cutover

  - **Start SNMD with 4 drives from day one**
    - **Pros**: Erasure coding active immediately, no future migration needed, self-healing available from day one
    - **Cons**: Server must have 4+ separate drive mount points from initial setup, all must be configured before first MinIO start

  - **Build toward MinIO federated gateway (future)**
    - **Pros**: Unlimited horizontal scale, bucket routing across multiple MinIO sites
    - **Cons**: Significantly complex topology, requires DNS-based routing, relevant only at scale far beyond current constraints

### Airflow executor upgrade path (Local → Celery)

  - **LocalExecutor now, documented Celery migration path**
    - **Pros**: Saves ~200-400MB RAM on day one (no broker/result backend), simpler to operate, migration to CeleryExecutor is well-documented (add Redis, change executor config, add worker service)
    - **Cons**: Migration to CeleryExecutor requires service restart, brief scheduling gap during transition

  - **CeleryExecutor from day one**
    - **Pros**: Scale-ready immediately, no future migration, worker services can be replicated same day as capacity expands
    - **Cons**: Consumes ~200–400MB additional RAM for Redis + extra Celery infra even when single-worker, more complexity to operate from day one

### Storage volume portability

  - **Named Docker volumes throughout (Airflow logs, DAGs, PostgreSQL data)**
    - **Pros**: Docker-managed, compatible with volume plugins (REX-Ray, Portworx) for multi-host attachment when scaling
    - **Cons**: Data lives under `/var/lib/docker/volumes` — not intuitive to back up directly, volume data migration between hosts requires explicit tools

  - **Bind mounts throughout (explicit host paths)**
    - **Pros**: Transparent — paths are visible and obvious on the host, easy to back up with `rsync`, familiar to sysadmins
    - **Cons**: Host path hardcoded in stack file, breaks portability if path structure differs between nodes in a multi-node Swarm

### Configuration management for scale-out

  - **Environment variables in stack file per service**
    - **Pros**: Self-contained, Git-tracked, visible in one place
    - **Cons**: When scaling to multiple Swarm nodes, stack file must be redeployed to propagate config changes, no dynamic config update without redeploy

  - **Consul KV store (service config read at startup)**
    - **Pros**: Dynamic config — update a key in Consul, services read new value on next restart without stack file change, single source of truth across all nodes
    - **Cons**: Consul is a new service with its own HA concerns, adds ~50–100MB RAM, application code must integrate Consul SDK or use envconsul sidecar

  - **`.env` files per environment (prod.env, staging.env)**
    - **Pros**: Simple, familiar `dotenv` pattern, works with `docker stack deploy --env-file`
    - **Cons**: `.env` files contain secrets — must never be committed to Git, must be distributed to each Swarm manager manually, no centralized change tracking


---

## Operational & Maintenance

### Airflow upgrade strategy

  - **In-place image tag update (`image: apache/airflow:2.x.x` → `2.y.y` + `docker stack deploy`)**
    - **Pros**: Simple, fast, no parallel infrastructure
    - **Cons**: Broken migration = immediate production impact, DB migration (`airflow db migrate`) must complete successfully before scheduler starts, risk of breaking change between minor versions

  - **Blue/green stack deployment (deploy new stack alongside old, cut over DNS/VIP)**
    - **Pros**: Zero-downtime upgrade — full new version running and verified before any traffic cut, instant rollback by switching VIP back
    - **Cons**: Doubles resource consumption during transition window (~double RAM for Airflow services), DB migration complicates blue/green (both stacks cannot run DB migrations simultaneously)

  - **Canary deployment (route 5–10% of DAG scheduling to new version)**
    - **Pros**: Risk-limited — majority of workload on stable version while new version validated on small subset
    - **Cons**: Requires sophisticated traffic routing (hard to implement for Airflow scheduler), Airflow does not natively support canary at the task routing level without custom logic

### MinIO upgrade strategy

  - **Rolling update (MNMD mode only — update one node at a time)**
    - **Pros**: Zero downtime — MinIO quorum maintained as long as ≥ (n/2 + 1) nodes healthy, official MinIO recommended upgrade path
    - **Cons**: Only available in MNMD mode, not applicable to SNSD single-node deployment

  - **Full stop and replace (`docker service update --image minio/minio:NEW_TAG`)**
    - **Pros**: Simple, always works, no quorum complexity
    - **Cons**: Brief downtime window (~10–30s for new container to start), Airflow tasks connecting to MinIO during update will fail with connection error

  - **Side-by-side new MinIO version with `mc mirror` cutover**
    - **Pros**: New version fully tested with real data before traffic cut, rollback = revert `MINIO_ENDPOINT` env var in Airflow
    - **Cons**: Requires temporary double storage capacity, `mc mirror` lag means some objects may be missing in new instance during transition

### PostgreSQL upgrade strategy (e.g., PG 14 → PG 16)

  - **`pg_upgrade` in-place**
    - **Pros**: Fast — upgrades data directory in-place without full data copy, minimal downtime (typically minutes)
    - **Cons**: `pg_upgrade --check` must be run first, any incompatibility = failed upgrade, requires exact binaries of both old and new PG version available

  - **Dump/restore to new version container**
    - **Pros**: Clean migration — `pg_dump` from old, restore to new, verifiable at each step
    - **Cons**: Full downtime for duration of `pg_dump` + `pg_restore` (proportional to DB size, minutes to hours for large Airflow metadata DB)

  - **Logical replication to new version**
    - **Pros**: Near-zero downtime — replicate from old PG to new PG while old runs, cutover by pointing Airflow to new PG with minimal gap
    - **Cons**: Requires understanding of PG logical replication (publication/subscription), DDL changes (schema migrations) not replicated logically, complex coordination

### Docker image update cadence

  - **Pin to exact image digest (`apache/airflow@sha256:abc123...`)**
    - **Pros**: 100% reproducible builds — same binary bytes every deploy, immune to upstream tag mutation
    - **Cons**: Manual process to update digest, digest changes even for patch updates require explicit operator action, harder to read in stack files

  - **Pin to `major.minor` tag (`apache/airflow:2.9` not `2.9.1`)**
    - **Pros**: Automatically picks up patch releases within minor version on next `docker pull`, balanced between stability and receiving patches
    - **Cons**: Minor-version tags can be mutated by maintainer — `docker pull` may silently pull a different image than before, no guarantee of exact reproducibility

  - **Use `latest` tag**
    - **Pros**: Always newest version
    - **Cons**: Absolute worst practice for production — tag mutates at every release, uncontrolled upgrades break production without warning, debugging becomes impossible ("what version is running?" = unknown)

### Dependency update management

  - **Renovate Bot / Dependabot (automated PR per dependency update)**
    - **Pros**: Never manually scan for updates, PR automatically created with changelog and diff, CI validates before merge, audit trail in Git
    - **Cons**: Requires CI/CD pipeline + Git repo + review process, high-volume repos may generate many PRs requiring triage

  - **Manual monthly scheduled review (check Docker Hub release notes, CVE feeds)**
    - **Pros**: Simple process, batches updates into planned maintenance windows, human judgment on update priority
    - **Cons**: Human-dependent and easy to skip, interval between reviews allows CVE accumulation, no automation safety net

  - **No update process**
    - **Pros**: Zero effort
    - **Cons**: Accumulates known CVEs over time, no security patches applied, compliance failures, increasing tech debt

### On-call and runbook documentation

  - **Runbooks in Git wiki (Markdown, co-located with infrastructure code)**
    - **Pros**: Version-controlled, PRs for runbook changes, searchable, links to relevant config files
    - **Cons**: Must be actively maintained, easy to drift from actual procedures if not reviewed regularly

  - **Confluence or Notion (external documentation platform)**
    - **Pros**: Rich formatting, diagrams, video embeds, cross-linking, good for non-technical stakeholders
    - **Cons**: External dependency (SaaS), potential cost, not version-controlled alongside code, risk of docs/code divergence

  - **No formal documentation**
    - **Pros**: Zero effort
    - **Cons**: Bus factor = 1 (only one person knows how to recover the system), onboarding new ops team members is slow and risky, disaster recovery depends entirely on institutional memory

### Change management process

  - **All infrastructure changes via Git PRs (GitOps)**
    - **Pros**: Every change reviewed, audit trail permanent in Git history, broken change easily reverted via `git revert`, CI validates syntax before merge
    - **Cons**: Process overhead — emergency changes during incidents slowed by PR review requirement, must have streamlined emergency PR process

  - **Direct stack redeploy by ops engineer (`docker stack deploy`)**
    - **Pros**: Fast, no review friction, immediate
    - **Cons**: No audit trail (who deployed what when), no peer review, accidental changes applied instantly to production, config drift between intended state (Git) and actual state

  - **Scheduled maintenance windows for all changes**
    - **Pros**: Predictable impact windows communicated to stakeholders, off-peak timing reduces blast radius
    - **Cons**: Slows iteration speed, hotfixes still need emergency path, maintenance window coordination overhead

