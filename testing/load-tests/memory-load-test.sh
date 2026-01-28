#!/usr/bin/env bash
#
# Flink Memory Load Testing Script
#
# This script performs load testing on Flink jobs to validate memory configuration
# and identify optimization opportunities.
#
# Usage:
#   ./memory-load-test.sh [options]
#
# Options:
#   --duration <seconds>    Test duration in seconds (default: 300)
#   --parallelism <num>     Target parallelism to scale to (default: 10)
#   --namespace <ns>        Kubernetes namespace (default: flink)
#   --job <name>            FlinkDeployment name (default: flink-autoscale-autoscaling-load)
#   --help                  Show this help message

set -euo pipefail

# Default values
DURATION=300
TARGET_PARALLELISM=10
NAMESPACE="flink"
JOB_NAME="flink-autoscale-autoscaling-load"
SAMPLE_INTERVAL=10

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --parallelism)
      TARGET_PARALLELISM="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --job)
      JOB_NAME="$2"
      shift 2
      ;;
    --help)
      grep '^#' "$0" | grep -v '#!/' | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Flink Memory Load Test${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Configuration:"
echo "  Duration: ${DURATION}s"
echo "  Target Parallelism: ${TARGET_PARALLELISM}"
echo "  Namespace: ${NAMESPACE}"
echo "  Job: ${JOB_NAME}"
echo "  Sample Interval: ${SAMPLE_INTERVAL}s"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

# Check if job exists
if ! kubectl get flinkdeployment "${JOB_NAME}" -n "${NAMESPACE}" &> /dev/null; then
    echo -e "${RED}Error: FlinkDeployment ${JOB_NAME} not found in namespace ${NAMESPACE}${NC}"
    exit 1
fi

# Create output directory
OUTPUT_DIR="load-test-results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${OUTPUT_DIR}"
echo "Results will be saved to: ${OUTPUT_DIR}"
echo ""

# Get current parallelism
CURRENT_PARALLELISM=$(kubectl get flinkdeployment "${JOB_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.job.parallelism}')
echo -e "${GREEN}Current parallelism: ${CURRENT_PARALLELISM}${NC}"

# Function to get metrics from pods
get_pod_metrics() {
    local pod_type=$1
    local label_selector=""

    if [ "$pod_type" == "jobmanager" ]; then
        label_selector="app.kubernetes.io/component=jobmanager"
    else
        label_selector="app.kubernetes.io/component=taskmanager"
    fi

    local pods=$(kubectl get pods -n "${NAMESPACE}" -l "${label_selector}" -o jsonpath='{.items[*].metadata.name}')

    for pod in $pods; do
        if kubectl exec -n "${NAMESPACE}" "${pod}" -- curl -s http://localhost:9249/ 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Function to collect memory metrics
collect_metrics() {
    local timestamp=$1
    local output_file="${OUTPUT_DIR}/metrics-${timestamp}.txt"

    echo "=== Metrics at $(date) ===" >> "${output_file}"

    # FlinkDeployment status
    echo "--- FlinkDeployment Status ---" >> "${output_file}"
    kubectl get flinkdeployment "${JOB_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status}' >> "${output_file}"
    echo "" >> "${output_file}"

    # Pod resource usage
    echo "--- Pod Resource Usage ---" >> "${output_file}"
    kubectl top pods -n "${NAMESPACE}" --no-headers >> "${output_file}" 2>/dev/null || echo "Metrics not available" >> "${output_file}"
    echo "" >> "${output_file}"

    # Flink metrics from Prometheus endpoint (if accessible)
    echo "--- Flink Metrics (from pods) ---" >> "${output_file}"

    # Try to get metrics from TaskManager pods
    local tm_pods=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=taskmanager -o jsonpath='{.items[*].metadata.name}')
    for pod in $tm_pods; do
        echo "TaskManager: ${pod}" >> "${output_file}"
        kubectl exec -n "${NAMESPACE}" "${pod}" -- curl -s http://localhost:9249/ 2>/dev/null | \
            grep -E "(JVM_Memory|Checkpoint|numRecords|backPressure)" >> "${output_file}" 2>/dev/null || true
        echo "" >> "${output_file}"
    done
}

# Start test
echo -e "${BLUE}Starting load test...${NC}"
START_TIME=$(date +%s)

# Scale up to target parallelism
echo -e "${YELLOW}Scaling to parallelism ${TARGET_PARALLELISM}...${NC}"
kubectl patch flinkdeployment "${JOB_NAME}" -n "${NAMESPACE}" --type=merge -p "{\"spec\":{\"job\":{\"parallelism\":${TARGET_PARALLELISM}}}}"

# Wait for scaling
echo "Waiting for job to stabilize..."
sleep 30

# Monitoring loop
ITERATION=0
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if [ $ELAPSED -ge $DURATION ]; then
        break
    fi

    REMAINING=$((DURATION - ELAPSED))
    echo -e "${GREEN}[${ELAPSED}s / ${DURATION}s] Collecting metrics... (${REMAINING}s remaining)${NC}"

    # Collect metrics
    collect_metrics "${ITERATION}"

    # Show current status
    echo "FlinkDeployment Status:"
    kubectl get flinkdeployment "${JOB_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.jobManagerDeploymentStatus}' && echo ""
    kubectl get flinkdeployment "${JOB_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.jobStatus.state}' && echo ""

    echo "Current Pods:"
    kubectl get pods -n "${NAMESPACE}" --no-headers | wc -l | xargs echo "  Total:"
    kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=taskmanager --no-headers | wc -l | xargs echo "  TaskManagers:"

    echo ""

    ITERATION=$((ITERATION + 1))
    sleep $SAMPLE_INTERVAL
done

# Test complete
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Load test complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Collect final metrics
echo "Collecting final metrics..."
collect_metrics "final"

# Generate summary report
SUMMARY_FILE="${OUTPUT_DIR}/summary.txt"
echo "Flink Memory Load Test Summary" > "${SUMMARY_FILE}"
echo "==============================" >> "${SUMMARY_FILE}"
echo "" >> "${SUMMARY_FILE}"
echo "Test Configuration:" >> "${SUMMARY_FILE}"
echo "  Duration: ${DURATION}s" >> "${SUMMARY_FILE}"
echo "  Target Parallelism: ${TARGET_PARALLELISM}" >> "${SUMMARY_FILE}"
echo "  Namespace: ${NAMESPACE}" >> "${SUMMARY_FILE}"
echo "  Job: ${JOB_NAME}" >> "${SUMMARY_FILE}"
echo "" >> "${SUMMARY_FILE}"
echo "Final Status:" >> "${SUMMARY_FILE}"
kubectl get flinkdeployment "${JOB_NAME}" -n "${NAMESPACE}" >> "${SUMMARY_FILE}"
echo "" >> "${SUMMARY_FILE}"
echo "Final Pods:" >> "${SUMMARY_FILE}"
kubectl get pods -n "${NAMESPACE}" >> "${SUMMARY_FILE}"
echo "" >> "${SUMMARY_FILE}"

# Check for OOM kills
echo "Checking for OOM kills..." >> "${SUMMARY_FILE}"
if kubectl get events -n "${NAMESPACE}" --field-selector reason=OOMKilled | grep -q OOMKilled; then
    echo -e "${RED}WARNING: OOM kills detected!${NC}"
    echo "WARNING: OOM kills detected!" >> "${SUMMARY_FILE}"
    kubectl get events -n "${NAMESPACE}" --field-selector reason=OOMKilled >> "${SUMMARY_FILE}"
else
    echo "No OOM kills detected" >> "${SUMMARY_FILE}"
fi
echo "" >> "${SUMMARY_FILE}"

# Show summary
cat "${SUMMARY_FILE}"

echo ""
echo -e "${GREEN}Results saved to: ${OUTPUT_DIR}/${NC}"
echo ""
echo "To analyze results:"
echo "  cat ${OUTPUT_DIR}/summary.txt"
echo "  cat ${OUTPUT_DIR}/metrics-*.txt"
echo ""
echo "To restore original parallelism:"
echo "  kubectl patch flinkdeployment ${JOB_NAME} -n ${NAMESPACE} --type=merge -p '{\"spec\":{\"job\":{\"parallelism\":${CURRENT_PARALLELISM}}}}'"
