.PHONY: help setup-ecr build-and-push deploy destroy clean validate logs status rebuild

# Load environment variables from .env file if it exists
-include .env
export

# AWS Configuration
AWS_REGION ?= $(shell aws configure get region)
AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text)
ECR_BASE_URI = $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

# Docker Images Configuration (source images to pull)
LANGFUSE_WEB_SOURCE = langfuse/langfuse:3
LANGFUSE_WORKER_SOURCE = langfuse/langfuse-worker:3
CLICKHOUSE_SOURCE = clickhouse/clickhouse-server:24.12.3.47

# ECR Repository Names
LANGFUSE_WEB_REPO = langfuse-web
LANGFUSE_WORKER_REPO = langfuse-worker
CLICKHOUSE_REPO = clickhouse

# Image version tag (timestamp-based for unique deployments)
# Saved to .image-tag file to maintain consistency between build and deploy
IMAGE_TAG_FILE = .image-tag

# Read existing tag from file, or will be generated in build-and-push target
ifneq (,$(wildcard $(IMAGE_TAG_FILE)))
IMAGE_TAG := $(shell cat $(IMAGE_TAG_FILE))
else
IMAGE_TAG ?= $(shell date +%Y%m%d-%H%M%S)
endif

# ECR Full URIs with version tags
LANGFUSE_WEB_URI = $(ECR_BASE_URI)/$(LANGFUSE_WEB_REPO):$(IMAGE_TAG)
LANGFUSE_WORKER_URI = $(ECR_BASE_URI)/$(LANGFUSE_WORKER_REPO):$(IMAGE_TAG)
CLICKHOUSE_URI = $(ECR_BASE_URI)/$(CLICKHOUSE_REPO):$(IMAGE_TAG)

# SAM Configuration
STACK_NAME ?= langfuse-v3
SAM_TEMPLATE = template.yaml
PARAMETERS_FILE = parameters.json

# Platform for Docker build (Mac M1/M2 needs to build for linux/amd64 or linux/arm64)
DOCKER_PLATFORM = linux/amd64

# Colors for output
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[1;33m
BLUE = \033[0;34m
NC = \033[0m # No Color

help:
	@echo "$(BLUE)Langfuse V3 AWS SAM Deployment Makefile$(NC)"
	@echo ""
	@echo "$(GREEN)Available targets:$(NC)"
	@echo "  $(YELLOW)setup-ecr$(NC)         - Create ECR repositories if they don't exist"
	@echo "  $(YELLOW)build-and-push$(NC)    - Build all Docker images and push to ECR"
	@echo "  $(YELLOW)rebuild$(NC)           - Clean and rebuild with new image tag"
	@echo "  $(YELLOW)deploy$(NC)            - Deploy infrastructure using SAM"
	@echo "  $(YELLOW)destroy$(NC)           - Delete the CloudFormation stack"
	@echo "  $(YELLOW)validate$(NC)          - Validate SAM template"
	@echo "  $(YELLOW)status$(NC)            - Show stack status and outputs"
	@echo "  $(YELLOW)show-image-tag$(NC)    - Show current image tag from last build"
	@echo "  $(YELLOW)logs$(NC)              - Tail logs for all services"
	@echo "  $(YELLOW)clean$(NC)             - Clean up local build artifacts"
	@echo ""
	@echo "$(GREEN)Quick Start:$(NC)"
	@echo "  1. Generate secrets: $(YELLOW)make generate-secrets$(NC)"
	@echo "  2. Update parameters.json with your values"
	@echo "  3. Run: $(YELLOW)make build-and-push$(NC)"
	@echo "  4. Run: $(YELLOW)make deploy$(NC)"
	@echo ""
	@echo "$(GREEN)Environment:$(NC)"
	@echo "  AWS_REGION:     $(AWS_REGION)"
	@echo "  AWS_ACCOUNT_ID: $(AWS_ACCOUNT_ID)"
	@echo "  ECR_BASE_URI:   $(ECR_BASE_URI)"
	@echo "  STACK_NAME:     $(STACK_NAME)"
	@echo "  IMAGE_TAG:      $(IMAGE_TAG)"
	@echo ""
	@echo "$(GREEN)Tip:$(NC) Override image tag with: $(YELLOW)IMAGE_TAG=v1.2.3 make build-and-push$(NC)"

check-env:
	@echo "$(BLUE)Checking environment...$(NC)"
	@if [ -z "$(AWS_REGION)" ]; then \
		echo "$(RED)Error: AWS_REGION is not set$(NC)"; \
		exit 1; \
	fi
	@if [ -z "$(AWS_ACCOUNT_ID)" ]; then \
		echo "$(RED)Error: Could not get AWS Account ID. Are you logged in?$(NC)"; \
		exit 1; \
	fi
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "$(RED)Error: docker is not installed$(NC)"; \
		exit 1; \
	fi
	@if ! command -v sam >/dev/null 2>&1; then \
		echo "$(RED)Error: AWS SAM CLI is not installed$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ Environment check passed$(NC)"

ecr-login: check-env
	@echo "$(BLUE)Logging in to ECR...$(NC)"
	@aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(ECR_BASE_URI)
	@echo "$(GREEN)✓ Logged in to ECR$(NC)"

create-repo-if-missing:
	@REPO_NAME=$(REPO); \
	echo "$(BLUE)Checking if ECR repository '$$REPO_NAME' exists...$(NC)"; \
	if ! aws ecr describe-repositories --repository-names $$REPO_NAME --region $(AWS_REGION) >/dev/null 2>&1; then \
		echo "$(YELLOW)Creating ECR repository: $$REPO_NAME$(NC)"; \
		aws ecr create-repository \
			--repository-name $$REPO_NAME \
			--region $(AWS_REGION) \
			--image-scanning-configuration scanOnPush=true \
			--encryption-configuration encryptionType=AES256 \
			--tags Key=Project,Value=langfuse Key=ManagedBy,Value=Makefile; \
		echo "$(GREEN)✓ Created repository: $$REPO_NAME$(NC)"; \
		aws ecr put-lifecycle-policy \
			--repository-name $$REPO_NAME \
			--region $(AWS_REGION) \
			--lifecycle-policy-text '{"rules":[{"rulePriority":1,"description":"Delete untagged images after 7 days","selection":{"tagStatus":"untagged","countType":"sinceImagePushed","countUnit":"days","countNumber":7},"action":{"type":"expire"}},{"rulePriority":2,"description":"Keep last 3 images","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":3},"action":{"type":"expire"}}]}'; \
		echo "$(GREEN)✓ Applied lifecycle policy to $$REPO_NAME$(NC)"; \
	else \
		echo "$(GREEN)✓ Repository $$REPO_NAME already exists$(NC)"; \
	fi

setup-ecr: check-env ecr-login
	@echo "$(BLUE)Setting up ECR repositories...$(NC)"
	@$(MAKE) create-repo-if-missing REPO=$(LANGFUSE_WEB_REPO)
	@$(MAKE) create-repo-if-missing REPO=$(LANGFUSE_WORKER_REPO)
	@$(MAKE) create-repo-if-missing REPO=$(CLICKHOUSE_REPO)
	@echo "$(GREEN)✓ All ECR repositories are ready$(NC)"

build-and-push: setup-ecr
	@echo "$(BLUE)╔════════════════════════════════════════════════════════════════╗$(NC)"
	@echo "$(BLUE)║  Building and Pushing Docker Images to ECR                    ║$(NC)"
	@echo "$(BLUE)╚════════════════════════════════════════════════════════════════╝$(NC)"
	@echo ""
	@TAG=$${IMAGE_TAG:-$$(date +%Y%m%d-%H%M%S)}; \
	echo "$(YELLOW)Build Configuration:$(NC)"; \
	echo "  Platform:     $(DOCKER_PLATFORM)"; \
	echo "  Image Tag:    $$TAG $(GREEN)(versioned for deployment tracking)$(NC)"; \
	echo ""; \
	echo "$(BLUE)Saving tag to $(IMAGE_TAG_FILE) for use in 'make deploy'...$(NC)"; \
	echo "$$TAG" > $(IMAGE_TAG_FILE); \
	echo ""; \
	\
	WEB_URI="$(ECR_BASE_URI)/$(LANGFUSE_WEB_REPO):$$TAG"; \
	WORKER_URI="$(ECR_BASE_URI)/$(LANGFUSE_WORKER_REPO):$$TAG"; \
	CLICKHOUSE_URI="$(ECR_BASE_URI)/$(CLICKHOUSE_REPO):$$TAG"; \
	\
	echo "$(BLUE)[1/3] Processing Langfuse Web image...$(NC)"; \
	echo "  Pulling:  $(LANGFUSE_WEB_SOURCE)"; \
	echo "  Tagging:  $$TAG + latest"; \
	echo "  Pushing to ECR..."; \
	docker pull --platform $(DOCKER_PLATFORM) $(LANGFUSE_WEB_SOURCE); \
	docker tag $(LANGFUSE_WEB_SOURCE) $$WEB_URI; \
	docker tag $(LANGFUSE_WEB_SOURCE) $(ECR_BASE_URI)/$(LANGFUSE_WEB_REPO):latest; \
	docker push $$WEB_URI; \
	docker push $(ECR_BASE_URI)/$(LANGFUSE_WEB_REPO):latest; \
	echo "$(GREEN)  ✓ Pushed: $$WEB_URI$(NC)"; \
	echo "$(GREEN)  ✓ Pushed: $(ECR_BASE_URI)/$(LANGFUSE_WEB_REPO):latest$(NC)"; \
	echo ""; \
	\
	echo "$(BLUE)[2/3] Processing Langfuse Worker image...$(NC)"; \
	echo "  Pulling:  $(LANGFUSE_WORKER_SOURCE)"; \
	echo "  Tagging:  $$TAG + latest"; \
	echo "  Pushing to ECR..."; \
	docker pull --platform $(DOCKER_PLATFORM) $(LANGFUSE_WORKER_SOURCE); \
	docker tag $(LANGFUSE_WORKER_SOURCE) $$WORKER_URI; \
	docker tag $(LANGFUSE_WORKER_SOURCE) $(ECR_BASE_URI)/$(LANGFUSE_WORKER_REPO):latest; \
	docker push $$WORKER_URI; \
	docker push $(ECR_BASE_URI)/$(LANGFUSE_WORKER_REPO):latest; \
	echo "$(GREEN)  ✓ Pushed: $$WORKER_URI$(NC)"; \
	echo "$(GREEN)  ✓ Pushed: $(ECR_BASE_URI)/$(LANGFUSE_WORKER_REPO):latest$(NC)"; \
	echo ""; \
	\
	echo "$(BLUE)[3/3] Processing Clickhouse image...$(NC)"; \
	echo "  Pulling:  $(CLICKHOUSE_SOURCE)"; \
	echo "  Tagging:  $$TAG + latest"; \
	echo "  Pushing to ECR..."; \
	docker pull --platform $(DOCKER_PLATFORM) $(CLICKHOUSE_SOURCE); \
	docker tag $(CLICKHOUSE_SOURCE) $$CLICKHOUSE_URI; \
	docker tag $(CLICKHOUSE_SOURCE) $(ECR_BASE_URI)/$(CLICKHOUSE_REPO):latest; \
	docker push $$CLICKHOUSE_URI; \
	docker push $(ECR_BASE_URI)/$(CLICKHOUSE_REPO):latest; \
	echo "$(GREEN)  ✓ Pushed: $$CLICKHOUSE_URI$(NC)"; \
	echo "$(GREEN)  ✓ Pushed: $(ECR_BASE_URI)/$(CLICKHOUSE_REPO):latest$(NC)"; \
	echo ""; \
	\
	echo "$(BLUE)╔════════════════════════════════════════════════════════════════╗$(NC)"; \
	echo "$(BLUE)║  $(GREEN)✓ All Images Successfully Pushed to ECR$(BLUE)                     ║$(NC)"; \
	echo "$(BLUE)╚════════════════════════════════════════════════════════════════╝$(NC)"; \
	echo ""; \
	echo "$(YELLOW)Versioned Image URIs (saved to $(IMAGE_TAG_FILE)):$(NC)"; \
	echo "  $$WEB_URI"; \
	echo "  $$WORKER_URI"; \
	echo "  $$CLICKHOUSE_URI"; \
	echo ""; \
	echo "$(BLUE)Why two tags per image?$(NC)"; \
	echo "  $(GREEN):$$TAG$(NC) - Versioned tag for deployment (forces ECS to pull new images)"; \
	echo "  $(GREEN):latest$(NC)      - Reference tag for local development"; \
	echo ""; \
	echo "$(YELLOW)Next Step:$(NC)"; \
	echo "  Run $(GREEN)make deploy$(NC) to update parameters.json with versioned URIs"; \
	echo "  and deploy the infrastructure to AWS"

update-parameters:
	@echo "$(BLUE)╔════════════════════════════════════════════════════════════════╗$(NC)"
	@echo "$(BLUE)║  Updating parameters.json with Versioned Image URIs           ║$(NC)"
	@echo "$(BLUE)╚════════════════════════════════════════════════════════════════╝$(NC)"
	@echo ""
	@if [ ! -f "$(IMAGE_TAG_FILE)" ]; then \
		echo "$(RED)Error: $(IMAGE_TAG_FILE) not found!$(NC)"; \
		echo "$(YELLOW)Please run 'make build-and-push' first to build and tag images.$(NC)"; \
		exit 1; \
	fi
	@echo "$(YELLOW)Image tag from $(IMAGE_TAG_FILE): $(IMAGE_TAG)$(NC)"
	@echo ""
	@if [ ! -f "$(PARAMETERS_FILE)" ]; then \
		echo "$(RED)Error: $(PARAMETERS_FILE) not found$(NC)"; \
		exit 1; \
	fi
	@if command -v jq >/dev/null 2>&1; then \
		echo "$(BLUE)Updating parameters with versioned URIs...$(NC)"; \
		jq --arg web "$(LANGFUSE_WEB_URI)" \
		   --arg worker "$(LANGFUSE_WORKER_URI)" \
		   --arg clickhouse "$(CLICKHOUSE_URI)" \
		   '(.[] | select(.ParameterKey == "LangfuseWebImageUri") | .ParameterValue) |= $$web | \
		    (.[] | select(.ParameterKey == "LangfuseWorkerImageUri") | .ParameterValue) |= $$worker | \
		    (.[] | select(.ParameterKey == "ClickhouseImageUri") | .ParameterValue) |= $$clickhouse' \
		   $(PARAMETERS_FILE) > $(PARAMETERS_FILE).tmp && \
		mv $(PARAMETERS_FILE).tmp $(PARAMETERS_FILE); \
		echo "$(GREEN)✓ Updated $(PARAMETERS_FILE) with:$(NC)"; \
		echo "  LangfuseWebImageUri:    $(LANGFUSE_WEB_URI)"; \
		echo "  LangfuseWorkerImageUri: $(LANGFUSE_WORKER_URI)"; \
		echo "  ClickhouseImageUri:     $(CLICKHOUSE_URI)"; \
	else \
		echo "$(RED)Error: jq is required for automatic parameter updates$(NC)"; \
		echo "$(YELLOW)Install jq: brew install jq (macOS) or apt-get install jq (Linux)$(NC)"; \
		echo ""; \
		echo "$(YELLOW)Or manually update $(PARAMETERS_FILE) with:$(NC)"; \
		echo "  LangfuseWebImageUri:    $(LANGFUSE_WEB_URI)"; \
		echo "  LangfuseWorkerImageUri: $(LANGFUSE_WORKER_URI)"; \
		echo "  ClickhouseImageUri:     $(CLICKHOUSE_URI)"; \
		exit 1; \
	fi
	@echo ""

validate: check-env
	@echo "$(BLUE)Validating SAM template...$(NC)"
	@sam validate --template $(SAM_TEMPLATE) --lint
	@echo "$(GREEN)✓ Template is valid$(NC)"

deploy: check-env validate update-parameters
	@echo "$(BLUE)╔════════════════════════════════════════════════════════════════╗$(NC)"
	@echo "$(BLUE)║  Deploying Langfuse V3 Infrastructure                         ║$(NC)"
	@echo "$(BLUE)╚════════════════════════════════════════════════════════════════╝$(NC)"
	@echo ""
	@echo "$(YELLOW)Deployment Configuration:$(NC)"
	@echo "  Stack Name:  $(STACK_NAME)"
	@echo "  Region:      $(AWS_REGION)"
	@echo "  Image Tag:   $(IMAGE_TAG) $(GREEN)(versioned)$(NC)"
	@echo ""
	@if [ ! -f "$(PARAMETERS_FILE)" ]; then \
		echo "$(RED)Error: $(PARAMETERS_FILE) not found$(NC)"; \
		echo "$(YELLOW)Please create $(PARAMETERS_FILE) from the example$(NC)"; \
		exit 1; \
	fi
	@echo "$(YELLOW)Infrastructure to be deployed:$(NC)"
	@echo "  • VPC with 3 AZs (10.111.0.0/16)"
	@echo "  • Application Load Balancer (internet-facing)"
	@echo "  • Aurora PostgreSQL 15.4 (r6g.large writer + reader)"
	@echo "  • ElastiCache Valkey 7.2 (t3.small)"
	@echo "  • S3 Buckets (blob + event storage)"
	@echo "  • EFS for Clickhouse persistence"
	@echo "  • ECS Fargate Services:"
	@echo "    - Clickhouse (1 vCPU, 8GB RAM)"
	@echo "    - Langfuse Worker (2 vCPU, 4GB RAM)"
	@echo "    - Langfuse Web (2 vCPU, 4GB RAM)"
	@echo ""
	@echo "$(BLUE)Starting SAM deployment (this may take 25-35 minutes)...$(NC)"
	@echo ""
	sam deploy \
		--template-file $(SAM_TEMPLATE) \
		--stack-name $(STACK_NAME) \
		--parameter-overrides $$(cat $(PARAMETERS_FILE) | jq -r '.[] | "\(.ParameterKey)=\(.ParameterValue)"' | tr '\n' ' ') \
		--capabilities CAPABILITY_IAM \
		--region $(AWS_REGION) \
		--tags "Project=langfuse" \
		--no-fail-on-empty-changeset \
		--resolve-s3
	@echo ""
	@echo "$(BLUE)╔════════════════════════════════════════════════════════════════╗$(NC)"
	@echo "$(BLUE)║  $(GREEN)✓ Deployment Complete!$(BLUE)                                      ║$(NC)"
	@echo "$(BLUE)╚════════════════════════════════════════════════════════════════╝$(NC)"
	@echo ""
	@$(MAKE) status

status: check-env
	@echo "$(BLUE)Stack Status:$(NC)"
	@aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--query 'Stacks[0].StackStatus' \
		--output text 2>/dev/null || echo "Stack not found"
	@echo ""
	@echo "$(BLUE)Stack Outputs:$(NC)"
	@aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--query 'Stacks[0].Outputs' \
		--output table 2>/dev/null || echo "No outputs available"

logs:
	@echo "$(BLUE)Tailing logs for all services...$(NC)"
	@echo "$(YELLOW)Press Ctrl+C to stop$(NC)"
	@echo ""
	@echo "$(BLUE)Available log groups:$(NC)"
	@echo "  /ecs/clickhouse"
	@echo "  /ecs/langfuse-worker"
	@echo "  /ecs/langfuse-web"
	@echo ""
	@read -p "Enter log group to tail (e.g., /ecs/langfuse-web): " LOG_GROUP; \
	aws logs tail $$LOG_GROUP --follow --region $(AWS_REGION)

destroy: check-env
	@echo "$(RED)WARNING: This will delete the entire stack and all resources!$(NC)"
	@echo "$(YELLOW)Stack Name: $(STACK_NAME)$(NC)"
	@echo "$(YELLOW)Region:     $(AWS_REGION)$(NC)"
	@echo ""
	@read -p "Are you sure? Type 'yes' to continue: " CONFIRM; \
	if [ "$$CONFIRM" = "yes" ]; then \
		echo "$(BLUE)Deleting stack...$(NC)"; \
		aws cloudformation delete-stack \
			--stack-name $(STACK_NAME) \
			--region $(AWS_REGION); \
		echo "$(YELLOW)Waiting for stack deletion...$(NC)"; \
		aws cloudformation wait stack-delete-complete \
			--stack-name $(STACK_NAME) \
			--region $(AWS_REGION); \
		echo "$(GREEN)✓ Stack deleted$(NC)"; \
	else \
		echo "$(YELLOW)Deletion cancelled$(NC)"; \
	fi

clean:
	@echo "$(BLUE)Cleaning up local artifacts...$(NC)"
	@rm -rf .aws-sam
	@rm -f $(IMAGE_TAG_FILE)
	@echo "$(GREEN)✓ Cleaned up$(NC)"

# Helper targets
show-image-tag:
	@if [ -f $(IMAGE_TAG_FILE) ]; then \
		echo "$(GREEN)Current image tag: $$(cat $(IMAGE_TAG_FILE))$(NC)"; \
	else \
		echo "$(YELLOW)No image tag file found. Run 'make build-and-push' first.$(NC)"; \
	fi

get-alb-url:
	@aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerUrl`].OutputValue' \
		--output text

open-langfuse:
	@echo "$(BLUE)Opening Langfuse in browser...$(NC)"
	@URL=$$($(MAKE) -s get-alb-url); \
	if [ -z "$$URL" ]; then \
		echo "$(RED)Error: Could not get ALB URL. Is the stack deployed?$(NC)"; \
		exit 1; \
	fi; \
	echo "$(GREEN)Opening $$URL$(NC)"; \
	open "$$URL" 2>/dev/null || xdg-open "$$URL" 2>/dev/null || echo "Please open: $$URL"

tail-web-logs:
	@aws logs tail /ecs/langfuse-web --follow --region $(AWS_REGION)

tail-worker-logs:
	@aws logs tail /ecs/langfuse-worker --follow --region $(AWS_REGION)

tail-clickhouse-logs:
	@aws logs tail /ecs/clickhouse --follow --region $(AWS_REGION)

list-ecr-images:
	@echo "$(BLUE)ECR Images:$(NC)"
	@echo ""
	@echo "$(YELLOW)Langfuse Web:$(NC)"
	@aws ecr describe-images --repository-name $(LANGFUSE_WEB_REPO) --region $(AWS_REGION) --query 'reverse(sort_by(imageDetails,&imagePushedAt))[:5].[join(`,`,imageTags),imagePushedAt]' --output table 2>/dev/null || echo "No images found"
	@echo ""
	@echo "$(YELLOW)Langfuse Worker:$(NC)"
	@aws ecr describe-images --repository-name $(LANGFUSE_WORKER_REPO) --region $(AWS_REGION) --query 'reverse(sort_by(imageDetails,&imagePushedAt))[:5].[join(`,`,imageTags),imagePushedAt]' --output table 2>/dev/null || echo "No images found"
	@echo ""
	@echo "$(YELLOW)Clickhouse:$(NC)"
	@aws ecr describe-images --repository-name $(CLICKHOUSE_REPO) --region $(AWS_REGION) --query 'reverse(sort_by(imageDetails,&imagePushedAt))[:5].[join(`,`,imageTags),imagePushedAt]' --output table 2>/dev/null || echo "No images found"

# Generate secrets helper
generate-secrets:
	@echo "$(BLUE)Generating shared secrets for parameters.json...$(NC)"
	@echo ""
	@echo "$(YELLOW)LangfuseNextAuthSecret (for session validation):$(NC)"
	@openssl rand -base64 32
	@echo ""
	@echo "$(YELLOW)LangfuseSalt (shared by web + worker):$(NC)"
	@openssl rand -base64 32
	@echo ""
	@echo "$(YELLOW)LangfuseEncryptionKey (shared by web + worker):$(NC)"
	@openssl rand -hex 32
	@echo ""
	@echo "$(GREEN)✓ Generated 3 shared secrets$(NC)"
	@echo ""
	@echo "$(BLUE)IMPORTANT:$(NC) These secrets must be identical across all containers."
	@echo "Copy these values to the following parameters in parameters.json:"
	@echo "  - LangfuseNextAuthSecret"
	@echo "  - LangfuseSalt"
	@echo "  - LangfuseEncryptionKey"

# All-in-one deployment
deploy-all: build-and-push deploy
	@echo "$(GREEN)✓ Complete deployment finished!$(NC)"
	@echo ""
	@echo "$(BLUE)Access Langfuse at:$(NC)"
	@$(MAKE) -s get-alb-url

# Rebuild with fresh image tag
rebuild: clean build-and-push
	@echo ""
	@echo "$(GREEN)✓ Rebuild complete with new image tag!$(NC)"
	@echo ""
	@echo "$(YELLOW)Next Step:$(NC)"
	@echo "  Run $(GREEN)make deploy$(NC) to deploy the new images to AWS"
