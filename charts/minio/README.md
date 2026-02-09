# MinIO Helm Chart

MinIO S3-compatible object storage for Flink state backend (checkpoints and savepoints).

## Overview

This chart provides MinIO as a local S3-compatible storage solution for the Flink POC environment. It wraps the official [MinIO Helm chart](https://github.com/minio/minio/tree/master/helm/minio) with pre-configured values suitable for local development and testing.

## Features

- **S3-Compatible Storage**: Provides an S3 API for Flink state backend
- **Pre-created Bucket**: Automatically creates `flink-state` bucket for Flink
- **Lightweight**: Standalone mode with minimal resource requirements (~100MB RAM)
- **POC-Friendly**: Simple credentials and configuration for local testing
- **Production-Ready Pattern**: Same configuration as AWS S3, just change the endpoint

## Configuration

Key configuration values (see `values.yaml`):

```yaml
minio:
  mode: standalone         # Single instance for POC
  rootUser: admin         # Default credentials (stored in Kubernetes Secret)
  rootPassword: password123

  persistence:
    size: 10Gi            # Storage size for Kind cluster

  buckets:
    - name: flink-state   # Pre-created for Flink

  # Credentials are stored in Kubernetes Secret (see templates/secret.yaml)
  existingSecret: minio-credentials
```

**Security Note**: Credentials are stored in a Kubernetes Secret (`minio-credentials`) created by this chart. For production deployments, consider using external secret management solutions like:
- AWS Secrets Manager with [External Secrets Operator](https://external-secrets.io/)
- HashiCorp Vault
- Azure Key Vault
- Google Secret Manager

## Deployment

MinIO is deployed to the **`storage` namespace** (separate from Flink workloads) for better separation of concerns. Flink accesses MinIO via cross-namespace DNS resolution.

## Usage with Flink

The MinIO endpoint is automatically available at:
- **Internal**: `http://minio.storage.svc.cluster.local:9000` (accessible from any namespace)
- **Console UI**: Port-forward 9001 to access web UI

Flink configuration (in `flink-autoscale` values):
```yaml
# S3 credentials stored in Kubernetes Secret and injected as environment variables
s3:
  accessKey: admin
  secretKey: password123

flinkConfiguration:
  state.checkpoints.dir: s3://flink-state/checkpoints/autoscaling-load
  state.savepoints.dir: s3://flink-state/savepoints/autoscaling-load
  s3.endpoint: http://minio.storage.svc.cluster.local:9000
  s3.path.style.access: "true"
  s3.connection.ssl.enabled: "false"
  # S3 credentials injected via AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY env vars
```

**Note**: By default, Kubernetes allows cross-namespace service access via DNS. No additional RBAC or NetworkPolicies are required for Flink pods to access MinIO service in the `storage` namespace.

## Accessing MinIO

### Retrieving Credentials
```bash
# Get the root username
kubectl get secret minio-credentials -n storage -o jsonpath='{.data.rootUser}' | base64 -d && echo

# Get the root password
kubectl get secret minio-credentials -n storage -o jsonpath='{.data.rootPassword}' | base64 -d && echo
```

### Web UI
```bash
kubectl port-forward -n storage svc/minio-console 9001:9001
# Open http://localhost:9001
# Login: admin / password123 (default credentials from values.yaml)
```

### MinIO Client (mc)
```bash
# Inside the MinIO pod
kubectl exec -n storage deployment/minio -- sh -c \
  "mc alias set local http://localhost:9000 admin password123 && \
   mc ls local/flink-state/"

# From playground namespace (cross-namespace access)
kubectl exec -n playground deployment/flink-autoscale-autoscaling-load -- \
  curl -I http://minio.storage.svc.cluster.local:9000/flink-state/
```

## Migration to Production

When moving to production AWS S3, only update these values in Flink configuration:

```yaml
flinkConfiguration:
  s3.endpoint: https://s3.us-east-1.amazonaws.com
  s3.path.style.access: "false"
  s3.access-key: <AWS_ACCESS_KEY_ID>
  s3.secret-key: <AWS_SECRET_ACCESS_KEY>
  s3.connection.ssl.enabled: "true"
```

No code changes required in Flink jobs!

## Resources

- **CPU**: 100m request, 500m limit
- **Memory**: 256Mi request, 512Mi limit
- **Storage**: 10Gi PVC (Kind local-path provisioner)

## Dependencies

- MinIO Helm chart v5.4.0 from https://charts.min.io/

## Notes

- This is for **POC/development only** - use managed S3 (AWS, GCS, Azure) in production
- Credentials are intentionally simple for POC - secure properly for any shared environments
- Single-instance mode has no redundancy - data survives pod restarts but not node failures
