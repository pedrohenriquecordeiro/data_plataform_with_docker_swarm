"""
minio_pipeline_dag.py — MinIO 3-Layer Data Pipeline DAG.

Simulates a Bronze -> Silver -> Gold data architecture using MinIO (S3) as the backend.
- Bronze: Raw generated JSON data.
- Silver: Refined CSV data with an added 'silver_id' column.
- Gold: Aggregated/Final Parquet data with an added 'gold_timestamp' column.
"""

import io
import logging
import uuid
from datetime import datetime

import pandas as pd
from airflow.decorators import dag, task
from airflow.providers.amazon.aws.hooks.s3 import S3Hook

# Configure module logger for task output
logger = logging.getLogger(__name__)

# ─────────────────────────────────────────────────────────────────────────────
# Configuration Constants
# ─────────────────────────────────────────────────────────────────────────────

TARGET_BUCKET = "init-bucket"
AWS_CONN_ID = "minio_default"

# ─────────────────────────────────────────────────────────────────────────────
# DAG Definition
# ─────────────────────────────────────────────────────────────────────────────

@dag(
    dag_id="minio_3_layer_pipeline",
    start_date=datetime(2024, 1, 1),
    schedule_interval=None,  # No schedule per requirements
    catchup=False,
    tags=["minio", "data-engineering", "bronze-silver-gold"],
    doc_md=__doc__,
)
def minio_pipeline():
    """
    Simulates a 3-layer data pipeline (Bronze -> Silver -> Gold) using MinIO.
    All data manipulation is done in-memory via pandas and io buffers.
    """

    @task
    def ingest_to_bronze() -> str:
        """
        Generate a random dataset using pandas and upload to the bronze layer in JSON format.
        
        Returns:
            str: The S3 key of the uploaded JSON file in the bronze layer.
        """
        logger.info("Starting ingest_to_bronze task")
        timestamp_str = datetime.now().strftime("%Y%m%d_%H%M%S")
        
        # 1. Generate random data (5 rows, 3 columns)
        data = {
            "id": list(range(1, 6)),
            "value": [round(x * 10.5, 2) for x in range(1, 6)],
            "category": ["A", "B", "A", "C", "B"]
        }
        df = pd.DataFrame(data)
        logger.info("Generated DataFrame with %d rows and %d columns.", len(df), len(df.columns))
        
        # 2. Convert to JSON using StringIO buffer
        json_buffer = io.StringIO()
        df.to_json(json_buffer, orient="records", lines=True)
        json_buffer.seek(0)
        
        # 3. Upload to MinIO
        s3_key = f"bronze/data_{timestamp_str}.json"
        
        s3_hook = S3Hook(aws_conn_id=AWS_CONN_ID)
        s3_hook.load_string(
            string_data=json_buffer.getvalue(),
            key=s3_key,
            bucket_name=TARGET_BUCKET,
            replace=True
        )
        
        logger.info("Successfully uploaded bronze data to s3://%s/%s", TARGET_BUCKET, s3_key)
        return s3_key

    @task
    def transform_to_silver(bronze_key: str) -> str:
        """
        Read the JSON file from the bronze layer, add a random silver_id,
        and save to the silver layer in CSV format.
        
        Args:
            bronze_key (str): The S3 key of the bronze JSON file.
            
        Returns:
            str: The S3 key of the uploaded CSV file in the silver layer.
        """
        logger.info("Starting transform_to_silver task with input key: %s", bronze_key)
        s3_hook = S3Hook(aws_conn_id=AWS_CONN_ID)
        
        # 1. Read from Bronze
        json_file_content = s3_hook.read_key(key=bronze_key, bucket_name=TARGET_BUCKET)
        df = pd.read_json(io.StringIO(json_file_content), orient="records", lines=True)
        logger.info("Read DataFrame with %d rows from bronze.", len(df))
        
        # 2. Transform: Add silver_id
        df["silver_id"] = [str(uuid.uuid4()) for _ in range(len(df))]
        
        # 3. Save to Silver (CSV)
        csv_buffer = io.StringIO()
        df.to_csv(csv_buffer, index=False)
        csv_buffer.seek(0)
        
        silver_key = bronze_key.replace("bronze/", "silver/").replace(".json", ".csv")
        
        s3_hook.load_string(
            string_data=csv_buffer.getvalue(),
            key=silver_key,
            bucket_name=TARGET_BUCKET,
            replace=True
        )
        
        logger.info("Successfully uploaded silver data to s3://%s/%s", TARGET_BUCKET, silver_key)
        return silver_key

    @task
    def transform_to_gold(silver_key: str) -> str:
        """
        Read the CSV file from the silver layer, add a gold_timestamp,
        and save to the gold layer in Parquet format.
        
        Args:
            silver_key (str): The S3 key of the silver CSV file.
            
        Returns:
            str: The S3 key of the uploaded Parquet file in the gold layer.
        """
        logger.info("Starting transform_to_gold task with input key: %s", silver_key)
        s3_hook = S3Hook(aws_conn_id=AWS_CONN_ID)
        
        # 1. Read from Silver
        csv_file_content = s3_hook.read_key(key=silver_key, bucket_name=TARGET_BUCKET)
        df = pd.read_csv(io.StringIO(csv_file_content))
        logger.info("Read DataFrame with %d rows from silver.", len(df))
        
        # 2. Transform: Add gold_timestamp
        df["gold_timestamp"] = datetime.now().isoformat()
        
        # 3. Save to Gold (Parquet)
        parquet_buffer = io.BytesIO()
        df.to_parquet(parquet_buffer, index=False, engine="pyarrow")
        parquet_buffer.seek(0)
        
        gold_key = silver_key.replace("silver/", "gold/").replace(".csv", ".parquet")
        
        # Note: load_bytes is used here since parquet is binary data
        s3_hook.load_bytes(
            bytes_data=parquet_buffer.getvalue(),
            key=gold_key,
            bucket_name=TARGET_BUCKET,
            replace=True
        )
        
        logger.info("Successfully uploaded gold data to s3://%s/%s", TARGET_BUCKET, gold_key)
        return gold_key

    # ─────────────────────────────────────────────────────────────────────────────
    # Task Dependencies Orchestration
    # ─────────────────────────────────────────────────────────────────────────────
    
    # TaskFlow API automatically resolves dependencies based on function arguments
    bronze_data_key = ingest_to_bronze()
    silver_data_key = transform_to_silver(bronze_data_key)
    transform_to_gold(silver_data_key)

# ─────────────────────────────────────────────────────────────────────────────
# DAG Instantiation
# ─────────────────────────────────────────────────────────────────────────────
dag_instance = minio_pipeline()
