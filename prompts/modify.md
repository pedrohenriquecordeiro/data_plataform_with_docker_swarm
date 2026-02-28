# task

1) move the project/tests/test_stack.sh to project/scripts and update the reference in all files of project that reference it.

2) change the path /opt/data-plataform/ to /opt/data-platform/ in all files of project that reference it.

3) make all shell scripts be in project/scripts and modify all files of project that reference them.
    - project/minio/scripts and project/airflow/scripts must not exist after this task.

4) write a simple readme.md in root of project that explain the project and how to use it.

5) in docs create a new markdown to explain the project/scripts/teardown.sh

6) reorganize the project/.env.example to make minio and airflow variables separated.

7) write a new deploy.sh to deploy all components of the project.
    - calling the other scripts in the correct order.

8) upgrade the project/docs/operations_runbook.md to be more comprehensive and give more context about the project

