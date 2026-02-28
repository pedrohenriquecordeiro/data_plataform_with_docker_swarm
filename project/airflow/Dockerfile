# Dockerfile — Custom Apache Airflow image for the data platform
# Extends the official Airflow image with additional Python packages
# needed for data processing (pandas, polars, duckdb, minio, pyarrow).
# Build: docker build -t registry.local/data-platform/airflow:2.10.5 .
# TODO(user): push image to registry before deploying the stack

# Base image: official Apache Airflow with Python 3.12
FROM apache/airflow:2.10.5-python3.12

# Metadata labels for image identification and traceability
LABEL maintainer="data-platform-team"
LABEL version="2.10.5"
LABEL build-date="2025-02-22"

# --- Airflow UI and behavior configuration ---
# Enable connection testing from the Airflow UI
ENV AIRFLOW__CORE__TEST_CONNECTION=Enabled
# Set DAG graph orientation to top-to-bottom for better readability
ENV AIRFLOW__WEBSERVER__DAG_ORIENTATION=TB
# Show full Python stack traces in the UI for easier debugging
ENV AIRFLOW__WEBSERVER__EXPOSE_STACKTRACE=True
# Expose Airflow configuration page in the web UI
ENV AIRFLOW__WEBSERVER__EXPOSE_CONFIG=True
# Enable text wrapping in the web UI for long values
ENV AIRFLOW__WEBSERVER__DEFAULT_WRAP=True

# Install additional Python packages required for data processing tasks.
# Uses Airflow's official constraints file to ensure package compatibility.
# --no-cache-dir reduces image size by not caching pip downloads.
# All packages are installed in a single RUN layer to minimize image layers.
RUN pip install --no-cache-dir \
    --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-2.10.5/constraints-3.12.txt" \
    pandas \
    polars \
    duckdb \
    minio \
    pyarrow

# Final image runs as the 'airflow' user (inherited from base image — do not switch to root)
