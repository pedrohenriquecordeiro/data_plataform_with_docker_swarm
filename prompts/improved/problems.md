## terminal logs
pedrojesus@dev-redis:~/platform$ sudo bash airflow/scripts/deploy_airflow.sh
[INFO]  2026-02-22 18:01:08 — Checking Docker Swarm status...
[INFO]  2026-02-22 18:01:08 — Docker Swarm is active.
[INFO]  2026-02-22 18:01:08 — Loaded environment variables from /home/pedrojesus/platform/.env
[INFO]  2026-02-22 18:01:08 — Step 1: Creating Airflow Docker Swarm secrets...
[WARN]  2026-02-22 18:01:08 — Secret 'airflow_fernet_key' already exists. Skipping creation.
[WARN]  2026-02-22 18:01:08 — Secret 'airflow_secret_key' already exists. Skipping creation.
[WARN]  2026-02-22 18:01:08 — Secret 'airflow_db_password' already exists. Skipping creation.
[WARN]  2026-02-22 18:01:08 — Secret 'airflow_admin_password' already exists. Skipping creation.
[WARN]  2026-02-22 18:01:08 — Secret 'airflow_admin_user' already exists. Skipping creation.
[INFO]  2026-02-22 18:01:08 — Step 2: Ensuring shared overlay network exists...
[INFO]  2026-02-22 18:01:08 — Overlay network 'data-platform-network' already exists. Skipping.
[INFO]  2026-02-22 18:01:08 — Step 3: Ensuring host data directories exist...
[INFO]  2026-02-22 18:01:08 — Host data directories created/verified.
[INFO]  2026-02-22 18:01:08 — Step 4: Deploying Airflow stack...
Since --detach=false was not specified, tasks will be created in the background.
In a future release, --detach=false will become the default.
Updating service airflow_redis (id: eqvywbekh3f62pxuvwi9gveqf)
Updating service airflow_airflow-webserver (id: jmwrw8q87t48cq4glozf6tzqc)
image registry.local/data-platform/airflow:2.10.5 could not be accessed on a registry to record
its digest. Each node will access registry.local/data-platform/airflow:2.10.5 independently,
possibly leading to different nodes running different
versions of the image.

Updating service airflow_airflow-scheduler (id: yngg07wtyg2zzdrz59ox5a42j)
image registry.local/data-platform/airflow:2.10.5 could not be accessed on a registry to record
its digest. Each node will access registry.local/data-platform/airflow:2.10.5 independently,
possibly leading to different nodes running different
versions of the image.

Updating service airflow_airflow-worker (id: muk1jf9c8ktf5zuk82xd5xvok)
image registry.local/data-platform/airflow:2.10.5 could not be accessed on a registry to record
its digest. Each node will access registry.local/data-platform/airflow:2.10.5 independently,
possibly leading to different nodes running different
versions of the image.

Updating service airflow_airflow-triggerer (id: rsygu4zxdvv96krljr9ewl5k2)
image registry.local/data-platform/airflow:2.10.5 could not be accessed on a registry to record
its digest. Each node will access registry.local/data-platform/airflow:2.10.5 independently,
possibly leading to different nodes running different
versions of the image.

Updating service airflow_postgres (id: y0fth6i3b0bebzzo9zkz6yeo5)
[INFO]  2026-02-22 18:01:12 — Airflow stack deployed successfully.
[INFO]  2026-02-22 18:01:12 — Step 5: Waiting for Airflow webserver to become healthy...
[INFO]  2026-02-22 18:01:12 — Webserver not ready (0s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:01:22 — Webserver not ready (10s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:01:32 — Webserver not ready (20s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:01:42 — Webserver not ready (30s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:01:52 — Webserver not ready (40s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:02:02 — Webserver not ready (50s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:02:12 — Webserver not ready (60s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:02:22 — Webserver not ready (70s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:02:32 — Webserver not ready (80s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:02:42 — Webserver not ready (90s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:02:52 — Webserver not ready (100s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:03:02 — Webserver not ready (110s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:03:12 — Webserver not ready (120s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:03:22 — Webserver not ready (130s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:03:32 — Webserver not ready (140s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:03:42 — Webserver not ready (150s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:03:52 — Webserver not ready (160s elapsed). Retrying in 10s...
[INFO]  2026-02-22 18:04:02 — Webserver not ready (170s elapsed). Retrying in 10s...
[ERROR] 2026-02-22 18:04:12 — Airflow webserver did not become healthy within 180 seconds.
[ERROR] 2026-02-22 18:04:12 — Check service logs: docker service logs airflow_airflow-webserver


## docker logs
 *  Executing task: docker logs --tail 1000 -f cf71d29ef710504b23da218b128f955f714d5eb8cf0241cfaa23a096b264ac46 


[2026-02-22T21:02:12.972+0000] {configuration.py:2112} INFO - Creating new FAB webserver config file in: /opt/airflow/webserver_config.py
ERROR: You need to initialize the database. Please run `airflow db init`. Make sure the command is run using Airflow version 2.10.5.
 *  Terminal will be reused by tasks, press any key to close it. 


                                                                                                                         

## my story


## context 
i am connected to the server by openvpn. 

## rules
Whenever a file is modified, identify all downstream dependencies and related configurations. Automatically propagate the changes to these files to ensure the entire project remains consistent and functional.