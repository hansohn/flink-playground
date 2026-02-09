# Kafka Load Producer Helm Chart

Deploys a Java-based Kafka producer that generates JSON load events at a configurable rate.
Used to drive realistic autoscaling behavior in the Flink job via Kafka consumer lag.

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `image.repository` | Docker image repository | `hansohn/kafka-load-producer` |
| `image.tag` | Docker image tag | `1.0.0` |
| `replicas` | Number of producer replicas | `1` |
| `producer.bootstrapServers` | Kafka bootstrap servers | `kafka-local-kafka-bootstrap.kafka.svc.cluster.local:9092` |
| `producer.topic` | Target Kafka topic | `load-events` |
| `producer.recordsPerSecond` | Records produced per second per replica | `1000` |
| `producer.keys` | Number of distinct keys | `128` |
| `resources.requests.cpu` | CPU request | `50m` |
| `resources.requests.memory` | Memory request | `128Mi` |
| `resources.limits.cpu` | CPU limit | `250m` |
| `resources.limits.memory` | Memory limit | `256Mi` |

## Scaling

Scale replicas to multiply throughput:

```bash
kubectl scale deployment kafka-load-producer -n playground --replicas=3
```
