# Flink Playground

A local Kubernetes environment for experimenting with [Apache Flink](https://flink.apache.org/) autoscaling, powered by the [Flink Kubernetes Operator](https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-stable/) and managed via [ArgoCD](https://argo-cd.readthedocs.io/) GitOps.

## What's Inside

A [Kind](https://kind.sigs.k8s.io/) cluster running a complete data streaming pipeline with autoscaling and full observability:

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **Flink Kubernetes Operator** | Manages FlinkDeployment CRDs and autoscaling | `flink-operator` |
| **Flink Autoscaling Load Job** | CPU-heavy streaming job that autoscales based on workload metrics | `playground` |
| **Kafka (Strimzi + KRaft)** | Event streaming platform providing input to the Flink job | `kafka` |
| **Kafka Load Producer** | Generates JSON load events at a configurable rate | `playground` |
| **MinIO** | S3-compatible storage for Flink checkpoints and savepoints | `storage` |
| **Prometheus** | Metrics collection and alerting | `monitoring` |
| **Grafana** | Dashboards and visualization (Flink memory monitoring) | `monitoring` |
| **Loki** | Log aggregation | `monitoring` |
| **Tempo** | Distributed tracing | `monitoring` |
| **Alloy** | Unified telemetry collection (logs and traces) | `monitoring` |
| **ArgoCD** | GitOps-driven deployment of all components | `argocd` |

### Architecture

```
Kafka Load Producer ──► Kafka (KRaft) ──► Flink Job ──► stdout
                                              │
                                    ┌─────────┴─────────┐
                                    ▼                   ▼
                              MinIO (S3)          Prometheus
                           checkpoints/            metrics
                           savepoints               │
                                              ┌─────┴─────┐
                                              ▼           ▼
                                           Grafana    Alerting

Logs ──► Alloy ──► Loki
Traces ─► Alloy ──► Tempo
```

The Flink job consumes JSON events from Kafka, applies a CPU-heavy transformation per event, and aggregates results in keyed tumbling windows. The Flink Operator autoscaler monitors job metrics (backpressure, processing rate, lag) and adjusts parallelism and TaskManager replicas to match the workload.

## Prerequisites

- [Docker](https://www.docker.com/)
- [Kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/)
- [Java 11+](https://openjdk.org/)
- [Maven](https://maven.apache.org/)

On macOS, run the setup script to install everything via Homebrew:

```bash
./setup.sh
```

## Quick Start

```bash
# Bootstrap the entire environment (Kind cluster + ArgoCD + all apps)
make up

# Watch ArgoCD sync all applications
make argocd/status

# Port-forward all UIs
make ui
```

Then open:

| UI | URL |
|----|-----|
| ArgoCD | http://localhost:8080 |
| Flink | http://localhost:8081 |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 |

Get the ArgoCD admin password with:

```bash
make argocd/password
```

## Project Structure

```
flink-playground/
├── argocd/                        # ArgoCD App-of-Apps manifests
│   ├── app-of-apps.yaml
│   └── apps/                      # Individual application manifests
├── charts/                        # Helm charts
│   ├── flink-autoscale/           # Flink job deployment + autoscaler
│   ├── kafka/                     # Strimzi Kafka (KRaft mode)
│   ├── kafka-load-producer/       # Kafka event generator
│   ├── minio/                     # S3-compatible state storage
│   ├── prometheus/                # Monitoring
│   ├── grafana/                   # Dashboards
│   ├── loki/                      # Log aggregation
│   ├── tempo/                     # Distributed tracing
│   ├── alloy/                     # Telemetry collection
│   └── metrics-server/            # Kubernetes resource metrics
├── services/                      # Application source code
│   ├── autoscaling-load-job/      # Flink job (Java)
│   └── kafka-load-producer/       # Kafka producer (Java)
├── kind/                          # Kind cluster configuration
├── Makefile                       # All automation targets
└── setup.sh                       # macOS prerequisite installer
```

## Makefile Targets

### Environment

| Target | Description |
|--------|-------------|
| `make up` | Bootstrap entire environment (Kind + ArgoCD + all apps) |
| `make kind/down` | Delete the Kind cluster |
| `make ui` | Port-forward ArgoCD, Flink, Prometheus, and Grafana |
| `make argocd/status` | Show ArgoCD application sync status |
| `make argocd/password` | Get ArgoCD admin password |

### Build

| Target | Description |
|--------|-------------|
| `make maven/build` | Build the Flink job JAR |
| `make maven/build-producer` | Build the Kafka producer JAR |
| `make docker/build` | Build the Flink job Docker image |
| `make docker/build-producer` | Build the Kafka producer Docker image |
| `make kind/load` | Load Docker images into the Kind cluster |

### Cleanup

| Target | Description |
|--------|-------------|
| `make clean/all` | Clean Maven artifacts and delete the cluster |
| `make maven/clean` | Clean Flink job Maven artifacts |
| `make docker/clean` | Remove Flink job Docker image |

Run `make` for the full list of available targets.

## How Autoscaling Works

The Flink Kubernetes Operator autoscaler monitors job-level metrics over a configurable window and adjusts parallelism:

1. **Metrics collection** over a 5-minute window (processing rate, backpressure, lag, busy time)
2. **Utilization calculation** against 70% target
3. **Stabilization** for 1 minute to prevent flapping
4. **Scale up** after 1-minute grace period if utilization exceeds 80%
5. **Scale down** after 3-minute grace period if utilization drops below 60%

Autoscaler settings are configured in `charts/flink-autoscale/values.yaml` under the `autoscaler` section.

## Configuration

### Adjusting Load

The Kafka load producer rate and the Flink job's CPU intensity are the main tuning knobs:

- **Producer rate**: `charts/kafka-load-producer/values.yaml` &rarr; `producer.recordsPerSecond`
- **CPU intensity**: `charts/flink-autoscale/values.yaml` &rarr; job args `--cpu-iterations`

### Multi-Job Support

The `flink-autoscale` chart supports deploying multiple Flink jobs from a single `values.yaml`. See [MULTI_JOB_GUIDE.md](MULTI_JOB_GUIDE.md) for details.

### Custom Docker Images

See [BUILD_GUIDE.md](BUILD_GUIDE.md) for the full build pipeline: Maven JAR, Docker image, Kind loading, and Helm deployment.

## Further Reading

- [BUILD_GUIDE.md](BUILD_GUIDE.md) -- Building custom Flink Docker images
- [MULTI_JOB_GUIDE.md](MULTI_JOB_GUIDE.md) -- Deploying multiple Flink jobs
- [argocd/README.md](argocd/README.md) -- ArgoCD setup and App-of-Apps pattern
- [charts/flink-autoscale/README.md](charts/flink-autoscale/README.md) -- Flink chart configuration
- [charts/kafka/README.md](charts/kafka/README.md) -- Kafka (Strimzi) chart
- [charts/minio/README.md](charts/minio/README.md) -- MinIO S3 storage

## License

This project is for educational and experimental purposes.
