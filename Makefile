MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help/short
.DELETE_ON_ERROR:
.SUFFIXES:

# include makefiles
export SELF ?= $(MAKE)
PROJECT_PATH ?= $(shell pwd)
include $(PROJECT_PATH)/Makefile.*

REPO_NAME ?= $(shell basename $(CURDIR))

#-------------------------------------------------------------------------------
# Configurable Timeouts
#-------------------------------------------------------------------------------

WAIT_TIMEOUT_SHORT := 90s
WAIT_TIMEOUT_MEDIUM := 120s
WAIT_TIMEOUT_LONG := 180s

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------

## Check if required tools are installed
validate/tools:
	@echo "[INFO] Checking required tools..."
	@command -v docker >/dev/null 2>&1 || (echo "[ERROR] docker not found" && exit 1)
	@command -v kind >/dev/null 2>&1 || (echo "[ERROR] kind not found" && exit 1)
	@command -v kubectl >/dev/null 2>&1 || (echo "[ERROR] kubectl not found" && exit 1)
	@command -v helm >/dev/null 2>&1 || (echo "[ERROR] helm not found" && exit 1)
	@command -v mvn >/dev/null 2>&1 || (echo "[ERROR] maven not found" && exit 1)
	@echo "[INFO] All required tools found"
.PHONY: validate/tools

## Lint all Helm charts
validate/charts:
	@echo "[INFO] Linting Helm charts..."
	@helm lint ./charts/metrics-server || true
	@helm lint ./charts/prometheus || true
	@helm lint ./charts/grafana || true
	@helm lint ./charts/vertical-pod-autoscaler || true
	@helm lint ./charts/flink-autoscale || true
	@helm lint ./charts/minio || true
	@helm lint ./charts/kafka-load-producer || true
	@helm dependency build ./charts/kafka 2>/dev/null; helm lint ./charts/kafka || true
	@echo "[INFO] Chart validation complete"
.PHONY: validate/charts

#-------------------------------------------------------------------------------
# docker
#-------------------------------------------------------------------------------

DOCKER_USER ?= hansohn
DOCKER_REPO ?= flink-autoscaling-load
DOCKER_TAG_BASE ?= $(DOCKER_USER)/$(DOCKER_REPO)

FLINK_VERSION ?= 1.18-scala_2.12

GIT_BRANCH ?= $(shell git branch --show-current 2>/dev/null || echo 'unknown')
GIT_HASH := $(shell git rev-parse --short HEAD 2>/dev/null || echo 'pre')

APP_VERSION ?= 1.1.0

DOCKER_TAGS ?=
DOCKER_TAGS += --tag $(DOCKER_TAG_BASE):$(GIT_HASH)
DOCKER_TAGS += --tag $(DOCKER_TAG_BASE):$(APP_VERSION)
ifeq ($(GIT_BRANCH), main)
DOCKER_TAGS += --tag $(DOCKER_TAG_BASE):latest
endif

APP_DIR := services/autoscaling-load-job
DOCKER_BUILD_PATH ?= $(APP_DIR)

# Platform configuration - default to local platform for single-platform builds with --load
# For multi-platform builds, set DOCKER_PLATFORMS to "linux/amd64,linux/arm64"
DOCKER_LOCAL_PLATFORM ?= $(shell docker version --format '{{.Server.Os}}/{{.Server.Arch}}')
DOCKER_PLATFORMS ?= $(DOCKER_LOCAL_PLATFORM)
DOCKER_MULTI_PLATFORM := $(shell echo "$(DOCKER_PLATFORMS)" | grep -q ',' && echo true || echo false)

DOCKER_BUILD_ARGS ?=
DOCKER_BUILD_ARGS += --build-arg FLINK_VERSION=$(FLINK_VERSION)
DOCKER_BUILD_ARGS += --platform=$(DOCKER_PLATFORMS)
# Only add --load for single-platform builds (multi-platform builds require --push)
ifeq ($(DOCKER_MULTI_PLATFORM),false)
DOCKER_BUILD_ARGS += --load
endif
DOCKER_BUILD_ARGS += $(DOCKER_TAGS)

## Check if Docker daemon is running
docker/check:
	@docker info > /dev/null 2>&1 || (echo "[ERROR] Docker daemon is not running." && exit 1)
.PHONY: docker/check

## Build Docker image with JAR
docker/build: maven/build docker/check
	@echo "[INFO] Building '$(DOCKER_TAG_BASE)' docker image."
	@docker build $(DOCKER_BUILD_ARGS) $(DOCKER_BUILD_PATH)/
.PHONY: docker/build

## Clean docker build images
docker/clean: docker/check
	@if docker inspect --type=image "$(DOCKER_TAG_BASE):$(APP_VERSION)" > /dev/null 2>&1; then \
		echo "[INFO] Removing docker image '$(DOCKER_TAG_BASE)'"; \
		docker rmi -f $$(docker inspect --format='{{ .Id }}' --type=image $(DOCKER_TAG_BASE):$(GIT_HASH)); \
	fi
.PHONY: docker/clean

#-------------------------------------------------------------------------------
# docker (kafka-load-producer)
#-------------------------------------------------------------------------------

PRODUCER_DOCKER_REPO ?= kafka-load-producer
PRODUCER_DOCKER_TAG_BASE ?= $(DOCKER_USER)/$(PRODUCER_DOCKER_REPO)
PRODUCER_APP_VERSION ?= 1.0.0
PRODUCER_APP_DIR := services/kafka-load-producer

PRODUCER_DOCKER_TAGS ?=
PRODUCER_DOCKER_TAGS += --tag $(PRODUCER_DOCKER_TAG_BASE):$(GIT_HASH)
PRODUCER_DOCKER_TAGS += --tag $(PRODUCER_DOCKER_TAG_BASE):$(PRODUCER_APP_VERSION)
ifeq ($(GIT_BRANCH), main)
PRODUCER_DOCKER_TAGS += --tag $(PRODUCER_DOCKER_TAG_BASE):latest
endif

PRODUCER_DOCKER_BUILD_ARGS ?=
PRODUCER_DOCKER_BUILD_ARGS += --platform=$(DOCKER_PLATFORMS)
ifeq ($(DOCKER_MULTI_PLATFORM),false)
PRODUCER_DOCKER_BUILD_ARGS += --load
endif
PRODUCER_DOCKER_BUILD_ARGS += $(PRODUCER_DOCKER_TAGS)

## Build Kafka Load Producer Docker image
docker/build-producer: maven/build-producer docker/check
	@echo "[INFO] Building '$(PRODUCER_DOCKER_TAG_BASE)' docker image."
	@docker build $(PRODUCER_DOCKER_BUILD_ARGS) $(PRODUCER_APP_DIR)/
.PHONY: docker/build-producer

## Clean Kafka Load Producer docker images
docker/clean-producer: docker/check
	@if docker inspect --type=image "$(PRODUCER_DOCKER_TAG_BASE):$(PRODUCER_APP_VERSION)" > /dev/null 2>&1; then \
		echo "[INFO] Removing docker image '$(PRODUCER_DOCKER_TAG_BASE)'"; \
		docker rmi -f $$(docker inspect --format='{{ .Id }}' --type=image $(PRODUCER_DOCKER_TAG_BASE):$(GIT_HASH)); \
	fi
.PHONY: docker/clean-producer

#-------------------------------------------------------------------------------
# kind
#-------------------------------------------------------------------------------

# kind
CLUSTER_NAME := flink-playground
KIND_CONFIG := kind/config.yaml
KUBE_CONTEXT := kind-$(CLUSTER_NAME)

# kubectl
KUBECONFIG ?= $(HOME)/.kube/config
KUBECTL := KUBECONFIG=$(KUBECONFIG) kubectl --context $(KUBE_CONTEXT)
HELM := KUBECONFIG=$(KUBECONFIG) helm --kube-context $(KUBE_CONTEXT)

## Check if Kind cluster exists (fails if not)
kind/check:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Kind cluster '$(CLUSTER_NAME)' does not exist. Run 'make up' first."; \
		exit 1; \
	fi
.PHONY: kind/check

## Create Kind cluster if it doesn't exist
kind/up: docker/check
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[INFO] Creating Kind cluster '$(CLUSTER_NAME)'"; \
		if [ ! -f $(KIND_CONFIG) ]; then \
			echo "[ERROR] Kind config not found: $(KIND_CONFIG)"; \
			exit 1; \
		fi; \
		kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG); \
		echo "[INFO] Waiting for Kind cluster '$(CLUSTER_NAME)' Ready state"; \
		$(KUBECTL) wait --for=condition=Ready nodes --all --timeout=$(WAIT_TIMEOUT_SHORT); \
	else \
		echo "[INFO] Kind cluster '$(CLUSTER_NAME)' already exists"; \
	fi
.PHONY: kind/up

## Delete Kind cluster if it exists
kind/down: docker/check
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[INFO] Deleting Kind cluster: $(CLUSTER_NAME)"; \
		kind delete cluster --name $(CLUSTER_NAME); \
	else \
		echo "[INFO] Kind cluster '$(CLUSTER_NAME)' does not exist"; \
	fi
.PHONY: kind/down

## Load Docker image into Kind cluster
kind/load: kind/check
	@if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^$(DOCKER_TAG_BASE):$(APP_VERSION)$$"; then \
		echo "[INFO] Image $(DOCKER_TAG_BASE) not found locally, building..."; \
		$(MAKE) docker/build; \
	fi
	@echo "[INFO] Loading Docker image into Kind cluster: $(CLUSTER_NAME)"
	@kind load docker-image $(DOCKER_TAG_BASE):$(APP_VERSION) --name $(CLUSTER_NAME)
	@kind load docker-image $(PRODUCER_DOCKER_TAG_BASE):$(PRODUCER_APP_VERSION) --name $(CLUSTER_NAME)
.PHONY: kind/load

## Check if cluster is running and healthy
kind/status: kind/check
	@echo "[INFO] Kind cluster '$(CLUSTER_NAME)' is running"
	@$(KUBECTL) cluster-info
.PHONY: kind/status

#-------------------------------------------------------------------------------
# ArgoCD
#-------------------------------------------------------------------------------

ARGOCD_NAMESPACE := argocd
ARGOCD_VERSION := v2.13.3

## Install ArgoCD (idempotent)
argocd/install: kind/up
	@if ! $(KUBECTL) get namespace $(ARGOCD_NAMESPACE) > /dev/null 2>&1; then \
		echo "[INFO] Installing ArgoCD $(ARGOCD_VERSION)"; \
		$(KUBECTL) create namespace $(ARGOCD_NAMESPACE); \
		$(KUBECTL) apply -n $(ARGOCD_NAMESPACE) -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml; \
		echo "[INFO] Waiting for ArgoCD to be ready..."; \
		$(KUBECTL) wait --for=condition=Available --timeout=$(WAIT_TIMEOUT_LONG) -n $(ARGOCD_NAMESPACE) deployment/argocd-server 2>/dev/null || true; \
		$(KUBECTL) wait --for=condition=Available --timeout=$(WAIT_TIMEOUT_LONG) -n $(ARGOCD_NAMESPACE) deployment/argocd-repo-server 2>/dev/null || true; \
		$(KUBECTL) wait --for=condition=Available --timeout=$(WAIT_TIMEOUT_LONG) -n $(ARGOCD_NAMESPACE) deployment/argocd-applicationset-controller 2>/dev/null || true; \
		echo "[INFO] ArgoCD installed successfully"; \
	else \
		echo "[INFO] ArgoCD already installed"; \
	fi
.PHONY: argocd/install

## Uninstall ArgoCD
argocd/clean:
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		if $(KUBECTL) get namespace $(ARGOCD_NAMESPACE) > /dev/null 2>&1; then \
			echo "[INFO] Uninstalling ArgoCD"; \
			$(KUBECTL) delete -n $(ARGOCD_NAMESPACE) -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml 2>/dev/null || true; \
			$(KUBECTL) delete namespace $(ARGOCD_NAMESPACE) 2>/dev/null || true; \
		else \
			echo "[INFO] ArgoCD not installed"; \
		fi \
	else \
		echo "[INFO] Cluster does not exist, skipping uninstall"; \
	fi
.PHONY: argocd/clean

## Get ArgoCD admin password
argocd/password: kind/check
	@echo "[INFO] ArgoCD admin password:"
	@$(KUBECTL) -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
.PHONY: argocd/password

## Deploy all applications via ArgoCD
argocd/deploy: argocd/install
	@echo "[INFO] Deploying applications via ArgoCD"
	@$(KUBECTL) apply -f argocd/apps/
	@echo "[INFO] Applications deployed. Check status with: make argocd/status"
.PHONY: argocd/deploy

## Show ArgoCD application status
argocd/status: kind/check
	@echo "=== ArgoCD Applications ==="
	@$(KUBECTL) get applications -n $(ARGOCD_NAMESPACE) 2>/dev/null || echo "No applications found"
.PHONY: argocd/status

#-------------------------------------------------------------------------------
# Prometheus
#-------------------------------------------------------------------------------
# Managed by ArgoCD - see argocd/apps/prometheus.yaml

PROMETHEUS_NAMESPACE := monitoring
PROMETHEUS_SERVICE := prometheus-prometheus
GRAFANA_NAMESPACE := monitoring
GRAFANA_SERVICE := grafana

#-------------------------------------------------------------------------------
# Flink
#-------------------------------------------------------------------------------
# Managed by ArgoCD - see argocd/apps/flink-autoscale.yaml

FLINK_RELEASE := flink-autoscale
FLINK_NAMESPACE := playground
FLINK_SERVICE := flink-autoscale-autoscaling-load-rest

APP_DIR := services/autoscaling-load-job
APP_JAR := $(APP_DIR)/target/autoscaling-load-job.jar

# -----------------------------
# Maven Build / Clean
# -----------------------------

MVN := cd $(APP_DIR) && mvn -q

## Build Autoscaling Load Job JAR
maven/build:
	@echo "[INFO] Building Autoscaling Load Job"
	@$(MVN) clean package
	@echo "[INFO] Build complete: $(APP_JAR)"
.PHONY: maven/build

## Build Kafka Load Producer JAR
maven/build-producer:
	@echo "[INFO] Building Kafka Load Producer"
	@cd $(PRODUCER_APP_DIR) && mvn -q clean package
	@echo "[INFO] Build complete: $(PRODUCER_APP_DIR)/target/kafka-load-producer.jar"
.PHONY: maven/build-producer

## Clean Maven project artifacts
maven/clean:
	@echo "[INFO] Cleaning Maven project"
	@$(MVN) clean
	@echo "[INFO] Cleaned: $(APP_DIR)/target"
.PHONY: maven/clean

# -----------------------------
# Full bootstrap (one command)
# -----------------------------

## Bootstrap entire environment using ArgoCD (cluster + ArgoCD + all components)
up: kind/up argocd/install argocd/deploy
	@echo ""
	@echo "=== Environment Ready ==="
	@echo "UIs:           make ui (ArgoCD :8080, Flink :8081, Prometheus :9090, Grafana :3000)"
	@echo "Cluster:       kind get clusters"
	@echo "ArgoCD Apps:   make argocd/status"
	@echo ""
.PHONY: up

## Port forward all UIs (ArgoCD :8080, Flink :8081, Prometheus :9090, Grafana :3000)
ui: kind/check
	@echo "[INFO] Starting all port forwards..."
	@echo "[INFO] ArgoCD:     http://localhost:8080"
	@echo "[INFO] Flink:      http://localhost:8081"
	@echo "[INFO] Prometheus: http://localhost:9090"
	@echo "[INFO] Grafana:    http://localhost:3000"
	@echo "[INFO] Press Ctrl+C to stop all"
	@trap 'kill 0' EXIT; \
		$(KUBECTL) port-forward -n $(ARGOCD_NAMESPACE) svc/argocd-server 8080:443 & \
		$(KUBECTL) port-forward -n $(FLINK_NAMESPACE) svc/$(FLINK_SERVICE) 8081:8081 & \
		$(KUBECTL) port-forward -n $(PROMETHEUS_NAMESPACE) svc/$(PROMETHEUS_SERVICE) 9090:9090 & \
		$(KUBECTL) port-forward -n $(GRAFANA_NAMESPACE) svc/$(GRAFANA_SERVICE) 3000:80 & \
		wait
.PHONY: ui

# -----------------------------
# Load Testing
# -----------------------------

## Run memory load test (requires running cluster)
loadtest/memory: kind/check
	@echo "[INFO] Running memory load test..."
	@cd testing/load-tests && ./memory-load-test.sh
.PHONY: loadtest/memory

## Run memory load test with custom duration and parallelism
loadtest/memory/custom: kind/check
	@echo "[INFO] Running custom memory load test..."
	@echo "[INFO] Usage: make loadtest/memory/custom DURATION=600 PARALLELISM=20"
	@cd testing/load-tests && ./memory-load-test.sh \
		--duration $(or $(DURATION),300) \
		--parallelism $(or $(PARALLELISM),10) \
		--namespace $(FLINK_NAMESPACE) \
		--job $(FLINK_RELEASE)-autoscaling-load
.PHONY: loadtest/memory/custom

## Analyze load test results from Prometheus
loadtest/analyze: kind/check
	@echo "[INFO] Analyzing load test metrics from Prometheus..."
	@echo "[INFO] Make sure Prometheus is port-forwarded: make ui"
	@cd testing/load-tests && python3 analyze-metrics.py \
		--prometheus-url http://localhost:9090 \
		--duration $(or $(DURATION),300)
.PHONY: loadtest/analyze

## Install Python dependencies for load testing
loadtest/install-deps:
	@echo "[INFO] Installing Python dependencies for load testing..."
	@pip3 install -r testing/load-tests/requirements.txt
.PHONY: loadtest/install-deps

# -----------------------------
# Cleanup Helpers
# -----------------------------

## Clean all Maven artifacts
maven/clean-producer:
	@echo "[INFO] Cleaning Kafka Load Producer Maven project"
	@cd $(PRODUCER_APP_DIR) && mvn -q clean
	@echo "[INFO] Cleaned: $(PRODUCER_APP_DIR)/target"
.PHONY: maven/clean-producer

## Clean Maven artifacts and delete cluster
clean/all: maven/clean maven/clean-producer kind/down
	@echo "[INFO] All cleanup complete"
.PHONY: clean/all
