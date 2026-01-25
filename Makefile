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
# docker
#-------------------------------------------------------------------------------

## Check if Docker daemon is running
docker/check:
	@docker info > /dev/null 2>&1 || (echo "[ERROR] Docker daemon is not running." && exit 1)
.PHONY: docker/check

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
	@helm lint ./charts/vertical-pod-autoscaler || true
	@helm lint ./charts/flink-autoscale || true
	@echo "[INFO] Chart validation complete"
.PHONY: validate/charts

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

## Create Kind cluster if it doesn't exist
cluster/up: docker/check
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
.PHONY: cluster/up

## Delete Kind cluster if it exists
cluster/down: docker/check
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[INFO] Deleting Kind cluster: $(CLUSTER_NAME)"; \
		kind delete cluster --name $(CLUSTER_NAME); \
	else \
		echo "[INFO] Kind cluster '$(CLUSTER_NAME)' does not exist"; \
	fi
.PHONY: cluster/down

## Check if Kind cluster exists (fails if not)
kind/check:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Cluster '$(CLUSTER_NAME)' does not exist. Run 'make up' first."; \
		exit 1; \
	fi
.PHONY: kind/check

## Check if cluster is running and healthy
cluster/status: kind/check
	@echo "[INFO] Cluster '$(CLUSTER_NAME)' is running"
	@$(KUBECTL) cluster-info
.PHONY: cluster/status

#-------------------------------------------------------------------------------
# Prometheus
#-------------------------------------------------------------------------------
# Managed by ArgoCD - see argocd/apps/prometheus.yaml

PROMETHEUS_NAMESPACE := monitoring
PROMETHEUS_RELEASE := prometheus-community

## Port forward to Prometheus UI (http://localhost:9090)
prometheus/ui: kind/check
	@echo "[INFO] Port forwarding to Prometheus UI at http://localhost:9090"
	@echo "[INFO] Press Ctrl+C to stop"
	@$(KUBECTL) port-forward -n $(PROMETHEUS_NAMESPACE) \
		svc/$(PROMETHEUS_RELEASE)-server 9090:9090
.PHONY: prometheus/ui

#-------------------------------------------------------------------------------
# ArgoCD
#-------------------------------------------------------------------------------

ARGOCD_NAMESPACE := argocd
ARGOCD_VERSION := v2.13.3

## Install ArgoCD (idempotent)
argocd/install: cluster/up
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
argocd/uninstall:
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
.PHONY: argocd/uninstall

## Get ArgoCD admin password
argocd/password: kind/check
	@echo "[INFO] ArgoCD admin password:"
	@$(KUBECTL) -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
.PHONY: argocd/password

## Port forward to ArgoCD UI (http://localhost:8080)
argocd/ui: kind/check
	@echo "[INFO] Port forwarding to ArgoCD UI at http://localhost:8080"
	@echo "[INFO] Username: admin"
	@echo "[INFO] Password: run 'make argocd/password' to get the password"
	@echo "[INFO] Press Ctrl+C to stop"
	@$(KUBECTL) port-forward -n $(ARGOCD_NAMESPACE) svc/argocd-server 8080:443
.PHONY: argocd/ui

## Deploy all applications via ArgoCD
argocd/deploy-apps: argocd/install
	@echo "[INFO] Deploying applications via ArgoCD"
	@$(KUBECTL) apply -f argocd/apps/
	@echo "[INFO] Applications deployed. Check status with: make argocd/status"
.PHONY: argocd/deploy-apps

## Show ArgoCD application status
argocd/status: kind/check
	@echo "=== ArgoCD Applications ==="
	@$(KUBECTL) get applications -n $(ARGOCD_NAMESPACE) 2>/dev/null || echo "No applications found"
.PHONY: argocd/status

#-------------------------------------------------------------------------------
# Flink
#-------------------------------------------------------------------------------
# Managed by ArgoCD - see argocd/apps/flink-autoscale.yaml

FLINK_RELEASE := flink-autoscale
FLINK_NAMESPACE := flink

APP_DIR := services/autoscaling-load-job
APP_POM := $(APP_DIR)/pom.xml
APP_JAR := $(APP_DIR)/target/autoscaling-load-job.jar

# -----------------------------
# Full bootstrap (one command)
# -----------------------------

## Bootstrap entire environment using ArgoCD (cluster + ArgoCD + all components)
up: cluster/up argocd/install argocd/deploy-apps
	@echo ""
	@echo "=== Environment Ready ==="
	@echo "ArgoCD UI:     make argocd/ui (then visit http://localhost:8080)"
	@echo "  Username:    admin"
	@echo "  Password:    make argocd/password"
	@echo "Flink UI:      make flink/ui (then visit http://localhost:8081)"
	@echo "Prometheus UI: make prometheus/ui (then visit http://localhost:9090)"
	@echo "Cluster:       kind get clusters"
	@echo "Status:        make status"
	@echo "ArgoCD Apps:   make argocd/status"
	@echo "Flink Status:  make status/flink"
	@echo ""
.PHONY: up

## Tear down entire environment (delete cluster)
down:
	@echo "[INFO] Tearing down environment..."
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[INFO] Deleting Kind cluster (this will remove all ArgoCD-managed apps)"; \
		$(MAKE) cluster/down; \
	else \
		echo "[INFO] Cluster does not exist, nothing to tear down"; \
	fi
	@echo "[INFO] Environment torn down"
.PHONY: down

## Restart entire environment (down + up)
restart: down up
.PHONY: restart

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

## Clean Maven project artifacts
maven/clean:
	@echo "[INFO] Cleaning Maven project"
	@$(MVN) clean
	@echo "[INFO] Cleaned: $(APP_DIR)/target"
.PHONY: maven/clean

## Build shaded JAR with shade plugin
maven/build-shaded:
	@echo "[INFO] Building Shaded JAR"
	@$(MVN) clean package -Pshade
	@echo "[INFO] Shaded JAR: $(APP_DIR)/target/*-shaded.jar"
.PHONY: maven/build-shaded

# -----------------------------
# Docker Image Build
# -----------------------------

DOCKER_IMAGE_NAME := flink-autoscaling-load
DOCKER_IMAGE_TAG := 1.0.0
DOCKER_IMAGE_FULL := $(DOCKER_IMAGE_NAME):$(DOCKER_IMAGE_TAG)

## Build Docker image with JAR
docker/build: maven/build docker/check
	@echo "[INFO] Building Docker image: $(DOCKER_IMAGE_FULL)"
	@cd $(APP_DIR) && docker build -t $(DOCKER_IMAGE_FULL) .
	@echo "[INFO] Docker image built successfully"
	@docker images | grep $(DOCKER_IMAGE_NAME) || true
.PHONY: docker/build

## Load Docker image into Kind cluster
docker/load: kind/check
	@if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^$(DOCKER_IMAGE_FULL)$$"; then \
		echo "[INFO] Image $(DOCKER_IMAGE_FULL) not found locally, building..."; \
		$(MAKE) docker/build; \
	fi
	@echo "[INFO] Loading Docker image into Kind cluster: $(CLUSTER_NAME)"
	@kind load docker-image $(DOCKER_IMAGE_FULL) --name $(CLUSTER_NAME)
	@echo "[INFO] Docker image loaded successfully"
.PHONY: docker/load

## Build and load Docker image into Kind (convenience target)
docker/build-and-load: docker/build docker/load
	@echo "[INFO] Docker image built and loaded into Kind cluster"
.PHONY: docker/build-and-load

## Remove Docker image
docker/clean:
	@echo "[INFO] Removing Docker image: $(DOCKER_IMAGE_FULL)"
	@docker rmi $(DOCKER_IMAGE_FULL) 2>/dev/null || echo "[INFO] Image not found, nothing to remove"
.PHONY: docker/clean

# -----------------------------
# Status Helpers
# -----------------------------

## Show cluster status (nodes and all pods)
status: kind/check
	@echo "=== Cluster Status ==="
	@$(KUBECTL) get nodes
	@echo ""
	@echo "=== All Pods ==="
	@$(KUBECTL) get pods -A
	@echo ""
	@echo "=== Flink Namespace ==="
	@$(KUBECTL) get all -n $(FLINK_NAMESPACE) 2>/dev/null || echo "Flink namespace does not exist"
.PHONY: status

## Show detailed Flink status
status/flink: kind/check
	@if ! $(KUBECTL) get namespace $(FLINK_NAMESPACE) > /dev/null 2>&1; then \
		echo "[ERROR] Flink namespace does not exist. Run 'make up' first."; \
		exit 1; \
	fi
	@echo "=== Flink Deployments (Operator Managed) ==="
	@$(KUBECTL) get flinkdeployments -n $(FLINK_NAMESPACE) 2>/dev/null || echo "No FlinkDeployments found"
	@echo ""
	@echo "=== Flink Pods ==="
	@$(KUBECTL) get pods -n $(FLINK_NAMESPACE) -o wide
	@echo ""
	@echo "=== Flink Services ==="
	@$(KUBECTL) get services -n $(FLINK_NAMESPACE)
	@echo ""
	@echo "=== HPA Status (Legacy) ==="
	@$(KUBECTL) get hpa -n $(FLINK_NAMESPACE) 2>/dev/null || echo "No HPA found (using Flink Operator autoscaler)"
	@echo ""
	@echo "=== VPA Status (Legacy) ==="
	@$(KUBECTL) get vpa -n $(FLINK_NAMESPACE) 2>/dev/null || echo "No VPA found (using Flink Operator autoscaler)"
.PHONY: status/flink

## Describe all Flink resources
flink/describe: kind/check
	@echo "=== Describing Flink Resources ==="
	@$(KUBECTL) describe flinkdeployments -n $(FLINK_NAMESPACE) 2>/dev/null || echo "No FlinkDeployments found"
	@$(KUBECTL) describe pods -n $(FLINK_NAMESPACE) 2>/dev/null || true
	@$(KUBECTL) describe hpa -n $(FLINK_NAMESPACE) 2>/dev/null || echo "No HPA (using Flink Operator autoscaler)"
	@$(KUBECTL) describe vpa -n $(FLINK_NAMESPACE) 2>/dev/null || echo "No VPA (using Flink Operator autoscaler)"
.PHONY: flink/describe

## Show Flink namespace events
flink/events: kind/check
	@echo "=== Flink Namespace Events ==="
	@$(KUBECTL) get events -n $(FLINK_NAMESPACE) --sort-by='.lastTimestamp'
.PHONY: flink/events

## Port forward to Flink UI (http://localhost:8081)
flink/ui: kind/check
	@echo "[INFO] Port forwarding to Flink UI at http://localhost:8081"
	@echo "[INFO] Press Ctrl+C to stop"
	@$(KUBECTL) port-forward -n $(FLINK_NAMESPACE) \
		svc/$(FLINK_RELEASE)-autoscaling-load-rest 8081:8081
.PHONY: flink/ui

## Tail Flink JobManager logs
logs/flink-jm: kind/check
	@$(KUBECTL) logs -n $(FLINK_NAMESPACE) \
		-l app.kubernetes.io/component=jobmanager --tail=100 -f
.PHONY: logs/flink-jm

## Tail Flink TaskManager logs
logs/flink-tm: kind/check
	@$(KUBECTL) logs -n $(FLINK_NAMESPACE) \
		-l app.kubernetes.io/component=taskmanager --tail=100 -f
.PHONY: logs/flink-tm

## Tail all Flink logs (JobManager + TaskManager)
logs/flink: kind/check
	@$(KUBECTL) logs -n $(FLINK_NAMESPACE) \
		-l app.kubernetes.io/name=flink-autoscale --tail=100 -f
.PHONY: logs/flink

# -----------------------------
# Cleanup Helpers
# -----------------------------

## Clean Maven artifacts and delete cluster
clean/all: maven/clean down
	@echo "[INFO] All cleanup complete"
.PHONY: clean/all
