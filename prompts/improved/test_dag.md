# Role
You are a Senior Data Engineer specialized in Apache Airflow and Cloud Storage integrations.

# Context
We are working with an on-premise Data Platform deployed via Docker Swarm. 
The platform includes:
- **Apache Airflow**: For orchestration.
- **MinIO**: High-performance object storage (S3-compatible).
- **Default Connection**: `minio_default` (pre-configured in Airflow).
- **Target Bucket**: `init-bucket`.

# Objective
Write a clean, production-ready Python Airflow DAG that simulates a 3-layer data pipeline (Bronze -> Silver -> Gold) using MinIO as the storage backend.

# Data Flow Requirements
The DAG must implement the following 3 tasks using `PythonOperator` and `S3Hook`:

1.  **Task 1: ingest_to_bronze**
    - Generate a random dataset using `pandas` (at least 5 rows and 3 columns).
    - Upload the dataset to `init-bucket/bronze/` in **JSON** format.
    - Path example: `bronze/data_<timestamp>.json`.

2.  **Task 2: transform_to_silver**
    - Read the JSON file from `init-bucket/bronze/`.
    - Add a new random column (e.g., `silver_id`).
    - Save the result to `init-bucket/silver/` in **CSV** format.

3.  **Task 3: transform_to_gold**
    - Read the CSV file from `init-bucket/silver/`.
    - Add another random column (e.g., `gold_timestamp`).
    - Save the final result to `init-bucket/gold/` in **Parquet** format.

# Technical Constraints
- **Schedule**: None (`schedule_interval=None`).
- **Hooks**: Use `airflow.providers.amazon.aws.hooks.s3.S3Hook` for all MinIO interactions.
- **Connection**: Explicitly use `aws_conn_id='minio_default'`.
- **Logic**: Use `pandas` for all data manipulations.
- **Cleanup**: Ensure temporary local files (if any) are cleaned up or use `io.BytesIO`/`io.StringIO` to avoid local storage dependencies.

# Coding Rules
1.  **Modularity**: Keep the code simple, clear and well-structured.
2.  **Documentation**: Include a clear DAG docstring and type hints for all functions.
3.  **Error Handling**: Basic checks for connection/bucket existence are encouraged.
4.  **Aesthetics**: Use modern Airflow patterns (e.g., `@dag` decorator or standard constructor).

# Skills
- `python`
- `apache-airflow`
- `minio` (S3 API)
- `pandas`
- `pyarrow` (for parquet support)