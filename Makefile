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
	@helm lint $(METRICS_CHART) || true
	@helm lint $(PROMETHEUS_CHART) || true
	@helm lint $(VPA_CHART) || true
	@helm lint $(FLINK_CHART) || true
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

# Helper to check if cluster exists
define cluster-exists
	@kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"
endef

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

## Check if cluster is running and healthy
cluster/status:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Cluster '$(CLUSTER_NAME)' does not exist"; \
		exit 1; \
	fi
	@echo "[INFO] Cluster '$(CLUSTER_NAME)' is running"
	@$(KUBECTL) cluster-info
.PHONY: cluster/status

#-------------------------------------------------------------------------------
# Metrics Server
#-------------------------------------------------------------------------------

METRICS_CHART := ./charts/metrics-server
METRICS_NAMESPACE := kube-system
METRICS_RELEASE := metrics-server

## Install metrics-server (idempotent)
metrics-server/install: cluster/up
	@if ! $(KUBECTL) get --raw /apis/metrics.k8s.io > /dev/null 2>&1; then \
		echo "[INFO] Installing metrics-server"; \
		$(HELM) upgrade --install $(METRICS_RELEASE) $(METRICS_CHART) \
			-n $(METRICS_NAMESPACE) --create-namespace --wait --timeout=$(WAIT_TIMEOUT_MEDIUM); \
	else \
		echo "[INFO] metrics-server already installed"; \
	fi
.PHONY: metrics-server/install

## Uninstall metrics-server
metrics-server/uninstall:
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		if $(KUBECTL) get --raw /apis/metrics.k8s.io > /dev/null 2>&1; then \
			echo "[INFO] Uninstalling metrics-server"; \
			$(HELM) uninstall $(METRICS_RELEASE) -n $(METRICS_NAMESPACE) 2>/dev/null || true; \
		else \
			echo "[INFO] metrics-server not installed"; \
		fi \
	else \
		echo "[INFO] Cluster does not exist, skipping uninstall"; \
	fi
.PHONY: metrics-server/uninstall

## Reinstall metrics-server
metrics-server/reinstall: metrics-server/uninstall metrics-server/install
.PHONY: metrics-server/reinstall

#-------------------------------------------------------------------------------
# Prometheus
#-------------------------------------------------------------------------------

PROMETHEUS_CHART := ./charts/prometheus
PROMETHEUS_NAMESPACE := monitoring
PROMETHEUS_RELEASE := prometheus-community

## Install Prometheus (idempotent)
prometheus/install: cluster/up
	@if ! $(KUBECTL) get deployment -n $(PROMETHEUS_NAMESPACE) $(PROMETHEUS_RELEASE)-server > /dev/null 2>&1; then \
		echo "[INFO] Installing Prometheus"; \
		$(HELM) upgrade --install $(PROMETHEUS_RELEASE) $(PROMETHEUS_CHART) \
			-n $(PROMETHEUS_NAMESPACE) --create-namespace --wait --timeout=$(WAIT_TIMEOUT_MEDIUM); \
	else \
		echo "[INFO] Prometheus already installed"; \
	fi
.PHONY: prometheus/install

## Uninstall Prometheus
prometheus/uninstall:
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		if $(KUBECTL) get namespace $(PROMETHEUS_NAMESPACE) > /dev/null 2>&1; then \
			echo "[INFO] Uninstalling Prometheus"; \
			$(HELM) uninstall $(PROMETHEUS_RELEASE) -n $(PROMETHEUS_NAMESPACE) 2>/dev/null || true; \
		else \
			echo "[INFO] Prometheus not installed"; \
		fi \
	else \
		echo "[INFO] Cluster does not exist, skipping uninstall"; \
	fi
.PHONY: prometheus/uninstall

## Reinstall Prometheus
prometheus/reinstall: prometheus/uninstall prometheus/install
.PHONY: prometheus/reinstall

## Port forward to Prometheus UI (http://localhost:9090)
prometheus/ui:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Cluster does not exist. Run 'make up' first."; \
		exit 1; \
	fi
	@echo "[INFO] Port forwarding to Prometheus UI at http://localhost:9090"
	@echo "[INFO] Press Ctrl+C to stop"
	@$(KUBECTL) port-forward -n $(PROMETHEUS_NAMESPACE) \
		svc/$(PROMETHEUS_RELEASE)-server 9090:9090
.PHONY: prometheus/ui

#-------------------------------------------------------------------------------
# Vertical Pod Autoscaler (VPA)
#-------------------------------------------------------------------------------

VPA_CHART := ./charts/vertical-pod-autoscaler
VPA_NAMESPACE := kube-system
VPA_RELEASE := vertical-pod-autoscaler

## Install Vertical Pod Autoscaler (idempotent)
vpa/install: cluster/up
	@if ! $(KUBECTL) get deployment -n $(VPA_NAMESPACE) $(VPA_RELEASE)-recommender > /dev/null 2>&1; then \
		echo "[INFO] Installing Vertical Pod Autoscaler"; \
		$(HELM) upgrade --install $(VPA_RELEASE) $(VPA_CHART) \
			-n $(VPA_NAMESPACE) --create-namespace --wait --timeout=$(WAIT_TIMEOUT_LONG); \
	else \
		echo "[INFO] VPA already installed"; \
	fi
.PHONY: vpa/install

## Uninstall VPA
vpa/uninstall:
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		if $(KUBECTL) get deployment -n $(VPA_NAMESPACE) $(VPA_RELEASE)-recommender > /dev/null 2>&1; then \
			echo "[INFO] Uninstalling VPA"; \
			$(HELM) uninstall $(VPA_RELEASE) -n $(VPA_NAMESPACE) 2>/dev/null || true; \
		else \
			echo "[INFO] VPA not installed"; \
		fi \
	else \
		echo "[INFO] Cluster does not exist, skipping uninstall"; \
	fi
.PHONY: vpa/uninstall

## Reinstall VPA
vpa/reinstall: vpa/uninstall vpa/install
.PHONY: vpa/reinstall

#-------------------------------------------------------------------------------
# Flink
#-------------------------------------------------------------------------------

FLINK_RELEASE := flink-autoscale
FLINK_CHART := ./charts/flink-autoscale
FLINK_NAMESPACE := flink

APP_DIR := autoscaling-load-job
APP_POM := $(APP_DIR)/pom.xml
APP_JAR := $(APP_DIR)/target/autoscaling-load-job.jar

## Install Flink Autoscale application (idempotent)
flink/install: cluster/up
	@if ! $(KUBECTL) get deployment -n $(FLINK_NAMESPACE) $(FLINK_RELEASE)-flink-autoscale-jobmanager > /dev/null 2>&1; then \
		echo "[INFO] Installing Flink Autoscale Helm chart"; \
		$(HELM) upgrade --install $(FLINK_RELEASE) $(FLINK_CHART) \
			-n $(FLINK_NAMESPACE) --create-namespace --wait --timeout=$(WAIT_TIMEOUT_MEDIUM); \
		echo "[INFO] Flink installed successfully"; \
	else \
		echo "[INFO] Flink already installed"; \
	fi
.PHONY: flink/install

## Uninstall Flink Autoscale application
flink/uninstall:
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		if $(KUBECTL) get namespace $(FLINK_NAMESPACE) > /dev/null 2>&1; then \
			echo "[INFO] Uninstalling Flink"; \
			$(HELM) uninstall $(FLINK_RELEASE) -n $(FLINK_NAMESPACE) 2>/dev/null || true; \
		else \
			echo "[INFO] Flink not installed"; \
		fi \
	else \
		echo "[INFO] Cluster does not exist, skipping uninstall"; \
	fi
.PHONY: flink/uninstall

## Reinstall Flink Autoscale application
flink/reinstall: flink/uninstall flink/install
.PHONY: flink/reinstall

# -----------------------------
# Full bootstrap (one command)
# -----------------------------

## Bootstrap entire environment (cluster + all components)
up: cluster/up metrics-server/install prometheus/install vpa/install flink/install
	@echo ""
	@echo "=== Environment Ready ==="
	@echo "Flink UI:      make flink/ui (then visit http://localhost:8081)"
	@echo "Prometheus UI: make prometheus/ui (then visit http://localhost:9090)"
	@echo "Cluster:       kind get clusters"
	@echo "Status:        make status"
	@echo "Flink Status:  make status/flink"
	@echo ""
.PHONY: up

## Tear down entire environment (uninstall all + delete cluster)
down:
	@echo "[INFO] Tearing down environment..."
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		$(MAKE) flink/uninstall || true; \
		$(MAKE) vpa/uninstall || true; \
		$(MAKE) prometheus/uninstall || true; \
		$(MAKE) metrics-server/uninstall || true; \
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
# Status Helpers
# -----------------------------

## Show cluster status (nodes and all pods)
status:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Cluster '$(CLUSTER_NAME)' does not exist. Run 'make cluster/up' first."; \
		exit 1; \
	fi
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
status/flink:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Cluster '$(CLUSTER_NAME)' does not exist. Run 'make cluster/up' first."; \
		exit 1; \
	fi
	@if ! $(KUBECTL) get namespace $(FLINK_NAMESPACE) > /dev/null 2>&1; then \
		echo "[ERROR] Flink namespace does not exist. Run 'make flink/install' first."; \
		exit 1; \
	fi
	@echo "=== Flink Deployments ==="
	@$(KUBECTL) get deployments -n $(FLINK_NAMESPACE)
	@echo ""
	@echo "=== Flink Pods ==="
	@$(KUBECTL) get pods -n $(FLINK_NAMESPACE) -o wide
	@echo ""
	@echo "=== Flink Services ==="
	@$(KUBECTL) get services -n $(FLINK_NAMESPACE)
	@echo ""
	@echo "=== HPA Status ==="
	@$(KUBECTL) get hpa -n $(FLINK_NAMESPACE) 2>/dev/null || echo "No HPA found"
	@echo ""
	@echo "=== VPA Status ==="
	@$(KUBECTL) get vpa -n $(FLINK_NAMESPACE) 2>/dev/null || echo "No VPA found"
.PHONY: status/flink

## Describe all Flink resources
flink/describe:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Cluster does not exist"; \
		exit 1; \
	fi
	@echo "=== Describing Flink Resources ==="
	@$(KUBECTL) describe deployment -n $(FLINK_NAMESPACE) 2>/dev/null || true
	@$(KUBECTL) describe pods -n $(FLINK_NAMESPACE) 2>/dev/null || true
	@$(KUBECTL) describe hpa -n $(FLINK_NAMESPACE) 2>/dev/null || true
	@$(KUBECTL) describe vpa -n $(FLINK_NAMESPACE) 2>/dev/null || true
.PHONY: flink/describe

## Show Flink namespace events
flink/events:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Cluster does not exist"; \
		exit 1; \
	fi
	@echo "=== Flink Namespace Events ==="
	@$(KUBECTL) get events -n $(FLINK_NAMESPACE) --sort-by='.lastTimestamp'
.PHONY: flink/events

## Port forward to Flink UI (http://localhost:8081)
flink/ui:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Cluster does not exist. Run 'make up' first."; \
		exit 1; \
	fi
	@echo "[INFO] Port forwarding to Flink UI at http://localhost:8081"
	@echo "[INFO] Press Ctrl+C to stop"
	@$(KUBECTL) port-forward -n $(FLINK_NAMESPACE) \
		svc/$(FLINK_RELEASE)-flink-autoscale-jobmanager 8081:8081
.PHONY: flink/ui

## Tail Flink JobManager logs
logs/flink-jm:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Cluster does not exist"; \
		exit 1; \
	fi
	@$(KUBECTL) logs -n $(FLINK_NAMESPACE) \
		-l app.kubernetes.io/component=jobmanager --tail=100 -f
.PHONY: logs/flink-jm

## Tail Flink TaskManager logs
logs/flink-tm:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Cluster does not exist"; \
		exit 1; \
	fi
	@$(KUBECTL) logs -n $(FLINK_NAMESPACE) \
		-l app.kubernetes.io/component=taskmanager --tail=100 -f
.PHONY: logs/flink-tm

## Tail all Flink logs (JobManager + TaskManager)
logs/flink:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "[ERROR] Cluster does not exist"; \
		exit 1; \
	fi
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
