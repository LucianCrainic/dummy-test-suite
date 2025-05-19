#!/bin/bash
# This script sets up and runs the Robot Framework tests in Kubernetes

# Color definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${GREEN}==== $1 ====${NC}\n"
}

print_warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

print_error() {
    echo -e "${RED}ERROR: $1${NC}"
}

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed. Please install kubectl first."
    exit 1
fi

# Check if minikube is installed (for local development)
if ! command -v minikube &> /dev/null; then
    print_warning "minikube is not installed. If you're running locally, you might need it."
    sleep 2
fi

# Check if minikube is running
if command -v minikube &> /dev/null; then
    if ! minikube status &> /dev/null; then
        print_warning "minikube is not running. Attempting to start it..."
        minikube start
    else
        print_header "minikube is already running"
    fi
fi

# Parse command line arguments
REPLICAS=5
RESET=false
CLEANUP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --replicas)
            REPLICAS="$2"
            shift
            shift
            ;;
        --reset)
            RESET=true
            shift
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Usage: $0 [--replicas N] [--reset] [--cleanup]"
            exit 1
            ;;
    esac
done

print_header "Setting up Robot Framework parallel test environment in Kubernetes"
echo "Configuration:"
echo "  Parallel pods: $REPLICAS"
echo "  Reset tests:   $RESET"
echo "  Cleanup after: $CLEANUP"

# Check if we need to build the Docker image
print_header "Building Docker image"
docker build -t dummy-test-suite:latest .

# If using minikube, load the image into minikube
if command -v minikube &> /dev/null && minikube status &> /dev/null; then
    print_header "Loading Docker image into minikube"
    minikube image load dummy-test-suite:latest
fi

# Create a temporary directory for shared files if running locally with minikube
if command -v minikube &> /dev/null && minikube status &> /dev/null; then
    print_header "Setting up minikube shared directories"
    
    # Create host folders that will be mounted into pods
    mkdir -p /tmp/robot-tests/tests
    mkdir -p /tmp/robot-tests/results
    mkdir -p /tmp/robot-tests/templates
    
    # Copy test files to the shared directory
    cp -r tests/* /tmp/robot-tests/tests/
    
    # Copy database, API server, and templates
    cp robot_tests.db /tmp/robot-tests/
    cp test_api_server.py /tmp/robot-tests/
    
    # Ensure templates directory exists
    if [ -d "templates" ] && [ -f "templates/dashboard.html" ]; then
        cp -r templates /tmp/robot-tests/
        echo "Dashboard template copied to /tmp/robot-tests/"
    else
        print_warning "Dashboard template not found. Visualization dashboard will not be available."
    fi
    
    echo "Files copied to /tmp/robot-tests/"
fi

# Create namespace if it doesn't exist
print_header "Creating Kubernetes namespace"
kubectl create namespace robot-tests 2>/dev/null || true

# Apply Kubernetes configurations
print_header "Applying Kubernetes configurations"
kubectl apply -f k8s_test_runner_configmap.yaml -n robot-tests
kubectl apply -f k8s_test_runner_deployment.yaml -n robot-tests

# Update replica count if specified
kubectl scale deployment robot-test-runner --replicas=$REPLICAS -n robot-tests

# If reset flag is set, call the API to reset test statuses
if [ "$RESET" = true ]; then
    print_header "Resetting test statuses"
    # Wait for API to be ready
    echo "Waiting for API service to be ready..."
    sleep 10
    
    # Get the API service IP
    API_IP=$(kubectl get service test-api-service -n robot-tests -o jsonpath='{.spec.clusterIP}')
    
    if [ -n "$API_IP" ]; then
        # Forward port to access the API
        kubectl port-forward service/test-api-service 8000:8000 -n robot-tests &
        PORT_FORWARD_PID=$!
        
        # Wait for port forwarding to be established
        sleep 5
        
        # Call the reset API
        curl -X POST http://localhost:8000/api/reset
        
        # Kill port forwarding
        kill $PORT_FORWARD_PID
    else
        print_warning "Could not get API service IP for reset"
    fi
fi

print_header "Tests are now running in Kubernetes"
echo "To monitor test progress, run:"
echo "  kubectl get pods -n robot-tests"
echo "  kubectl logs -f deployment/robot-test-runner -n robot-tests"
echo ""
echo "To access the test visualization dashboard:"
echo "  kubectl port-forward service/test-api-service 8000:8000 -n robot-tests"
echo "Then visit: http://localhost:8000/"
echo ""
echo "For API access only:"
echo "  kubectl port-forward service/test-api-service 8000:8000 -n robot-tests"
echo "Then visit: http://localhost:8000/api/dashboard or http://localhost:8000/api/status"

# Check if we should wait and cleanup
if [ "$CLEANUP" = true ]; then
    print_header "Waiting for tests to complete before cleanup"
    echo "Press Ctrl+C to skip cleanup"
    
    # Simple loop to wait for tests to complete
    while true; do
        running_pods=$(kubectl get pods -n robot-tests -l app=robot-test-runner --field-selector=status.phase=Running --no-headers | wc -l)
        if [ "$running_pods" -eq 0 ]; then
            break
        fi
        echo "Still running: $running_pods pods..."
        sleep 10
    done
    
    print_header "Cleaning up Kubernetes resources"
    kubectl delete -f k8s_test_runner_deployment.yaml -n robot-tests
    kubectl delete -f k8s_test_runner_configmap.yaml -n robot-tests
    
    echo "Cleanup complete."
fi

print_header "Done!"
