# Data Platform - Docker Stack Management
# Usage: make <command>

# Colors for output
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m # No Color

.PHONY: help install deploy deploy-minio deploy-airflow status healthcheck test destroy clean build-airflow all
 
# Default target
help:
	@echo "$(GREEN)Data Platform Stack Management$(NC)"
	@echo ""
	@echo "$(YELLOW)Available commands:$(NC)"
	@echo "  make install       - Install dependencies (Docker, Swarm, host directories)"
	@echo "  make deploy        - Deploy all stacks (MinIO and Airflow)"
	@echo "  make build-airflow - Build local Airflow Docker image"
	@echo "  make status        - Check health of all services"
	@echo "  make destroy       - Remove all stacks and clean up"
	@echo "  make all           - Install, build, deploy and check status"
	@echo ""
	@echo "$(YELLOW)Individual stack commands:$(NC)"
	@echo "  make deploy-minio  - Deploy MinIO stack"
	@echo "  make deploy-airflow- Deploy Airflow stack"
	@echo ""
	@echo "$(YELLOW)Aliases:$(NC)"
	@echo "  make healthcheck   - Alias for 'make status'"
	@echo "  make clean         - Alias for 'make destroy'"

install:
	@echo "$(YELLOW)Installing dependencies...$(NC)"
	sudo bash scripts/install_dependencies.sh
 
build-airflow:
	@echo "$(YELLOW)Building Airflow image...$(NC)"
	@if [ ! -f .env ]; then \
		echo "Creating .env from .env.example..."; \
		cp .env.example .env && chmod 600 .env; \
	fi
	@AIRFLOW_IMAGE=$$(grep -E "^AIRFLOW_IMAGE=" .env | cut -d '=' -f2 | tr -d '"'\'' ' | tail -n 1 || echo "local/data-platform-airflow:2.10.5") && \
	docker build -t "$$AIRFLOW_IMAGE" airflow/
 
deploy:
	@echo "$(YELLOW)Deploying all stacks...$(NC)"
	sudo bash scripts/deploy_all.sh
 
deploy-minio:
	@echo "$(YELLOW)Deploying MinIO stack...$(NC)"
	@if [ ! -f .env ]; then \
		echo "Creating .env from .env.example..."; \
		cp .env.example .env && chmod 600 .env; \
	fi
	bash scripts/deploy_minio.sh
 
deploy-airflow: build-airflow
	@echo "$(YELLOW)Deploying Airflow stack...$(NC)"
	@if [ ! -f .env ]; then \
		echo "Creating .env from .env.example..."; \
		cp .env.example .env && chmod 600 .env; \
	fi
	bash scripts/deploy_airflow.sh
 
status:
	@echo "$(YELLOW)Checking service health...$(NC)"
	bash scripts/healthcheck.sh
 
healthcheck: status
 
test:
	@echo "$(YELLOW)Running integration tests...$(NC)"
	bash scripts/test_stack.sh
 
destroy:
	@echo "$(YELLOW)Destroying platform...$(NC)"
	sudo bash scripts/destroy.sh
 
clean: destroy
 
all: install deploy status
