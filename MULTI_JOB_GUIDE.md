# Multi-Job FlinkDeployment Guide

This guide shows you how to use the restructured Helm chart to deploy multiple Flink jobs simultaneously, each with its own FlinkDeployment and autoscaler configuration.

## Overview

The `flink-autoscale` Helm chart now supports deploying multiple Flink jobs from a single `values.yaml` file. Each job:
- Gets its own FlinkDeployment (separate Flink cluster)
- Can have independent autoscaler settings
- Can have independent VPA configuration
- Can override default resources and settings

## Chart Structure

```
charts/flink-autoscale/
├── Chart.yaml
├── values.yaml                # Define multiple jobs here
└── templates/
    ├── flink-deployment.yaml  # Iterates over jobs list (NEW)
    ├── vpa.yaml              # Creates VPA per job (NEW)
    ├── flink-serviceaccount.yaml  # Shared RBAC
    ├── namespace.yaml        # Shared namespace
    ├── jobmanager-svc.yaml   # JobManager service
    └── [deprecated templates]
```

## Basic Usage

### 1. Deploy Single Job

The default `values.yaml` includes one job called `autoscaling-load`:

```bash
# Install with default configuration (1 job)
make flink/install

# Or using helm directly
helm install flink-autoscale ./charts/flink-autoscale -n flink --create-namespace
```

This creates:
- 1 FlinkDeployment: `flink-autoscale-autoscaling-load`
- 1 JobManager pod
- 1+ TaskManager pods (autoscales 1-10)
- 1 VPA for TaskManager memory optimization

### 2. Deploy Multiple Jobs

Edit `values.yaml` to enable additional jobs:

```yaml
jobs:
  # Job 1: Autoscaling Load Test
  - name: autoscaling-load
    enabled: true
    job:
      jarURI: "local:///opt/flink/usrlib/autoscaling-load-job.jar"
      entryClass: "com.example.flink.AutoscalingLoadJob"
      parallelism: 2
    autoscaler:
      minParallelism: 1
      maxParallelism: 10

  # Job 2: Analytics Pipeline
  - name: analytics-pipeline
    enabled: true
    job:
      jarURI: "local:///opt/flink/usrlib/analytics.jar"
      entryClass: "com.example.flink.AnalyticsPipeline"
      parallelism: 4
    autoscaler:
      targetUtilization: "0.8"
      minParallelism: 2
      maxParallelism: 20
    taskManager:
      resources:
        requests:
          cpu: "500m"
          memory: "1Gi"
      slots: 4

  # Job 3: ETL Job
  - name: etl-job
    enabled: true
    job:
      jarURI: "local:///opt/flink/usrlib/etl.jar"
      entryClass: "com.example.flink.ETLJob"
      parallelism: 1
```

Then deploy:

```bash
helm upgrade --install flink-autoscale ./charts/flink-autoscale -n flink
```

This creates 3 separate FlinkDeployments, each with its own cluster and autoscaler.

### 3. Check Deployed Jobs

```bash
# View all FlinkDeployments
kubectl get flinkdeployments -n flink

# Example output:
NAME                                  MODE     STATE
flink-autoscale-autoscaling-load     native   RUNNING
flink-autoscale-analytics-pipeline   native   RUNNING
flink-autoscale-etl-job              native   RUNNING

# View all pods
kubectl get pods -n flink

# View all VPAs
kubectl get vpa -n flink
```

### 4. Access Flink UI for Specific Job

The JobManager service is created per job:

```bash
# Port-forward to specific job's UI
kubectl port-forward -n flink svc/flink-autoscale-autoscaling-load-jobmanager 8081:8081

# Or for analytics-pipeline
kubectl port-forward -n flink svc/flink-autoscale-analytics-pipeline-jobmanager 8082:8081
```

## Configuration Reference

### Global Defaults

Set defaults that apply to all jobs unless overridden:

```yaml
defaults:
  image:
    repository: flink
    tag: "1.18-scala_2.12"

  taskManager:
    resources:
      requests:
        cpu: "250m"
        memory: "512Mi"

  autoscaler:
    enabled: true
    targetUtilization: "0.7"
    minParallelism: 1
    maxParallelism: 10

  vpa:
    enabled: true
    updateMode: "Auto"
```

### Per-Job Overrides

Each job can override any default:

```yaml
jobs:
  - name: my-job
    enabled: true

    # Custom image (e.g., with JAR bundled)
    image:
      repository: myregistry/flink-my-job
      tag: "1.0.0"

    # Job specification (Application Mode)
    job:
      jarURI: "local:///opt/flink/usrlib/my-job.jar"
      entryClass: "com.example.MyJob"
      parallelism: 4
      upgradeMode: savepoint
      state: running
      args:
        - "--input"
        - "kafka://topic"

    # Custom resources
    jobManager:
      resources:
        requests:
          cpu: "500m"
          memory: "1Gi"
        limits:
          cpu: "2"
          memory: "2Gi"

    taskManager:
      resources:
        requests:
          cpu: "1"
          memory: "2Gi"
        limits:
          cpu: "4"
          memory: "4Gi"
      slots: 4

    # Custom autoscaler
    autoscaler:
      enabled: true
      targetUtilization: "0.8"
      minParallelism: 2
      maxParallelism: 50
      scaleUpGracePeriod: "30s"
      scaleDownGracePeriod: "5m"

    # Custom VPA
    vpa:
      enabled: true
      updateMode: "Auto"
      controlledResources:
        - "memory"
      minAllowed:
        memory: "1Gi"
      maxAllowed:
        memory: "8Gi"

    # Custom Flink configuration
    flinkConfiguration:
      state.backend: rocksdb
      state.checkpoints.dir: s3://my-bucket/checkpoints
      state.savepoints.dir: s3://my-bucket/savepoints
```

## Common Patterns

### Pattern 1: Session Cluster (No Job)

```yaml
jobs:
  - name: dev-session
    enabled: true
    # No job section = Session Mode
    autoscaler:
      enabled: false  # Disable autoscaler for session mode
    taskManager:
      replicas: 3
      slots: 4
```

Then submit jobs manually via CLI:

```bash
kubectl port-forward -n flink svc/flink-autoscale-dev-session-jobmanager 8081:8081
# Visit http://localhost:8081 and submit JAR via UI
```

### Pattern 2: Different Environments

Use separate values files for different environments:

```bash
# values-dev.yaml
jobs:
  - name: test-job
    enabled: true
    taskManager:
      replicas: 1
    autoscaler:
      maxParallelism: 5

# values-prod.yaml
jobs:
  - name: prod-job
    enabled: true
    taskManager:
      replicas: 3
    autoscaler:
      maxParallelism: 50
      targetUtilization: "0.8"

# Deploy to different namespaces
helm install flink-dev ./charts/flink-autoscale -f values-dev.yaml -n flink-dev
helm install flink-prod ./charts/flink-autoscale -f values-prod.yaml -n flink-prod
```

### Pattern 3: Selective Deployment

Enable/disable jobs without removing configuration:

```yaml
jobs:
  - name: job-1
    enabled: true  # Deployed

  - name: job-2
    enabled: false  # Skipped

  - name: job-3
    enabled: true  # Deployed
```

### Pattern 4: Custom Docker Images per Job

Build separate images for each job:

```yaml
jobs:
  - name: analytics
    enabled: true
    image:
      repository: myregistry/flink-analytics
      tag: "2.1.0"
    job:
      jarURI: "local:///opt/flink/usrlib/analytics.jar"

  - name: etl
    enabled: true
    image:
      repository: myregistry/flink-etl
      tag: "1.5.3"
    job:
      jarURI: "local:///opt/flink/usrlib/etl.jar"
```

## Monitoring Multiple Jobs

### View All Job Status

```bash
# FlinkDeployments
kubectl get flinkdeployments -n flink -o wide

# Pods
kubectl get pods -n flink -l app.kubernetes.io/name=flink-autoscale

# Filter by specific job
kubectl get pods -n flink -l flink-job=autoscaling-load
```

### Monitor Autoscaling

```bash
# Watch FlinkDeployment status
kubectl get flinkdeployments -n flink -w

# View operator logs (autoscaling decisions)
kubectl logs -n flink-operator deployment/flink-kubernetes-operator -f | grep autoscal

# Check specific job's scaling
kubectl describe flinkdeployment -n flink flink-autoscale-analytics-pipeline
```

### Monitor VPA Recommendations

```bash
# View VPA recommendations for all jobs
kubectl get vpa -n flink

# Describe specific VPA
kubectl describe vpa -n flink flink-autoscale-autoscaling-load-taskmanager
```

## Troubleshooting

### Job Not Starting

```bash
# Check FlinkDeployment status
kubectl describe flinkdeployment -n flink flink-autoscale-<job-name>

# Check operator logs
kubectl logs -n flink-operator deployment/flink-kubernetes-operator

# Check JobManager logs
kubectl logs -n flink -l flink-job=<job-name>,component=jobmanager
```

### Autoscaler Not Scaling

```bash
# Verify autoscaler is enabled in FlinkDeployment
kubectl get flinkdeployment -n flink flink-autoscale-<job-name> -o yaml | grep autoscaler

# Check operator logs for scaling decisions
kubectl logs -n flink-operator deployment/flink-kubernetes-operator | grep -i "autoscal.*<job-name>"
```

### VPA Not Updating Resources

```bash
# Check VPA status
kubectl describe vpa -n flink flink-autoscale-<job-name>-taskmanager

# Verify VPA is enabled
helm get values flink-autoscale -n flink
```

## Upgrading Jobs

### Update Single Job

```bash
# Edit values.yaml to change job configuration
# Then upgrade
helm upgrade flink-autoscale ./charts/flink-autoscale -n flink
```

### Zero-Downtime Updates

Use savepoint-based upgrades:

```yaml
jobs:
  - name: my-job
    job:
      upgradeMode: savepoint  # Enables zero-downtime upgrades
```

When you upgrade:

```bash
helm upgrade flink-autoscale ./charts/flink-autoscale -n flink
```

The operator will:
1. Trigger savepoint
2. Stop old job
3. Start new job from savepoint

## Resource Planning

### Memory Calculation

For each job:
- JobManager: ~512Mi-1Gi
- TaskManager: Based on slots and state size
- Example for 3 jobs:
  - Total JobManagers: 3 × 1Gi = 3Gi
  - Total TaskManagers: Variable based on autoscaling

### Namespace Quotas

Set quotas per namespace:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: flink-quota
  namespace: flink
spec:
  hard:
    requests.cpu: "20"
    requests.memory: "40Gi"
    limits.cpu: "40"
    limits.memory: "80Gi"
    persistentvolumeclaims: "10"
```

## Next Steps

1. **Build Custom Images**: Create Docker images with your JARs bundled
2. **Configure State Backend**: Use S3/HDFS for production checkpoints
3. **Set Up Monitoring**: Integrate with Prometheus/Grafana
4. **Add Metrics**: Configure custom metrics for autoscaler
5. **Implement CI/CD**: Automate job deployments with GitOps (ArgoCD, Flux)

## References

- [Flink Operator Autoscaler Docs](https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-main/docs/custom-resource/autoscaler/)
- [FlinkDeployment Reference](https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-main/docs/custom-resource/reference/)
- [Helm Chart Best Practices](https://helm.sh/docs/chart_best_practices/)
