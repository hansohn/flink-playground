# Dockerfile for Kafka Load Producer
# Lightweight JRE image for running the producer JAR

FROM eclipse-temurin:11-jre-jammy

WORKDIR /app

COPY target/kafka-load-producer.jar /app/kafka-load-producer.jar

ENTRYPOINT ["java", "-jar", "/app/kafka-load-producer.jar"]
