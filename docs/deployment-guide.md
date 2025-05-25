# Deployment Guide

This guide provides detailed instructions for deploying and running the Robot Framework parallel test suite.

## Prerequisites

### System Requirements
- **Kubernetes Cluster**: minikube (local) or cloud-based cluster
- **Docker**: For building container images
- **kubectl**: Kubernetes command-line tool
- **Python 3.11+**: For local development and testing

### Local Development (Minikube)
```bash
# Install minikube
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-darwin-amd64
sudo install minikube-darwin-amd64 /usr/local/bin/minikube

# Start minikube
minikube start

# Verify installation
kubectl cluster-info
```

## Quick Start

### 1. Parse Tests and Create Database
```bash
# Parse all Robot Framework tests
python parser.py ./tests

# Verify tests were parsed
python parser.py ./tests --list
```

### 2. Deploy to Kubernetes
```bash
# Basic deployment with 5 worker pods
./deploy.sh

# Deploy with custom replica count
./deploy.sh --replicas 10

# Deploy with test reset (clears previous results)
./deploy.sh --replicas 5 --reset

# Deploy with automatic cleanup after completion
./deploy.sh --replicas 3 --cleanup
```

### 3. Monitor Execution
```bash
# Watch pod status
kubectl get pods -n robot-tests -w

# Check API server logs
kubectl logs -l app=test-api -n robot-tests -f

# Monitor worker pod logs
kubectl logs -l app=robot-test-runner -n robot-tests -f

# Check test progress via API
curl http://localhost:8000/api/status
```

### 4. Retrieve Results
Results are automatically copied to `./merged-results/` when using `--cleanup` flag.

Manual retrieval:
```bash
# Copy from minikube
minikube cp /tmp/robot-tests/merged-results ./merged-results

# Or use kubectl
kubectl cp robot-tests/<merger-pod>:/merged-results ./merged-results
```

## Detailed Deployment Steps

### Step 1: Environment Preparation

#### Check Kubernetes Connectivity
```bash
kubectl cluster-info
kubectl get nodes
```

#### Verify Docker
```bash
docker --version
docker info
```

### Step 2: Build Container Image

The deployment script automatically builds the Docker image:
```bash
docker build -t dummy-test-suite:latest .
```

For minikube, the image is loaded automatically:
```bash
minikube image load dummy-test-suite:latest
```

### Step 3: Database Initialization

Parse test files and create the database:
```bash
python parser.py ./tests
```

This creates `robot_tests.db` with:
- Test case metadata
- Execution tracking tables
- Initial test status (all pending)

### Step 4: Kubernetes Deployment

#### Namespace Creation
```bash
kubectl create namespace robot-tests
```

#### Deploy API Server
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-api
  namespace: robot-tests
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-api
  template:
    metadata:
      labels:
        app: test-api
    spec:
      containers:
      - name: test-api
        image: python:3.9-slim
        ports:
        - containerPort: 8000
        command: ["python", "/app/server.py"]
```

#### Deploy Worker Pods
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: robot-test-runner
  namespace: robot-tests
spec:
  replicas: 5  # Configurable
  selector:
    matchLabels:
      app: robot-test-runner
  template:
    metadata:
      labels:
        app: robot-test-runner
    spec:
      containers:
      - name: runner
        image: dummy-test-suite:latest
        env:
        - name: API_BASE_URL
          value: "http://test-api-service:8000"
        command: ["python3", "/app/worker.py"]
```

### Step 5: Monitor and Validate

#### Check Deployment Status
```bash
# Verify all pods are running
kubectl get pods -n robot-tests

# Check services
kubectl get services -n robot-tests

# Verify deployments
kubectl get deployments -n robot-tests
```

#### Access API Server
```bash
# Port forward to access API locally
kubectl port-forward service/test-api-service 8000:8000 -n robot-tests

# Check status
curl http://localhost:8000/api/status
```

## Configuration Options

### Deployment Script Parameters

| Parameter | Description | Default | Example |
|-----------|-------------|---------|---------|
| `--replicas N` | Number of worker pods | 5 | `--replicas 10` |
| `--reset` | Reset test statuses to pending | false | `--reset` |
| `--cleanup` | Auto-cleanup and merge results | false | `--cleanup` |

### Environment Variables

#### API Server Configuration
```bash
TEST_DB_PATH="/app/robot_tests.db"
TEMPLATES_DIR="/app/templates"
```

#### Worker Configuration
```bash
API_BASE_URL="http://test-api-service:8000"
NODE_ID="<pod-name>"
TESTS_DIR="/tests"
RESULTS_DIR="/results"
SHARED_OUTPUTS_DIR="/shared-outputs"
```

#### Merger Configuration
```bash
SHARED_OUTPUTS_DIR="/shared-outputs"
MERGED_RESULTS_DIR="/merged-results"
DATABASE_PATH="/app/robot_tests.db"
POLLING_INTERVAL="10"
```

### Volume Mounts (Minikube)

```yaml
volumes:
- name: test-data
  hostPath:
    path: /tmp/robot-tests
    type: DirectoryOrCreate
- name: shared-outputs
  hostPath:
    path: /tmp/robot-tests/shared-outputs
    type: DirectoryOrCreate
```

## Advanced Configuration

### Custom Resource Limits
```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

### Persistent Storage (Production)
```yaml
volumes:
- name: test-storage
  persistentVolumeClaim:
    claimName: test-results-pvc
```

### Security Context
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
```

## Scaling and Performance

### Horizontal Scaling
```bash
# Scale worker pods
kubectl scale deployment robot-test-runner --replicas=20 -n robot-tests

# Or use the deployment script
./deploy.sh --replicas 20
```

### Performance Tuning

#### Optimal Replica Count
- **CPU-bound tests**: replicas = 2 × CPU cores
- **I/O-bound tests**: replicas = 4 × CPU cores
- **Network-bound tests**: Start with 10 replicas

#### Resource Allocation
```yaml
resources:
  requests:
    memory: "512Mi"  # Increase for memory-intensive tests
    cpu: "500m"      # Increase for CPU-intensive tests
  limits:
    memory: "1Gi"
    cpu: "1000m"
```

## Troubleshooting

### Common Issues and Solutions

#### 1. Pods Stuck in Pending State
```bash
# Check node resources
kubectl describe nodes

# Check pod events
kubectl describe pod <pod-name> -n robot-tests
```

**Solution**: Ensure sufficient cluster resources or reduce replica count.

#### 2. Database Connection Errors
```bash
# Check API server logs
kubectl logs -l app=test-api -n robot-tests
```

**Common causes**:
- Missing database file
- Incorrect volume mounts
- Permission issues

#### 3. Worker Pods Can't Reach API
```bash
# Test service connectivity
kubectl exec -it <worker-pod> -n robot-tests -- curl http://test-api-service:8000/api/status
```

**Solution**: Verify service configuration and network policies.

#### 4. Test Execution Failures
```bash
# Check individual worker logs
kubectl logs <worker-pod> -n robot-tests

# Check shared storage
kubectl exec -it <worker-pod> -n robot-tests -- ls -la /shared-outputs
```

### Debugging Commands

#### Pod Information
```bash
# Get all pods with details
kubectl get pods -n robot-tests -o wide

# Describe specific pod
kubectl describe pod <pod-name> -n robot-tests

# Get pod logs with timestamps
kubectl logs <pod-name> -n robot-tests --timestamps
```

#### Service Debugging
```bash
# Test service endpoints
kubectl get endpoints -n robot-tests

# Port forward for debugging
kubectl port-forward service/test-api-service 8000:8000 -n robot-tests
```

#### Storage Debugging
```bash
# Check volume mounts
kubectl exec -it <pod-name> -n robot-tests -- df -h

# List shared directory contents
kubectl exec -it <pod-name> -n robot-tests -- ls -la /shared-outputs
```

## Cleanup

### Complete Cleanup
```bash
# Delete namespace (removes all resources)
kubectl delete namespace robot-tests

# Stop port forwarding
pkill -f "kubectl port-forward"

# Clean up minikube volumes (if needed)
minikube ssh "sudo rm -rf /tmp/robot-tests"
```

### Partial Cleanup
```bash
# Delete specific deployments
kubectl delete deployment test-api robot-test-runner -n robot-tests

# Delete services
kubectl delete service test-api-service -n robot-tests

# Reset database (keep namespace)
curl -X POST http://localhost:8000/api/reset
```

## Production Considerations

### High Availability
- Use multiple API server replicas with load balancer
- Implement database clustering (PostgreSQL)
- Use persistent storage for critical data

### Security
- Implement RBAC for service accounts
- Use network policies to restrict pod communication
- Secure database connections with TLS

### Monitoring
- Integrate with Prometheus/Grafana
- Set up alerting for failed tests
- Monitor resource utilization

### Backup and Recovery
- Regular database backups
- Result archival strategy
- Disaster recovery procedures

This deployment guide provides comprehensive instructions for running the Robot Framework parallel test suite in various environments, from local development to production clusters.
