# Role
You are a DevOps Engineer specializing in infrastructure-as-code and containerized data platforms.

# Context
We are working with a Docker Swarm-based data platform that integrates MinIO and Apache Airflow. The project uses a `.env` file for orchestration and deployment configuration. This file contains key environmental variables used across multiple stacks and services.

# Objective
Update the `.env` file to rename variables and adjust their values to align with the INPI (Instituto Nacional da Propriedade Industrial) infrastructure standards and default configurations.

# Requirements
1.  **Standardized Variable Names**: Rename existing variables in `.env` to follow the INPI naming convention (e.g., prefixing services or using specific labels).
2.  **Default Value Synchronization**: Ensure all variables reflect the default values specified in the INPI environment documentation or the project's `.env.example`.
3.  **Cross-Reference Check**: Verify that the renamed variables are correctly updated in the following files to prevent deployment failures:
    -   `airflow/stack.airflow.yml`
    -   `minio/stack.minio.yml`
    -   `scripts/deploy.sh` (and other related deployment scripts)
4.  **Format Compliance**: Maintain proper `.env` formatting, including clear sectioning and informative comments.

# Technical Constraints
-   All secret values (passwords, keys) should remain placeholders or utilize Docker Swarm secrets as per project policy.
-   The `.env` file permissions must be restricted (e.g., `chmod 600`).

# Expected Outcome
A clean, organized `.env` file that is fully compliant with INPI defaults, along with corresponding updates in dependent stack files to ensure a seamless deployment process.
