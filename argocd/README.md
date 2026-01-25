# ArgoCD Setup

This directory contains ArgoCD Application manifests for managing the Flink Playground infrastructure using GitOps.

## Overview

The setup uses ArgoCD's "App of Apps" pattern to manage all components:

- **metrics-server**: Kubernetes metrics server for resource metrics
- **prometheus**: Monitoring and metrics collection
- **vertical-pod-autoscaler**: VPA for automatic resource recommendations
- **cert-manager**: Certificate management (required by Flink Operator)
- **flink-kubernetes-operator**: Apache Flink Kubernetes Operator
- **flink-autoscale**: Flink autoscaling application

## Directory Structure

```
argocd/
├── README.md                    # This file
├── app-of-apps.yaml            # Main App of Apps manifest
└── apps/                        # Individual application manifests
    ├── metrics-server.yaml
    ├── prometheus.yaml
    ├── vpa.yaml
    ├── cert-manager.yaml
    ├── flink-operator.yaml
    └── flink-autoscale.yaml
```

## Prerequisites

Before using ArgoCD, you need to:

1. **Update Git repository URLs**: Replace `YOUR_USERNAME` in all Application manifests with your actual GitHub username or organization
2. **Push code to Git**: ArgoCD needs to pull from a Git repository, so ensure your code is committed and pushed

## Quick Start

### 1. Update Repository URLs

Update the `repoURL` field in the following files:
- `argocd/app-of-apps.yaml`
- `argocd/apps/metrics-server.yaml`
- `argocd/apps/prometheus.yaml`
- `argocd/apps/vpa.yaml`
- `argocd/apps/flink-autoscale.yaml`

Replace:
```yaml
repoURL: https://github.com/YOUR_USERNAME/flink-playground.git
```

With your actual repository URL:
```yaml
repoURL: https://github.com/yourusername/flink-playground.git
```

### 2. Bootstrap Environment

```bash
# Start the entire environment with ArgoCD
make up
```

This will:
1. Create the Kind cluster
2. Install ArgoCD
3. Deploy all applications via ArgoCD

### 3. Access ArgoCD UI

```bash
# Get the admin password
make argocd/password

# Port forward to ArgoCD UI
make argocd/ui

# Visit http://localhost:8080
# Username: admin
# Password: (from argocd/password command)
```

## Makefile Commands

### ArgoCD Management

- `make argocd/install` - Install ArgoCD
- `make argocd/uninstall` - Uninstall ArgoCD
- `make argocd/deploy-apps` - Deploy all applications
- `make argocd/status` - Show ArgoCD application status
- `make argocd/ui` - Port forward to ArgoCD UI
- `make argocd/password` - Get ArgoCD admin password

### Environment Management

- `make up` - Bootstrap entire environment with ArgoCD (recommended)
- `make up-legacy` - Bootstrap without ArgoCD (legacy direct install)
- `make down` - Tear down entire environment
- `make status` - Show cluster status

## How It Works

### App of Apps Pattern

The `app-of-apps.yaml` manifest creates a parent ArgoCD Application that manages all child applications in the `argocd/apps/` directory. This provides:

- **Single entry point**: Deploy all apps with one command
- **Automatic syncing**: Apps auto-sync when changes are pushed to Git
- **Self-healing**: Apps automatically recover from drift
- **Dependency management**: Apps can depend on each other

### Application Sync Policies

All applications are configured with:

```yaml
syncPolicy:
  automated:
    prune: true      # Delete resources when removed from Git
    selfHeal: true   # Auto-sync when drift is detected
  syncOptions:
    - CreateNamespace=true  # Auto-create namespaces
  retry:
    limit: 5
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 3m
```

## Deployment Dependencies

Applications have the following dependencies:

1. **cert-manager** (first)
2. **flink-kubernetes-operator** (depends on cert-manager)
3. **metrics-server, prometheus, vpa** (parallel)
4. **flink-autoscale** (depends on flink-operator)

ArgoCD handles these dependencies automatically through sync waves or manual ordering.

## Troubleshooting

### Application Not Syncing

Check application status:
```bash
kubectl get applications -n argocd
kubectl describe application <app-name> -n argocd
```

### Sync Failed

View sync status in ArgoCD UI or check events:
```bash
kubectl get events -n argocd --sort-by='.lastTimestamp'
```

### Repository Access Issues

If ArgoCD can't access your Git repository:
1. Ensure the repository is public, or configure credentials
2. Verify the repository URL is correct
3. Check ArgoCD has network access to GitHub

## Managing the Environment

All components are now exclusively managed through ArgoCD:

```bash
# Start the entire environment
make up

# Tear down the entire environment
make down

# Check ArgoCD application status
make argocd/status

# Check overall cluster status
make status
```

## Next Steps

1. Update repository URLs in all manifests
2. Commit and push changes to Git
3. Run `make up` to bootstrap with ArgoCD
4. Access ArgoCD UI to monitor deployments
5. Make changes to charts and push to Git - ArgoCD will auto-sync

## Additional Resources

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [App of Apps Pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [ArgoCD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)
