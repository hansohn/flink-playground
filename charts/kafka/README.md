# Kafka (Strimzi) Helm Chart

Wrapper chart that deploys the [Strimzi Kafka Operator](https://strimzi.io/) along with a
playground-sized Kafka cluster and a `load-events` topic for the Flink autoscaling demo.

## Components

| Component | Replicas | Requests | Limits |
|-----------|----------|----------|--------|
| Strimzi Operator | 1 | 100m / 256Mi | 500m / 512Mi |
| Kafka Broker | 1 | 250m / 512Mi | 1 / 1Gi |
| ZooKeeper | 1 | 100m / 256Mi | 500m / 512Mi |
| Topic Operator | 1 | 50m / 128Mi | 250m / 256Mi |
| User Operator | 1 | 50m / 128Mi | 250m / 256Mi |

## Topic

- **Name:** `load-events`
- **Partitions:** 3
- **Replication Factor:** 1
- **Retention:** 10 minutes

## Bootstrap Server

From within the cluster:

```
kafka-kafka-bootstrap.<namespace>.svc.cluster.local:9092
```

## Usage

```bash
# Build dependencies
helm dependency build charts/kafka

# Install
helm install kafka charts/kafka -n kafka --create-namespace

# Verify
kubectl get kafka -n kafka
kubectl get kafkatopic -n kafka
```
