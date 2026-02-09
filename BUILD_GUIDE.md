# Build Guide: Custom Flink Docker Images

This guide explains how to build custom Flink Docker images with your job JARs bundled, and deploy them to your Kind cluster.

## Overview

The project now supports building custom Docker images that extend the base Flink image and include your job JARs. This eliminates the need to manually copy JARs or mount volumes.

## Architecture

```
┌─────────────────────────────────────────┐
│ 1. Maven Build                          │
│    services/autoscaling-load-job/       │
│    └── target/autoscaling-load-job.jar  │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ 2. Docker Build                         │
│    FROM flink:1.18-scala_2.12           │
│    COPY JAR → /opt/flink/usrlib/        │
│    = flink-autoscaling-load:1.0.0       │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ 3. Load into Kind                       │
│    kind load docker-image ...           │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ 4. Deploy via Helm                      │
│    image: flink-autoscaling-load:1.0.0  │
│    jarURI: local:///opt/flink/usrlib/...│
└─────────────────────────────────────────┘
```

## Quick Start

### One-Command Deployment

The simplest way to build and deploy:

```bash
# Build JAR, build Docker image, load into Kind, and deploy
make up
```

This runs all steps automatically:
1. Creates Kind cluster
2. Installs all dependencies (metrics-server, Prometheus, cert-manager, Flink Operator)
3. Builds Maven JAR
4. Builds Docker image
5. Loads image into Kind
6. Deploys Flink job via Helm

### Step-by-Step

If you want more control:

```bash
# 1. Create cluster and install dependencies
make kind/up
make metrics-server/install
make prometheus/install
make flink-operator/install

# 2. Build Maven JAR
make maven/build

# 3. Build Docker image
make docker/build

# 4. Load image into Kind cluster
make kind/load

# 5. Deploy Flink job
make flink/install
```

## Available Makefile Targets

### Maven Targets

```bash
# Build JAR using Maven
make maven/build

# Clean Maven artifacts
make maven/clean

```

**Output:** `services/autoscaling-load-job/target/autoscaling-load-job.jar`

### Docker Targets

```bash
# Build Docker image (automatically runs maven/build first)
make docker/build

# Load Docker image into Kind cluster
make kind/load

# Remove Docker image
make docker/clean
```

**Output Image:** `flink-autoscaling-load:1.0.0`

### Flink Targets

```bash
# Install Flink (automatically builds and loads image)
make flink/install

# Uninstall Flink
make flink/uninstall

# Reinstall Flink
make flink/reinstall
```

## File Structure

```
services/autoscaling-load-job/
├── pom.xml                    # Maven configuration
├── Dockerfile                 # Docker build instructions
├── .dockerignore             # Docker build context exclusions
├── src/
│   └── main/java/
│       └── com/example/flink/
│           └── AutoscalingLoadJob.java
└── target/
    └── autoscaling-load-job.jar    # Built by Maven
```

## Understanding the Build Process

### 1. Maven Build (pom.xml)

The `pom.xml` is configured to:
- Compile Java 11 code
- Use Maven Shade plugin to create a JAR
- Set the main class to `com.example.flink.AutoscalingLoadJob`
- Exclude Flink dependencies (they're provided by the runtime)

Key configuration:

```xml
<build>
  <finalName>autoscaling-load-job</finalName>
  <plugins>
    <plugin>
      <groupId>org.apache.maven.plugins</groupId>
      <artifactId>maven-shade-plugin</artifactId>
      <configuration>
        <transformers>
          <transformer implementation="...ManifestResourceTransformer">
            <mainClass>com.example.flink.AutoscalingLoadJob</mainClass>
          </transformer>
        </transformers>
      </configuration>
    </plugin>
  </plugins>
</build>
```

### 2. Docker Build (Dockerfile)

The Dockerfile:
- Extends the official Flink image (`flink:1.18-scala_2.12`)
- Copies the JAR to `/opt/flink/usrlib/` (Flink's user library directory)
- Inherits all Flink configurations from base image

```dockerfile
FROM flink:1.18-scala_2.12
COPY target/autoscaling-load-job.jar /opt/flink/usrlib/autoscaling-load-job.jar
```

### 3. Kind Image Loading

Kind requires images to be explicitly loaded:

```bash
kind load docker-image flink-autoscaling-load:1.0.0 --name flink-playground
```

This makes the image available to pods in the Kind cluster without needing a registry.

### 4. Helm Configuration (values.yaml)

The Helm chart references the custom image:

```yaml
jobs:
  - name: autoscaling-load
    image:
      repository: flink-autoscaling-load
      tag: "1.0.0"
      pullPolicy: IfNotPresent
    job:
      jarURI: "local:///opt/flink/usrlib/autoscaling-load-job.jar"
      entryClass: "com.example.flink.AutoscalingLoadJob"
```

## Customization

### Change Image Name or Tag

Edit `Makefile`:

```makefile
DOCKER_IMAGE_NAME := my-custom-flink-job
DOCKER_IMAGE_TAG := 2.0.0
```

Then update `values.yaml`:

```yaml
image:
  repository: my-custom-flink-job
  tag: "2.0.0"
```

### Add Dependencies

Edit `services/autoscaling-load-job/pom.xml`:

```xml
<dependencies>
  <!-- Existing Flink dependencies -->

  <!-- Add your dependency -->
  <dependency>
    <groupId>com.example</groupId>
    <artifactId>my-library</artifactId>
    <version>1.0.0</version>
  </dependency>
</dependencies>
```

Then rebuild:

```bash
make docker/build && make kind/load
make flink/reinstall
```

### Change Flink Version

Edit `services/autoscaling-load-job/Dockerfile`:

```dockerfile
ARG FLINK_VERSION=1.19-scala_2.12
FROM flink:${FLINK_VERSION}
```

And update `pom.xml`:

```xml
<properties>
  <flink.version>1.19.0</flink.version>
</properties>
```

## Building Multiple Job Images

### Create Additional Jobs

```bash
# Create new job directory
mkdir -p services/analytics-job
cd services/analytics-job

# Copy template
cp ../autoscaling-load-job/pom.xml .
cp ../autoscaling-load-job/Dockerfile .

# Edit pom.xml to change artifact name and main class
# Edit Dockerfile to change JAR name
# Create your Java source files
```

### Build Multiple Images

You can add more Makefile targets:

```makefile
# Analytics job
ANALYTICS_IMAGE := flink-analytics:1.0.0

docker/build-analytics:
	cd services/analytics-job && mvn clean package
	cd services/analytics-job && docker build -t $(ANALYTICS_IMAGE) .
	kind load docker-image $(ANALYTICS_IMAGE) --name $(CLUSTER_NAME)
```

Then add to `values.yaml`:

```yaml
jobs:
  - name: autoscaling-load
    image:
      repository: flink-autoscaling-load
      tag: "1.0.0"
    # ...

  - name: analytics
    enabled: true
    image:
      repository: flink-analytics
      tag: "1.0.0"
    job:
      jarURI: "local:///opt/flink/usrlib/analytics.jar"
      entryClass: "com.example.flink.Analytics"
```

## Troubleshooting

### Issue: JAR Not Found

**Error:**
```
java.io.FileNotFoundException: /opt/flink/usrlib/autoscaling-load-job.jar
```

**Solution:**
1. Verify Maven build succeeded: `ls -la services/autoscaling-load-job/target/`
2. Verify Docker image has JAR:
   ```bash
   docker run --rm flink-autoscaling-load:1.0.0 ls -la /opt/flink/usrlib/
   ```
3. Rebuild and reload:
   ```bash
   make docker/build && make kind/load
   make flink/reinstall
   ```

### Issue: Image Pull Error

**Error:**
```
ImagePullBackOff: Failed to pull image "flink-autoscaling-load:1.0.0"
```

**Solution:**
The image wasn't loaded into Kind. Run:
```bash
make kind/load
```

Verify image is in Kind:
```bash
docker exec -it flink-playground-control-plane crictl images | grep flink-autoscaling
```

### Issue: Wrong Image Version Running

**Problem:** Updated code but seeing old behavior.

**Solution:**
1. Update image tag in `Makefile` and `values.yaml`
2. Rebuild and redeploy:
   ```bash
   make docker/clean
   make docker/build && make kind/load
   make flink/reinstall
   ```

Or use `imagePullPolicy: Always` in `values.yaml` (not recommended for local dev).

### Issue: Maven Build Fails

**Error:**
```
[ERROR] Failed to execute goal... compilation failure
```

**Solution:**
1. Check Java version: `java -version` (needs Java 11)
2. Clean and rebuild:
   ```bash
   make maven/clean
   make maven/build
   ```
3. Check for syntax errors in Java source

### Issue: Docker Build Fails

**Error:**
```
COPY failed: file not found in build context
```

**Solution:**
The JAR hasn't been built yet. Run:
```bash
make maven/build
make docker/build
```

## Development Workflow

### Iterative Development

```bash
# 1. Edit Java code
vim services/autoscaling-load-job/src/main/java/com/example/flink/AutoscalingLoadJob.java

# 2. Rebuild JAR
make maven/build

# 3. Rebuild Docker image
make docker/build

# 4. Reload into Kind
make kind/load

# 5. Restart Flink job
make flink/reinstall

# Or do all at once:
make docker/build && make kind/load && make flink/reinstall
```

### Testing Locally Without Kubernetes

```bash
# Build JAR
make maven/build

# Run directly with Flink
cd services/autoscaling-load-job
java -cp target/autoscaling-load-job.jar com.example.flink.AutoscalingLoadJob
```

## Production Deployment

For production, push images to a container registry:

```bash
# Tag for registry
docker tag flink-autoscaling-load:1.0.0 myregistry.com/flink-autoscaling-load:1.0.0

# Push to registry
docker push myregistry.com/flink-autoscaling-load:1.0.0

# Update values.yaml
# image:
#   repository: myregistry.com/flink-autoscaling-load
#   tag: "1.0.0"
#   pullPolicy: Always
```

## Next Steps

1. **Add Tests**: Create unit tests in `src/test/java/`
2. **CI/CD Integration**: Automate builds with GitHub Actions/Jenkins
3. **Multi-Stage Builds**: Optimize Dockerfile with multi-stage builds
4. **Version Management**: Use semantic versioning for images
5. **Registry Integration**: Push to Docker Hub, ECR, GCR, etc.

## References

- [Maven Shade Plugin](https://maven.apache.org/plugins/maven-shade-plugin/)
- [Flink Docker Images](https://hub.docker.com/_/flink)
- [Kind Loading Images](https://kind.sigs.k8s.io/docs/user/quick-start/#loading-an-image-into-your-cluster)
- [Dockerfile Best Practices](https://docs.docker.com/develop/develop-images/dockerfile_best-practices/)
