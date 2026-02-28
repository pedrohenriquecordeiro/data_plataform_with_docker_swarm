# Data Platform

Welcome to the Data Platform project. This repository contains the complete codebase for an on-premise data platform running **MinIO** (object storage) and **Apache Airflow** (workflow orchestration) on **Docker Swarm**, along with sample data engineering pipelines demonstrating modern data architectures.

## Project Structure

The project is divided into two main areas:

1. **Infrastructure (`infra/`)**
   Contains all configuration files and deployment scripts required to provision the self-hosted platform:
   - **Docker Swarm configurations** for Apache Airflow and MinIO.
   - **Deployment scripts** to setup host environments, build Airflow images and deploy stacks.
   - Detailed **documentation** (`infra/docs/`) on architecture, deployment and platform maintenance.
   - ➜ *For setup instructions, head over to [infra/readme.md](infra/readme.md).*

2. **Code (`code/`)**
   Contains the data engineering codebase, specifically Airflow DAGs that execute within the platform:
   - Example pipelines such as a 3-layer data framework (Bronze -> Silver -> Gold).
   - Demonstrations of in-memory data processing using Pandas and S3 integration via MinIO.
   - ➜ *Explore the DAGs inside [code/dags/](code/dags/).*

## Overview

The platform is designed to provide a cohesive data environment with:
- **Scalable Object Storage:** S3 compatibility through MinIO.
- **Robust Orchestration:** Scheduling and task orchestration using Apache Airflow (backed by Celery workers, Redis and PostgreSQL).
- **Extensibility:** A clear separation between infrastructure management and data pipeline engineering, enabling teams to independently update deployment strategies or pipeline code.

## Getting Started

To get the platform up and running on your Docker Swarm cluster:
1. Navigate to the `infra/` folder.
2. Follow the detailed steps outlined in the [Deployment Guide](infra/docs/deployment_guide.md) to bootstrap the environment.
3. Once the orchestrator is deployed, Airflow will automatically discover the pipelines maintained inside `code/dags/`.

## Documentation

- **[Infrastructure Overview & Setup](infra/readme.md)**
- **[Architecture Details](infra/docs/architecture.md)**
- **[Deployment Guide](infra/docs/deployment_guide.md)**
- **[Maintenance & Operations](infra/docs/maintenance_guide.md)**
