# Flink Autoscale Helm Chart

Multi-job Flink deployment with Kubernetes Operator autoscaling support.

## Overview

This chart deploys Apache Flink jobs in Application Mode using the [Flink Kubernetes Operator](https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-stable/). Each job runs as a separate FlinkDeployment with:

- **Native Kubernetes Mode**: Dynamic TaskManager provisioning based on workload
- **Horizontal Autoscaling**: Flink Operator autoscaler adjusts parallelism based on metrics
- **S3-Compatible State Storage**: RocksDB state backend with checkpoints/savepoints on MinIO or AWS S3
- **Prometheus Metrics**: Built-in metrics export for monitoring and alerting

## Features

- **Multi-Job Support**: Define multiple Flink jobs in a single values.yaml
- **Autoscaling**: Kubernetes Operator autoscaler with configurable target utilization
- **State Persistence**: S3-compatible object storage for durable checkpoints and savepoints
- **Security**: Credentials stored in Kubernetes Secrets (not hardcoded)
- **Production-Ready**: Easy migration from MinIO (POC) to AWS S3 (production)

## Configuration

### S3 Credentials (Kubernetes Secrets)

S3 credentials are stored in Kubernetes Secrets and injected as environment variables (`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`). This follows AWS SDK conventions and works with both MinIO and AWS S3.

**Default credentials (values.yaml):**
```yaml
defaults:
  s3:
    accessKey: admin
    secretKey: password123
```

**Per-job override:**
```yaml
jobs:
  - name: my-job
    s3:
      accessKey: prod-access-key
      secretKey: prod-secret-key
```

**Retrieving credentials from cluster:**
```bash
# Get S3 access key
kubectl get secret flink-autoscale-autoscaling-load-s3-credentials -n flink \
  -o jsonpath='{.data.s3\.access-key}' | base64 -d && echo

# Get S3 secret key
kubectl get secret flink-autoscale-autoscaling-load-s3-credentials -n flink \
  -o jsonpath='{.data.s3\.secret-key}' | base64 -d && echo
```

**Production security best practices:**
- Use external secret management (AWS Secrets Manager, HashiCorp Vault, etc.)
- Rotate credentials regularly
- Use IAM roles for AWS deployments (no credentials needed)
- Enable encryption at rest for Secrets

### Flink Configuration

Each job can define custom Flink configuration:

```yaml
jobs:
  - name: my-job
    flinkConfiguration:
      state.backend.type: rocksdb
      state.backend.incremental: "true"
      state.checkpoints.dir: s3://bucket/checkpoints/my-job
      state.savepoints.dir: s3://bucket/savepoints/my-job
      s3.endpoint: http://minio.storage.svc.cluster.local:9000
      s3.path.style.access: "true"
      s3.connection.ssl.enabled: "false"
      execution.checkpointing.interval: "30s"
```

**Note**: Do not include `s3.access-key` or `s3.secret-key` in `flinkConfiguration`. These are automatically injected from the Kubernetes Secret.

### Autoscaler Configuration

Configure autoscaling behavior per job:

```yaml
jobs:
  - name: my-job
    autoscaler:
      enabled: true
      targetUtilization: "0.7"          # Scale when utilization crosses 70%
      minParallelism: 1
      maxParallelism: 10
      metricsWindow: "5m"               # Metrics collection window
      stabilizationInterval: "1m"       # Prevent flapping
      scaleUpGracePeriod: "1m"          # Wait before scaling up
      scaleDownGracePeriod: "3m"        # Wait before scaling down
```

## Deployment

### Via ArgoCD (Recommended)
```bash
# Deploy via ArgoCD Application
kubectl apply -f argocd/apps/flink-autoscale.yaml

# Check sync status
kubectl get application flink-autoscale -n argocd
```

### Via Helm (Manual)
```bash
# Install chart with dependencies
helm dependency update charts/flink-autoscale
helm install flink-autoscale charts/flink-autoscale -n flink --create-namespace

# Upgrade after changes
helm upgrade flink-autoscale charts/flink-autoscale -n flink
```

## Migration to Production AWS S3

To migrate from MinIO (POC) to AWS S3 (production):

1. **Update S3 credentials** (use AWS access keys or IAM roles):
```yaml
jobs:
  - name: my-job
    s3:
      accessKey: <AWS_ACCESS_KEY_ID>
      secretKey: <AWS_SECRET_ACCESS_KEY>
```

2. **Update Flink configuration**:
```yaml
jobs:
  - name: my-job
    flinkConfiguration:
      s3.endpoint: https://s3.us-east-1.amazonaws.com
      s3.path.style.access: "false"
      s3.connection.ssl.enabled: "true"
      state.checkpoints.dir: s3://my-bucket/checkpoints/my-job
      state.savepoints.dir: s3://my-bucket/savepoints/my-job
```

3. **For IAM roles (recommended)**, remove credentials and use [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html):
```yaml
# Add annotation to ServiceAccount
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/flink-s3-role
```

## Monitoring

### Flink UI
```bash
make flink/ui
# Visit http://localhost:8081
```

### Prometheus Metrics
Flink pods expose metrics on port 9249:
```bash
# Query metrics from TaskManager pod
kubectl exec -n flink <taskmanager-pod> -- curl http://localhost:9249/
```

### Logs
```bash
# JobManager logs
make logs/flink-jm

# TaskManager logs
make logs/flink-tm

# All Flink logs
make logs/flink
```

## Troubleshooting

### Verify S3 Credentials
```bash
# Check if secret exists
kubectl get secret flink-autoscale-autoscaling-load-s3-credentials -n flink

# Verify environment variables in pod
kubectl exec -n flink <pod> -- env | grep AWS
```

### Check Checkpoint Status
```bash
# View Flink logs for checkpoint activity
kubectl logs -n flink <jobmanager-pod> | grep -i checkpoint

# List checkpoints in MinIO
kubectl exec -n storage deployment/minio -- mc ls --recursive local/flink-state/checkpoints/
```

### FlinkDeployment Status
```bash
# Check deployment status
kubectl get flinkdeployment -n flink

# Describe for detailed events
kubectl describe flinkdeployment flink-autoscale-autoscaling-load -n flink
```

## Resources

- [Flink Kubernetes Operator Documentation](https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-stable/)
- [Flink S3 Filesystem Documentation](https://nightlies.apache.org/flink/flink-docs-stable/docs/deployment/filesystems/s3/)
- [Flink State Backends](https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/state/state_backends/)
