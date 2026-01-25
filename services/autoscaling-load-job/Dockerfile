# Dockerfile for Flink Autoscaling Load Job
# Extends the base Flink image and adds the job JAR

ARG FLINK_VERSION=1.18-scala_2.12
FROM flink:${FLINK_VERSION}

# Set working directory
WORKDIR /opt/flink

# Copy the job JAR to the usrlib directory
# This directory is automatically added to Flink's classpath
COPY target/autoscaling-load-job.jar /opt/flink/usrlib/autoscaling-load-job.jar

# Optional: Set maintainer label
LABEL maintainer="your-email@example.com"
LABEL description="Flink job for testing autoscaling with synthetic load"
LABEL version="1.0.0"

# The base Flink image already has the correct USER and ENTRYPOINT
# No need to override them
