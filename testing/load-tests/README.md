# Flink Memory Load Testing

This directory contains tools for load testing and validating Flink memory configurations.

## Overview

Load testing helps validate memory configurations and identify optimization opportunities before deploying to production. The tools in this directory allow you to:

- Scale Flink jobs to target parallelism
- Monitor memory usage, GC behavior, and checkpoint performance
- Analyze metrics and generate reports
- Identify memory bottlenecks and OOM conditions

## Tools

### 1. Shell-Based Load Test (`memory-load-test.sh`)

A simple bash script for running load tests and collecting metrics.

**Features:**
- Automated scaling to target parallelism
- Periodic metric collection from Flink pods
- Event monitoring (OOM kills, pod crashes)
- Summary report generation

**Usage:**
```bash
# Run default test (5 minutes, scale to parallelism 10)
./memory-load-test.sh

# Custom test duration and parallelism
./memory-load-test.sh --duration 600 --parallelism 20

# Full options
./memory-load-test.sh \
  --duration 600 \
  --parallelism 20 \
  --namespace flink \
  --job flink-autoscale-autoscaling-load
```

**Output:**
- `load-test-results-TIMESTAMP/` directory containing:
  - `metrics-*.txt` - Periodic metric snapshots
  - `summary.txt` - Test summary and final status
  - Event logs and OOM detection

### 2. Python-Based Analysis (`analyze-metrics.py`)

Advanced analysis tool that queries Prometheus and generates visualizations.

**Features:**
- Queries historical metrics from Prometheus
- Calculates statistical summaries (avg, max, min)
- Generates visualization plots
- Exports JSON reports

**Prerequisites:**
```bash
# Install Python dependencies
pip install -r requirements.txt

# Or install individually
pip install prometheus-api-client pandas matplotlib requests
```

**Usage:**
```bash
# Port-forward Prometheus first
kubectl port-forward -n monitoring svc/prometheus-prometheus 9090:9090 &

# Analyze last 5 minutes
python3 analyze-metrics.py --prometheus-url http://localhost:9090 --duration 300

# Analyze last 10 minutes with custom output directory
python3 analyze-metrics.py \
  --prometheus-url http://localhost:9090 \
  --duration 600 \
  --output-dir my-load-test-results
```

**Output:**
- `load-test-analysis/` directory (or custom) containing:
  - `metrics-visualization.png` - Multi-panel chart with all metrics
  - `analysis-report.json` - Detailed JSON report with statistics

## Load Testing Workflow

### 1. Prepare Environment

```bash
# Ensure Flink job is running
kubectl get flinkdeployment -n flink

# Verify Prometheus is scraping Flink metrics
kubectl port-forward -n monitoring svc/prometheus-prometheus 9090:9090 &
# Open http://localhost:9090 and query: flink_taskmanager_Status_JVM_Memory_Heap_Used

# Optional: Open Grafana dashboard
kubectl port-forward -n monitoring svc/grafana 3000:80 &
# Open http://localhost:3000 (admin/admin)
```

### 2. Run Load Test

```bash
# Start the shell-based load test
cd testing/load-tests
./memory-load-test.sh --duration 600 --parallelism 20
```

**What it does:**
1. Scales Flink job to target parallelism
2. Waits for stabilization (30s)
3. Collects metrics every 10 seconds
4. Monitors for OOM kills and errors
5. Generates summary report

### 3. Monitor Live (Optional)

While the test is running, monitor in real-time:

```bash
# Watch FlinkDeployment status
watch kubectl get flinkdeployment -n flink

# Monitor pods and resources
watch kubectl top pods -n flink

# Tail JobManager logs
kubectl logs -n flink -l app.kubernetes.io/component=jobmanager -f

# Watch for OOM kills
kubectl get events -n flink --watch
```

### 4. Analyze Results

After the test completes:

```bash
# Analyze metrics from Prometheus
python3 analyze-metrics.py \
  --prometheus-url http://localhost:9090 \
  --duration 600 \
  --output-dir load-test-results-$(date +%Y%m%d-%H%M%S)

# View results
cat load-test-analysis/analysis-report.json
open load-test-analysis/metrics-visualization.png
```

### 5. Review and Optimize

Look for these issues in the results:

**Memory Issues:**
- Heap usage consistently > 80% → Increase heap memory
- Managed memory maxed out → Increase managed memory fraction
- Non-heap memory high → Check for classloader leaks

**GC Issues:**
- GC time > 50ms/s → Increase heap, tune GC settings
- GC frequency > 10/min → Heap too small or memory leak

**Checkpoint Issues:**
- Duration increasing over time → State size growing, RocksDB needs tuning
- Failed checkpoints → Timeout too short or resource constraints
- Size > 1GB → Consider incremental checkpoints, state cleanup

**Throughput Issues:**
- Backpressure > 0.3 → Downstream bottleneck or insufficient resources
- Throughput decreasing → GC pressure, resource contention

**OOM Kills:**
- Check events and logs for OOM kills
- Increase memory limits
- Adjust Flink memory model (see production values)

## Example Scenarios

### Scenario 1: Validate Production Configuration

Before deploying production-optimized memory settings:

```bash
# Deploy with production values
helm upgrade flink-autoscale charts/flink-autoscale \
  -f charts/flink-autoscale/values-production.yaml \
  -n flink

# Wait for deployment
kubectl wait --for=condition=Ready \
  -n flink deployment/flink-autoscale-autoscaling-load \
  --timeout=300s

# Run load test
./memory-load-test.sh --duration 900 --parallelism 20

# Analyze results
python3 analyze-metrics.py --duration 900
```

**Success criteria:**
- No OOM kills
- Heap usage < 85%
- GC time < 50ms/s
- Checkpoint duration < 10s
- No backpressure

### Scenario 2: Find Optimal Memory Configuration

Iteratively test different memory configurations:

```bash
# Test 1: Baseline (4Gi TaskManager)
./memory-load-test.sh --duration 300 --parallelism 10
python3 analyze-metrics.py --duration 300 --output-dir test-4gi

# Test 2: Increased memory (6Gi TaskManager)
# Edit values-production.yaml: taskManager.memory: "6144Mi"
helm upgrade flink-autoscale charts/flink-autoscale -f values-production.yaml -n flink
kubectl rollout status deployment -n flink --timeout=300s
./memory-load-test.sh --duration 300 --parallelism 10
python3 analyze-metrics.py --duration 300 --output-dir test-6gi

# Compare results
diff test-4gi/analysis-report.json test-6gi/analysis-report.json
```

### Scenario 3: Stress Test

Push the job to its limits to find breaking points:

```bash
# Gradually increase parallelism
for parallelism in 5 10 15 20 25 30; do
  echo "Testing parallelism: $parallelism"

  ./memory-load-test.sh --duration 180 --parallelism $parallelism

  # Check if job survived
  if kubectl get flinkdeployment -n flink | grep -q STABLE; then
    echo "Success at parallelism $parallelism"
  else
    echo "Failed at parallelism $parallelism"
    break
  fi

  sleep 60  # Cool down period
done
```

## Interpreting Metrics

### Memory Metrics

**Heap Memory:**
- `flink_taskmanager_Status_JVM_Memory_Heap_Used`: Current heap usage
- `flink_taskmanager_Status_JVM_Memory_Heap_Max`: Maximum heap size
- **Target**: Keep usage at 60-80% during steady state

**Managed Memory (RocksDB):**
- `flink_taskmanager_Status_Flink_Memory_Managed_Used`: RocksDB memory usage
- **Target**: Should stabilize after warmup, not grow continuously

### GC Metrics

**Young Generation:**
- `rate(G1_Young_Generation_Time[1m])`: Time spent in young GC
- `rate(G1_Young_Generation_Count[1m])`: GC frequency
- **Target**: < 50ms/s, < 5 collections/min

**Old Generation:**
- Similar metrics for old gen GC
- **Target**: Very infrequent (< 1/hour in steady state)

### Checkpoint Metrics

**Duration:**
- `flink_jobmanager_job_lastCheckpointDuration`: Time to complete checkpoint
- **Target**: < 10s (depends on state size)

**Size:**
- `flink_jobmanager_job_lastCheckpointSize`: Checkpoint size in bytes
- **Target**: Stable (not growing continuously)

**Success Rate:**
- `numberOfCompletedCheckpoints` vs `numberOfFailedCheckpoints`
- **Target**: 100% success rate

### Performance Metrics

**Throughput:**
- `rate(numRecordsInPerSecond[1m])`: Records processed per second
- **Target**: Stable, no degradation over time

**Backpressure:**
- `backPressuredTimeMsPerSecond / 1000`: Fraction of time backpressured (0-1)
- **Target**: < 0.3 (< 30% of time)

## Troubleshooting

### OOM Kills

**Symptoms:**
- Pods restarting with exit code 137
- Events show "OOMKilled"

**Solutions:**
1. Increase memory limits in podTemplate resources
2. Adjust Flink memory model (reduce heap, increase overhead)
3. Enable heap dumps: `-XX:+HeapDumpOnOutOfMemoryError`

### High GC Pressure

**Symptoms:**
- GC time > 100ms/s
- Frequent young GC (> 10/min)
- Throughput degradation

**Solutions:**
1. Increase heap memory
2. Tune G1GC parameters (MaxGCPauseMillis, G1HeapRegionSize)
3. Reduce object allocation in user code

### Checkpoint Timeouts

**Symptoms:**
- Failed checkpoints with timeout errors
- Checkpoint duration increasing

**Solutions:**
1. Increase checkpoint timeout
2. Enable unaligned checkpoints
3. Tune RocksDB (increase write buffers)
4. Reduce checkpoint frequency

### Backpressure

**Symptoms:**
- Backpressure metric > 0.5
- Throughput below expected
- Tasks idle

**Solutions:**
1. Scale up parallelism
2. Optimize slow operators
3. Increase TaskManager resources
4. Check external systems (Kafka, database)

## CI/CD Integration

To integrate load testing into CI/CD:

```bash
# Example GitLab CI job
load-test:
  stage: test
  script:
    - kubectl apply -f deploy/
    - ./testing/load-tests/memory-load-test.sh --duration 300 --parallelism 10
    - python3 testing/load-tests/analyze-metrics.py --duration 300
    - |
      # Check for failures
      if grep -q "OOMKilled" load-test-results-*/summary.txt; then
        echo "Load test failed: OOM kills detected"
        exit 1
      fi
  artifacts:
    paths:
      - load-test-results-*/
      - load-test-analysis/
    expire_in: 1 week
```

## Best Practices

1. **Establish Baseline**: Run tests with current configuration first
2. **Iterate**: Make one change at a time and retest
3. **Monitor Production**: Use same metrics in production
4. **Document**: Keep notes on configuration changes and results
5. **Automate**: Integrate tests into CI/CD pipeline
6. **Safety**: Test in non-production environment first

## Additional Resources

- [Flink Memory Model Documentation](https://nightlies.apache.org/flink/flink-docs-stable/docs/deployment/memory/mem_setup/)
- [RocksDB Tuning Guide](https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/state/large_state_tuning/)
- [Flink Performance Tuning](https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/production_ready/)
