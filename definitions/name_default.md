# Docker ---------------------------------------------------------------------
DOCKER_CONTEXT=$(docker context inspect $(docker context show) --format '{{.Name }}')
DOCKER_HOST_NAME=$(docker info --format '{{.Name}}' | awk -F'.' '{print $$1}')
DOCKER_HOST_IP=$(docker info --format '{{.Swarm.NodeAddr}}')
DOCKER_HOST_FQDN=$(docker info --format '{{.Name}}')
# --------------------------------------------------------------------- Docker

# Shared Network Storage -----------------------------------------------------
NFS_DATA_PATH=/share/servicospi
# ----------------------------------------------------- Shared Network Storage

# Data Ingestion -------------------------------------------------------------
## PostgreSQL
POSTGRES_DB=postgres
POSTGRES_USER=
POSTGRES_PASS=

## Airflow
AIRFLOW_POSTGRES_HOSTNAME=postgres-airflow
AIRFLOW_POSTGRES_USERNAME=
AIRFLOW_POSTGRES_PASSWORD=
AIRFLOW_POSTGRES_DB=airflow
AIRFLOW__CORE__FERNET_KEY=
AIRFLOW_WWW_USERNAME=
AIRFLOW_WWW_PASSWORD=
AIRFLOW_ALCHEMY_CONN=
AIRFLOW_CELERY_RESULT_BACKEND=

## ImageDB
IMAGE_DB_HOSTNAME=postgres-images
### Marcas Image Database
MARCAS_IMAGE_DB_USERNAME=
MARCAS_IMAGE_DB_PASSWORD=
MARCAS_IMAGE_DB=marcas

## Banco de dados
HLINFORMIX01=172.20.2.6
RWORACLE01=172.19.0.136
ORACLE_MARCAS_IP=${RWORACLE01}
ORACLE_MARCAS_USERNAME=
ORACLE_MARCAS_PASSWORD=
ORACLE_MARCAS_JDBC_URL="jdbc:oracle:thin:@${ORACLE_MARCAS_IP}:1521:ORCL"
# ------------------------------------------------------------- Data Ingestion


# API Imagens -------------------------------------------------------------------
## API Settings
HOST_SERVER='0.0.0.0'
PORT_SERVER=5000
DEBUG_API=0
FRONTEND_URL="*"
#***************** PARAMETROS NOVOS *************************
PATENT_IMAGE_DIRECTORY="\\pwvdiprof01\UEMProfiles\raulivan.silva\workspace\imagens"
MEDUSA_USER=
MEDUSA_PASSWORD=
URL_SISTEMA_MEDUSA="http://arquivo-homologacao.inpi.gov.br:8080/medusa/imagens"
URL_SISTEMA_IPASWS="http://javahomologacao.inpi.gov.br:8080/ipas-ws/documento/di/figuras/processo"
DB_ORACLE_MARCAS_SERVER=${RWORACLE01}
DB_ORACLE_MARCAS_SERVER_PORT=1521
DB_ORACLE_MARCAS_DB_NAME=ORCL
DB_ORACLE_MARCAS_USER=
DB_ORACLE_MARCAS_PASSWORD=
DB_ORACLE_MARCAS_TYPE=SID
# ------------------------------------------------------------------- API Imagens