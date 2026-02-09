# Flink Operator Migration Guide

This document describes the migration from Kubernetes-native autoscaling (HPA/VPA) to the Flink Kubernetes Operator with built-in autoscaler.

## Branch Information

**Branch:** `flink-operator-autoscaler`

This branch ports the flink-playground implementation to use the Apache Flink Kubernetes Operator instead of standard Kubernetes Deployments with HPA/VPA.

## Overview of Changes

### Architecture Shift

**Before (main branch):**
- Standard Kubernetes Deployments for JobManager and TaskManager
- Horizontal Pod Autoscaler (HPA) for scaling TaskManager replicas based on CPU
- Vertical Pod Autoscaler (VPA) for memory optimization
- Manual configuration of Flink components

**After (flink-operator-autoscaler branch):**
- FlinkDeployment Custom Resource managed by Flink Kubernetes Operator
- **Hybrid Autoscaling Approach:**
  - **Flink Operator Autoscaler**: Job-aware horizontal scaling (parallelism & replicas)
  - **VPA**: Memory optimization per TaskManager pod
- Native Kubernetes integration with high availability
- Declarative Flink configuration

### Key Benefits of Flink Operator

1. **Job-Aware Autoscaling**: Scales based on Flink job metrics (backpressure, processing rate, lag) rather than just CPU/memory
2. **Declarative Management**: Entire Flink deployment managed as a single Kubernetes resource
3. **High Availability**: Built-in HA configuration with Kubernetes state backend
4. **Unified Configuration**: All Flink settings in one place (FlinkDeployment spec)
5. **Better State Management**: Automatic checkpoint and savepoint handling
6. **Hybrid Autoscaling**: Combines Flink Operator (horizontal) + VPA (vertical) for complete coverage

## Files Changed

### New Files
- `charts/flink-autoscale/templates/flink-deployment.yaml` - FlinkDeployment CRD
- `charts/flink-autoscale/templates/flink-serviceaccount.yaml` - RBAC for Flink
- `FLINK_OPERATOR_MIGRATION.md` - This document

### Modified Files
- `Makefile` - Added Flink Operator installation targets
- `charts/flink-autoscale/values.yaml` - Added Flink Operator autoscaler configuration

### Deprecated Files (kept for reference)
- `charts/flink-autoscale/templates/jobmanager-deploy.yaml` - Replaced by FlinkDeployment
- `charts/flink-autoscale/templates/taskmanager-deploy.yaml` - Replaced by FlinkDeployment
- `charts/flink-autoscale/templates/taskmanager-hpa.yaml` - Replaced by Flink Operator autoscaler
- `charts/flink-autoscale/templates/taskmanager-vertical-pod-autoscaler.yaml` - Replaced by Flink Operator autoscaler

## New Makefile Targets

### Flink Operator Management

```bash
# Install Flink Kubernetes Operator
make flink-operator/install

# Uninstall Flink Operator
make flink-operator/uninstall

# Reinstall Flink Operator
make flink-operator/reinstall
```

### Full Bootstrap

The `make up` command now includes Flink Operator installation:

```bash
# Complete environment setup (includes Flink Operator)
make up

# Tear down everything (includes Flink Operator)
make kind/down
```

## Configuration

### Autoscaler Settings

The Flink Operator autoscaler is configured in `charts/flink-autoscale/values.yaml`:

```yaml
flinkOperator:
  autoscaler:
    enabled: true
    metricsWindow: "5m"              # Time window for metrics collection
    stabilizationInterval: "1m"       # Stability period before scaling
    targetUtilization: "0.7"          # Target utilization (70%)
    targetUtilizationBoundary: "0.1"  # Boundary to prevent oscillation
    scaleUpGracePeriod: "1m"          # Wait time before scaling up
    scaleDownGracePeriod: "3m"        # Wait time before scaling down
    minParallelism: 1                 # Minimum parallelism
    maxParallelism: 10                # Maximum parallelism
```

### Comparison: Autoscaling Approaches

| Feature | HPA (main branch) | Flink Operator (this branch) | VPA (both branches) |
|---------|------------------|------------------------------|---------------------|
| **Scaling Type** | Horizontal | Horizontal | Vertical |
| **Scaling Target** | TaskManager replicas | Job parallelism + replicas | Memory per pod |
| **Scaling Metric** | CPU utilization | Job metrics (lag, rate, backpressure) | Memory usage |
| **Awareness** | Pod-level | Job-level | Pod-level |
| **Enabled in this branch** | ❌ No | ✅ Yes | ✅ Yes |
| **Min/Max** | 1-10 replicas | 1-10 parallelism | 256Mi-2Gi memory |
| **Target** | 70% CPU | 70% utilization | Optimal memory |
| **Stabilization** | Default (15s) | Configurable (1m) | N/A |
| **Scale Up Grace** | None | 1 minute | N/A |
| **Scale Down Grace** | Default (5m) | 3 minutes | N/A |

### Hybrid Autoscaling Architecture

This branch uses a **complementary autoscaling approach**:

- **Flink Operator Autoscaler** (Horizontal):
  - Monitors Flink job metrics
  - Adjusts job parallelism based on workload
  - Scales TaskManager replicas to match parallelism
  - Prevents scaling oscillation with grace periods

- **VPA** (Vertical):
  - Monitors actual memory usage per TaskManager pod
  - Adjusts memory requests/limits within defined bounds (256Mi-2Gi)
  - Optimizes resource utilization without manual tuning
  - Works independently of Flink Operator's horizontal scaling

## Usage

### 1. Bootstrap the Environment

```bash
# Create cluster and install all components including Flink Operator
make up
```

This will:
1. Create Kind cluster
2. Install metrics-server
3. Install Prometheus
4. Install VPA (disabled but available)
5. **Install Flink Kubernetes Operator**
6. Deploy Flink using FlinkDeployment CRD

### 2. Access Flink UI

```bash
# Port-forward to Flink web UI
make ui

# Visit http://localhost:8081
```

### 4. Monitor Autoscaling

The Flink Operator autoscaler logs can be viewed:

```bash
# View Flink Operator logs
kubectl logs -n flink-operator deployment/flink-kubernetes-operator -f

# View Flink JobManager logs
kubectl logs -n flink -l app.kubernetes.io/component=jobmanager --tail=100 -f

# View Flink TaskManager logs
kubectl logs -n flink -l app.kubernetes.io/component=taskmanager --tail=100 -f
```

### 5. Trigger Autoscaling

The autoscaling load job will generate load automatically. Watch the autoscaler in action:

```bash
# Watch FlinkDeployment status
kubectl get flinkdeployments -n flink -w

# Watch pods scaling
kubectl get pods -n flink -w

# Check Flink UI for parallelism changes
# Visit http://localhost:8081
```

## Autoscaling Behavior

### How It Works

1. **Metrics Collection**: Operator collects Flink job metrics over a 5-minute window
2. **Utilization Calculation**: Compares current processing rate vs. target utilization (70%)
3. **Stabilization**: Waits 1 minute to ensure metrics are stable
4. **Scaling Decision**:
   - **Scale Up**: If utilization > 80% (70% + 10% boundary), after 1-minute grace period
   - **Scale Down**: If utilization < 60% (70% - 10% boundary), after 3-minute grace period
5. **Application**: Operator adjusts job parallelism and TaskManager replicas

### Metrics Used

The Flink Operator autoscaler uses:
- **Processing Rate**: Events processed per second
- **Backpressure**: Downstream task congestion
- **Lag**: For source connectors with lag tracking
- **Busy Time**: Percentage of time tasks are actively processing

Unlike HPA (CPU-based), this provides true **workload-aware scaling**.

## Why Hybrid Autoscaling?

### HPA Limitations (Addressed by Flink Operator)
- ✗ Only scales on CPU/memory, not Flink job metrics
- ✗ No awareness of Flink parallelism or job state
- ✗ Can cause inefficient scaling (e.g., adding TaskManagers without increasing parallelism)
- ✗ May scale prematurely on CPU spikes unrelated to actual job load

### Flink Operator Advantages (Replaces HPA)
- ✓ Scales based on actual job workload and backpressure
- ✓ Automatically adjusts parallelism and TaskManager replicas together
- ✓ Respects savepoints and checkpoints during scaling
- ✓ Prevents oscillation with stabilization periods
- ✓ Understands Flink-specific metrics (lag, processing rate, busy time)

### VPA Role (Kept Enabled)
- ✓ Complements Flink Operator by optimizing memory allocation per pod
- ✓ Flink Operator decides **how many** TaskManagers are needed
- ✓ VPA optimizes **how much memory** each TaskManager gets
- ✓ Both work independently without conflicts:
  - Flink Operator: Controls replicas (horizontal)
  - VPA: Controls memory resources (vertical)

## Troubleshooting

### Check Operator Status

```bash
# Verify operator is running
kubectl get pods -n flink-operator

# View operator logs
kubectl logs -n flink-operator deployment/flink-kubernetes-operator
```

### Check FlinkDeployment

```bash
# View FlinkDeployment status
kubectl get flinkdeployments -n flink

# Describe FlinkDeployment for details
kubectl describe flinkdeployment -n flink
```

### Common Issues

**Issue**: FlinkDeployment not creating pods

**Solution**: Check operator logs and ensure cert-manager is installed:
```bash
kubectl get pods -n cert-manager
```

**Issue**: Autoscaler not scaling

**Solution**: Verify autoscaler is enabled in values.yaml and check operator logs for scaling decisions:
```bash
kubectl logs -n flink-operator deployment/flink-kubernetes-operator | grep -i autoscal
```

## Reverting to HPA/VPA

To revert to the original HPA/VPA implementation:

```bash
# Switch back to main branch
git checkout main

# Tear down current environment
make kind/down

# Rebuild with HPA/VPA
make up
```

## Testing the Implementation

### Basic Functionality Test

```bash
# 1. Bootstrap environment
make up

# 2. Wait for all components to be ready (~3-5 minutes)
kubectl get pods -A

# 3. Check FlinkDeployment is created
kubectl get flinkdeployments -n flink

# 4. Access Flink UI
make ui
# Visit http://localhost:8081 and verify job is running

# 5. Monitor autoscaling over time
watch -n 5 'kubectl get flinkdeployments -n flink'
```

### Load Test for Autoscaling

The autoscaling load job generates synthetic load automatically. To adjust load:

1. Modify the job parameters in the FlinkDeployment spec
2. Update and reinstall:
```bash
make flink/reinstall
```

## Next Steps

After testing this branch:

1. **Compare Performance**: Monitor scaling behavior vs. HPA/VPA on main branch
2. **Tune Parameters**: Adjust autoscaler settings in values.yaml based on workload
3. **Add Custom Metrics**: Extend autoscaler with custom Flink metrics if needed
4. **Production Hardening**: Add resource quotas, network policies, etc.

## References

- [Flink Kubernetes Operator Documentation](https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-main/)
- [Flink Operator Autoscaler](https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-main/docs/custom-resource/autoscaler/)
- [FlinkDeployment Spec](https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-main/docs/custom-resource/reference/)
