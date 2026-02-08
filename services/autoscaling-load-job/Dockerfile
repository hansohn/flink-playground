# Dockerfile for Flink Autoscaling Load Job
# Extends the base Flink image and adds the job JAR

ARG FLINK_VERSION=1.18-scala_2.12
FROM flink:${FLINK_VERSION}

# Set working directory
WORKDIR /opt/flink

# Enable S3 filesystem plugin for MinIO/S3 support
# The base Flink image includes S3 jars in /opt/flink/opt/
# We need to move them to /opt/flink/plugins/ for Flink to load them
RUN mkdir -p /opt/flink/plugins/s3-fs-hadoop && \
    cp /opt/flink/opt/flink-s3-fs-hadoop-*.jar /opt/flink/plugins/s3-fs-hadoop/

# Download OpenTelemetry Java agent for automatic tracing instrumentation
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar /opt/flink/lib/opentelemetry-javaagent.jar

# Copy the job JAR to the usrlib directory
# This directory is automatically added to Flink's classpath
COPY target/autoscaling-load-job.jar /opt/flink/usrlib/autoscaling-load-job.jar

# Optional: Set maintainer label
LABEL maintainer="your-email@example.com"
LABEL description="Flink job for testing autoscaling with synthetic load"
LABEL version="1.0.0"

# The base Flink image already has the correct USER and ENTRYPOINT
# No need to override them
