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
MONITOR_ONLY=false
SIMPLE_LOG=false

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
        --monitor-only)
            MONITOR_ONLY=true
            shift
            ;;
        --simple-log)
            SIMPLE_LOG=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Usage: $0 [--replicas N] [--reset] [--cleanup] [--monitor-only] [--simple-log]"
            exit 1
            ;;
    esac
done

print_header "Setting up Robot Framework parallel test environment in Kubernetes"
echo "Configuration:"
echo "  Parallel pods: $REPLICAS"
echo "  Reset tests:   $RESET"
echo "  Cleanup after: $CLEANUP"
echo "  Monitor only:  $MONITOR_ONLY"
echo "  Simple log:    $SIMPLE_LOG"

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

# Function to monitor tests without cleanup
# Usage: monitor_tests [quiet_mode]
# If quiet_mode is "quiet", less verbose output will be shown
monitor_tests() {
    local quiet_mode=${1:-""}
    
    if [ "$quiet_mode" != "quiet" ]; then
        print_header "Monitoring test execution in real-time"
        echo "Press Ctrl+C to stop monitoring"
    fi
    
    # Create a log file for test completions
    TEST_LOG_FILE="test_execution_log_$(date +%Y%m%d_%H%M%S).txt"
    echo "Test Execution Log - Started at $(date)" > "$TEST_LOG_FILE"
    echo "----------------------------------------" >> "$TEST_LOG_FILE"
    echo "" >> "$TEST_LOG_FILE"
    echo "Tests Completed:" >> "$TEST_LOG_FILE"
    echo "----------------" >> "$TEST_LOG_FILE"
    echo "" >> "$TEST_LOG_FILE"
    
    if [ "$quiet_mode" != "quiet" ]; then
        echo "Recording all test completions to: $TEST_LOG_FILE"
    fi
    
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
    
    # Function to get completed tests since last check with detailed information
    get_recently_completed_tests() {
        local timestamp="$1"
        local api_response="$2"
        local simple_format="$3"
        
        # Get list of recently completed and failed tests using Python with detailed info
        echo "$api_response" | python3 -c "
import sys, json
import time
from datetime import datetime

data = json.load(sys.stdin)
timestamp = float('$timestamp')
simple_format = '$simple_format' == 'true'

# Extract completed and failed tests with timestamps
completed_tests = []

# Fix: The API doesn't return a 'tests' field directly, we need to look at recent_executions 
# and also query recent test data from status_counts
recent_executions = data.get('recent_executions', [])
for execution in recent_executions:
    try:
        # Check if this is a completed or failed test
        status = execution.get('status')
        if status in ['completed', 'failed']:
            # Try to parse the timestamp
            end_time = execution.get('end_time')
            if end_time:
                try:
                    # Parse timestamp from execution
                    test_time = datetime.strptime(end_time, '%Y-%m-%d %H:%M:%S.%f').timestamp()
                except ValueError:
                    # Try without microseconds
                    test_time = datetime.strptime(end_time, '%Y-%m-%d %H:%M:%S').timestamp()
                
                if test_time > timestamp:
                    name = execution.get('test_name', 'Unknown test')
                    node_id = execution.get('node_id', 'Unknown node')
                    execution_id = execution.get('execution_id', '?')
                    
                    # Extract suite name from test name (assuming format like T01_01)
                    suite_prefix = name.split('_')[0] if '_' in name else ''
                    suite_name = suite_prefix if suite_prefix else 'Unknown suite'
                    
                    # Format the time in a readable format
                    time_str = datetime.fromtimestamp(test_time).strftime('%H:%M:%S')
                    
                    if simple_format:
                        # Simple format just shows status and name
                        completed_tests.append(f'{status.upper()}: {suite_name}.{name}')
                    else:
                        # Create a detailed message for this test completion
                        completed_tests.append(f'{status.upper()}: {suite_name}.{name} [ID: {execution_id}, Node: {node_id}, Time: {time_str}]')
    except (ValueError, TypeError) as e:
        print(f'Error processing execution data: {e}', file=sys.stderr)

for test in completed_tests:
    print(test)
"
    }
    
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
        return 1
    fi
    
    echo "Monitoring test progress via API..."
    last_check_timestamp=$(date +%s.%N)
    
    while true; do
        # Get test status from API
        api_response=$(curl -s http://localhost:8000/api/status 2>/dev/null)
        if [ $? -eq 0 ]; then
            total_tests=$(echo "$api_response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('total_tests', 0))" 2>/dev/null)
            completed_count=$(echo "$api_response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status_counts', {}).get('completed', 0))" 2>/dev/null)
            failed_count=$(echo "$api_response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status_counts', {}).get('failed', 0))" 2>/dev/null)
            running_count=$(echo "$api_response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status_counts', {}).get('running', 0))" 2>/dev/null)
            pending_count=$(echo "$api_response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status_counts', {}).get('pending', 0))" 2>/dev/null)
            
            if [ -n "$total_tests" ] && [ -n "$completed_count" ] && [ -n "$failed_count" ]; then
                processed_tests=$((completed_count + failed_count))
                
                # Get any tests completed since our last check
                recently_completed=$(get_recently_completed_tests "$last_check_timestamp" "$api_response" "$SIMPLE_LOG")
                if [ -n "$recently_completed" ]; then
                    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━ TEST COMPLETION LOG ━━━━━━━━━━━━━━━━━${NC}"
                    echo "$recently_completed" | while read -r test; do
                        timestamp=$(date "+%Y-%m-%d %H:%M:%S")
                        
                        # Log to file - add each test to the cumulative log
                        echo "[$timestamp] $test" >> "$TEST_LOG_FILE"
                        
                        # Display to terminal with color
                        if [[ "$test" == COMPLETED:* ]]; then
                            echo -e "✅ ${GREEN}$test${NC}"
                        else
                            echo -e "❌ ${RED}$test${NC}"
                        fi
                    done
                    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
                fi
                
                # Update the timestamp for the next check
                last_check_timestamp=$(date +%s.%N)
                
                # Print status summary
                echo -e "${YELLOW}Status Summary:${NC} $processed_tests/$total_tests completed (Passed: $completed_count, Failed: $failed_count, Running: $running_count, Pending: $pending_count)"
                
                if [ "$processed_tests" -ge "$total_tests" ] && [ "$total_tests" -gt 0 ] && [ "$running_count" -eq 0 ]; then
                    echo -e "${GREEN}All tests completed!${NC} Total: $total_tests, Completed: $completed_count, Failed: $failed_count"
                    
                    # Get a final list of ALL completed tests to ensure our log is complete
                    echo -e "Collecting final test completion data..."
                    
                    # Get all completed tests using a modified version of our function that gets all tests regardless of timestamp
                    all_completed_tests=$(echo "$api_response" | python3 -c "
import sys, json
from datetime import datetime

data = json.load(sys.stdin)
simple_format = '$SIMPLE_LOG' == 'true'

# Get all finished test executions
status_counts = data.get('status_counts', {})
total = data.get('total_tests', 0)
passed = status_counts.get('completed', 0)
failed = status_counts.get('failed', 0)

print(f'Final test completion status: {passed + failed}/{total} tests completed')

# Get information about all test executions
all_test_data = []

# For a complete report, we need to query all executions from the API
try:
    import requests
    response = requests.get('http://localhost:8000/api/dashboard')
    if response.status_code == 200:
        dashboard_data = response.json()
        executions = dashboard_data.get('recent_executions', [])
        
        # Sort by test name to make the list more readable
        executions.sort(key=lambda x: x.get('test_name', ''))
        
        for execution in executions:
            status = execution.get('status')
            if status in ['completed', 'failed']:
                name = execution.get('test_name', 'Unknown test') 
                node_id = execution.get('node_id', 'Unknown node')
                
                # Extract suite name from test name (assuming format like T01_01)
                suite_prefix = name.split('_')[0] if '_' in name else ''
                suite_name = suite_prefix if suite_prefix else 'Unknown suite'
                
                if simple_format:
                    all_test_data.append(f'{status.upper()}: {suite_name}.{name}')
                else:
                    execution_id = execution.get('execution_id', '?')
                    end_time = execution.get('end_time', 'Unknown time')
                    all_test_data.append(f'{status.upper()}: {suite_name}.{name} [ID: {execution_id}, Node: {node_id}]')
    else:
        all_test_data.append('Failed to get complete test execution data from API')
except Exception as e:
    all_test_data.append(f'Error retrieving test data: {e}')

# Print each test on its own line
for test in all_test_data:
    print(test)
")

                    # Add test completion data to the log file in a clean format
                    echo -e "\n\n==== COMPLETE LIST OF EXECUTED TESTS ====\n" >> "$TEST_LOG_FILE"
                    echo "$all_completed_tests" | grep -E "^(COMPLETED|FAILED):" >> "$TEST_LOG_FILE"
                    
                    # Add summary to log file
                    echo -e "\n================ TEST RUN SUMMARY =================" >> "$TEST_LOG_FILE"
                    echo "Completed at: $(date)" >> "$TEST_LOG_FILE"
                    echo "Total tests: $total_tests" >> "$TEST_LOG_FILE"
                    echo "Passed: $completed_count" >> "$TEST_LOG_FILE"
                    echo "Failed: $failed_count" >> "$TEST_LOG_FILE"
                    echo "=================================================" >> "$TEST_LOG_FILE"
                    
                    # Print summary on screen
                    echo -e "\n${GREEN}Test execution log saved to: $TEST_LOG_FILE${NC}"
                    echo -e "To see all completed tests, run: ${YELLOW}cat $TEST_LOG_FILE${NC}"
                    break
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
}

# Check if we should only monitor
if [ "$MONITOR_ONLY" = true ]; then
    monitor_tests
    exit 0
fi

# Check if we should wait and cleanup
if [ "$CLEANUP" = true ]; then
    print_header "Waiting for tests to complete before cleanup"
    echo "Press Ctrl+C to skip cleanup"
    
    # Use our monitoring function to track test progress
    # Use standard verbose mode for cleanup
    monitor_tests
    
    # If monitoring fails or is interrupted, fall back to checking pod status
    if [ $? -ne 0 ]; then
        echo "Monitoring via API failed, falling back to pod status monitoring..."
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
    fi
    
        # Cleanup section - handled by monitor_tests function above
    
    print_header "Cleaning up Kubernetes resources"
    kubectl delete -f worker-deployment.yaml -n robot-tests
    
    echo "Cleanup complete."
fi

print_header "Done!"
