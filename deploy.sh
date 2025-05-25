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
    
    # Create directories on minikube VM that will be mounted into pods
    minikube ssh "sudo mkdir -p /tmp/robot-tests/tests"
    minikube ssh "sudo mkdir -p /tmp/robot-tests/results"
    minikube ssh "sudo mkdir -p /tmp/robot-tests/templates"
    minikube ssh "sudo mkdir -p /tmp/robot-tests/shared-outputs"
    
    # Copy test files to the minikube VM
    print_header "Copying test files to minikube VM"
    
    # Create a temporary archive of test files
    tar -czf /tmp/test-files.tar.gz tests/
    
    # Copy the archive to minikube VM and extract it
    minikube cp /tmp/test-files.tar.gz /tmp/test-files.tar.gz
    minikube ssh "cd /tmp && sudo tar -xzf test-files.tar.gz && sudo cp -r tests/* /tmp/robot-tests/tests/ && sudo rm -f test-files.tar.gz || true"
    
    # Copy database and API server files
    minikube cp robot_tests.db /tmp/robot_tests.db
    minikube cp server.py /tmp/server.py
    minikube ssh "sudo mv /tmp/robot_tests.db /tmp/robot-tests/ && sudo mv /tmp/server.py /tmp/robot-tests/"
    
    # Clean up local temp file without failing if permission denied
    rm -f /tmp/test-files.tar.gz 2>/dev/null || true
    
    echo "Files copied to minikube VM at /tmp/robot-tests/"
fi

# Create namespace if it doesn't exist
print_header "Creating Kubernetes namespace"
kubectl create namespace robot-tests 2>/dev/null || true

# Apply Kubernetes configurations
print_header "Applying Kubernetes configurations"
kubectl apply -f worker-deployment.yaml -n robot-tests

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
    
    # Wait for API pod to be ready
    echo "Waiting for API pod to be ready..."
    kubectl wait --for=condition=ready pod -l app=test-api -n robot-tests --timeout=120s
    
    # Make sure no other port forwards are running
    echo "Killing any existing port-forward processes..."
    pkill -f "kubectl port-forward" || true
    sleep 2
    
    # Get API Pod name directly
    API_POD_NAME=$(kubectl get pod -l app=test-api -n robot-tests -o jsonpath='{.items[0].metadata.name}')
    if [ -z "$API_POD_NAME" ]; then
        echo "Failed to find API pod"
        exit 1
    fi
    
    # Start port forwarding directly to the pod
    echo "Setting up port forwarding directly to API pod $API_POD_NAME..."
    kubectl port-forward pod/$API_POD_NAME 8000:8000 -n robot-tests > /dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    
    # Wait for port forwarding to be established
    echo "Waiting for port forwarding to be established..."
    attempt=0
    max_attempts=15
    while [ $attempt -lt $max_attempts ]; do
        if curl -s http://localhost:8000/api/status > /dev/null; then
            echo "Port forwarding established successfully"
            break
        fi
        attempt=$((attempt + 1))
        echo "Attempt $attempt of $max_attempts - waiting for API to become available..."
        sleep 2
    done
    
    if [ $attempt -eq $max_attempts ]; then
        echo "Failed to establish port forwarding after $max_attempts attempts"
        echo "Will use alternative approach to monitor test status"
        kill $PORT_FORWARD_PID 2>/dev/null || true
        
        # Alternative approach: check worker pod status
        echo "Monitoring worker pods status instead..."
        while true; do
            # Check if all tests are completed by looking at the worker pods
            running_pods=$(kubectl get pods -n robot-tests -l app=robot-test-runner --no-headers | grep -v "CrashLoopBackOff" | wc -l)
            if [ "$running_pods" -eq 0 ]; then
                echo "All worker pods completed or are in CrashLoopBackOff state - tests finished"
                break
            fi
            echo "Still $running_pods worker pods running..."
            sleep 10
        done
        USE_ALT_MONITORING=true
    else
        USE_ALT_MONITORING=false
    fi
    
    # Wait for all tests to complete
    if [ "$USE_ALT_MONITORING" = false ]; then
        echo "Monitoring test progress via API..."
        while true; do
            # Get test status from API
            api_response=$(curl -s http://localhost:8000/api/status 2>/dev/null)
            if [ $? -eq 0 ]; then
                total_tests=$(echo "$api_response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('total_tests', 0))" 2>/dev/null)
                completed_count=$(echo "$api_response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status_counts', {}).get('completed', 0))" 2>/dev/null)
                failed_count=$(echo "$api_response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status_counts', {}).get('failed', 0))" 2>/dev/null)
                
                if [ -n "$total_tests" ] && [ -n "$completed_count" ] && [ -n "$failed_count" ]; then
                    processed_tests=$((completed_count + failed_count))
                    if [ "$processed_tests" -ge "$total_tests" ] && [ "$total_tests" -gt 0 ]; then
                        echo "All tests completed! Total: $total_tests, Completed: $completed_count, Failed: $failed_count"
                        break
                    else
                        echo "Tests in progress: $processed_tests/$total_tests completed (Passed: $completed_count, Failed: $failed_count)"
                    fi
                else
                    echo "Waiting for API to respond with test status..."
                fi
            else
                echo "API connection lost, retrying..."
            fi
            sleep 5
        done
        
        # Kill port forwarding
        kill $PORT_FORWARD_PID 2>/dev/null || true
    fi
    
    print_header "Cleaning up Kubernetes resources"
    kubectl delete -f worker-deployment.yaml -n robot-tests
    
    echo "Cleanup complete."
fi

print_header "Done!"
