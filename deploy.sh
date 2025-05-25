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

# Clean up any existing deployments before starting
print_header "Cleaning up any existing deployments"
pkill -f "kubectl port-forward" || true
kubectl delete -f worker-deployment.yaml -n robot-tests --ignore-not-found=true
kubectl delete pods -n robot-tests --all --force --grace-period=0 2>/dev/null || true
kubectl delete namespace robot-tests --ignore-not-found=true
sleep 5

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
    
    # Copy database, API server and merger files
    # Remove any existing files or directories with the same names
    minikube ssh "sudo rm -rf /tmp/robot-tests/robot_tests.db /tmp/robot-tests/server.py /tmp/robot-tests/merger.py /tmp/robot_tests.db /tmp/server.py /tmp/merger.py"
    
    # Copy and move files
    minikube cp robot_tests.db /tmp/robot_tests.db
    minikube cp server.py /tmp/server.py
    minikube cp merger.py /tmp/merger.py
    minikube ssh "sudo cp -f /tmp/robot_tests.db /tmp/robot-tests/ && sudo cp -f /tmp/server.py /tmp/robot-tests/ && sudo cp -f /tmp/merger.py /tmp/robot-tests/"
    
    # Verify files are in the correct location
    if ! minikube ssh "test -f /tmp/robot-tests/robot_tests.db && test -f /tmp/robot-tests/server.py && test -f /tmp/robot-tests/merger.py"; then
        print_error "Files not found in destination directory. Please check permissions and paths."
        exit 1
    fi
    
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
    # Wait for API to be ready and forward port
    kubectl port-forward service/test-api-service 8000:8000 -n robot-tests &
    PORT_FORWARD_PID=$!
    
    # Wait for port forwarding to establish
    sleep 5
    
    # Call the reset API
    if curl -s -X POST http://localhost:8000/api/reset; then
        echo "Tests reset successfully"
    else
        print_warning "Failed to reset tests"
    fi
    
    # Kill port forwarding
    kill $PORT_FORWARD_PID
fi

# Function to monitor tests and always create test execution log
monitor_tests() {
    print_header "Monitoring test execution in real-time"
    echo "Press Ctrl+C to stop monitoring"
    
    # Create a log file for test completions
    TEST_LOG_FILE="test_execution_log_$(date +%Y%m%d_%H%M%S).txt"
    echo "Test Execution Log - Started at $(date)" > "$TEST_LOG_FILE"
    echo "----------------------------------------" >> "$TEST_LOG_FILE"
    echo "" >> "$TEST_LOG_FILE"
    echo "Tests Completed:" >> "$TEST_LOG_FILE"
    echo "----------------" >> "$TEST_LOG_FILE"
    echo "" >> "$TEST_LOG_FILE"
    
    echo "Recording all test completions to: $TEST_LOG_FILE"
    
    # Wait for API pod to be ready
    echo "Waiting for API pod to be ready..."
    kubectl wait --for=condition=ready pod -l app=test-api -n robot-tests --timeout=120s
    
    if [ $? -ne 0 ]; then
        print_error "Timed out waiting for API pod to be ready"
        API_POD_NAME=$(kubectl get pods -n robot-tests -l app=test-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$API_POD_NAME" ]; then
            kubectl logs $API_POD_NAME -n robot-tests
        fi
        exit 1
    fi
    
    # Clean up and set up port forwarding
    pkill -f "kubectl port-forward" || true
    sleep 1
    
    # Get API Pod name and start port forwarding
    API_POD_NAME=$(kubectl get pod -l app=test-api -n robot-tests -o jsonpath='{.items[0].metadata.name}')
    if [ -z "$API_POD_NAME" ]; then
        print_error "Failed to find API pod"
        exit 1
    fi
    
    kubectl port-forward pod/$API_POD_NAME 8000:8000 -n robot-tests > /dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    
    # Function to get completed tests since last check with detailed information
    get_recently_completed_tests() {
        local timestamp="$1"
        local api_response="$2"
        
        # Get list of recently completed and failed tests using Python with detailed info
        echo "$api_response" | python3 -c "
import sys, json
import time
from datetime import datetime

data = json.load(sys.stdin)
timestamp = float('$timestamp')

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
                    
                    # Create a detailed message for this test completion
                    completed_tests.append(f'{status.upper()}: {suite_name}.{name} [ID: {execution_id}, Node: {node_id}, Time: {time_str}]')
    except (ValueError, TypeError) as e:
        print(f'Error processing execution data: {e}', file=sys.stderr)

for test in completed_tests:
    print(test)
"
    }
    
    # Wait for port forwarding to be established
    echo "Waiting for API to become available..."
    attempt=0
    max_attempts=30
    while [ $attempt -lt $max_attempts ]; do
        if curl -s http://localhost:8000/api/status > /dev/null; then
            break
        fi
        attempt=$((attempt + 1))
        if [ $((attempt % 5)) -eq 0 ]; then
            echo "Waiting for API... ($attempt/$max_attempts)"
        fi
        sleep 2
    done
    
    if [ $attempt -eq $max_attempts ]; then
        echo "Failed to connect to API after $max_attempts attempts"
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
                recently_completed=$(get_recently_completed_tests "$last_check_timestamp" "$api_response")
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

print_header "Tests are now running in Kubernetes"
echo "To monitor test progress: kubectl get pods -n robot-tests"
echo "To access dashboard: kubectl port-forward service/test-api-service 8000:8000 -n robot-tests"
echo "Then visit: http://localhost:8000/"

# Always monitor tests and create test execution log
monitor_tests

# Check if we should wait and cleanup
if [ "$CLEANUP" = true ]; then
    print_header "Running test result merger and cleanup"
    
    # Run test result merger
    print_header "Merging test results"
    
    # Create a directory for merged results if it doesn't exist
    minikube ssh "sudo mkdir -p /tmp/robot-tests/merged-results"
    
    # Run the merger.py script in a temporary pod
    echo "Running merger script to combine test results..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-merger
  namespace: robot-tests
spec:
  volumes:
  - name: robot-tests-volume
    hostPath:
      path: /tmp/robot-tests
      type: DirectoryOrCreate
  containers:
  - name: merger
    image: dummy-test-suite:latest
    imagePullPolicy: Never
    volumeMounts:
    - name: robot-tests-volume
      mountPath: /app
    workingDir: /app
    env:
    - name: SHARED_OUTPUTS_DIR
      value: "/app/shared-outputs"
    - name: MERGED_RESULTS_DIR
      value: "/app/merged-results"
    - name: DATABASE_PATH
      value: "/app/robot_tests.db"
    command: ["python3", "/app/merger.py"]
  restartPolicy: Never
EOF

    # Wait for a reasonable time for the merger to produce output (don't wait for completion status)
    echo "Waiting for merger to produce output files..."
    sleep 30
    
    # Show the merger logs regardless of exit status
    echo "Merger logs:"
    kubectl logs test-merger -n robot-tests
    
    # Check if the output files exist in the minikube VM
    if minikube ssh "test -f /tmp/robot-tests/merged-results/merged_output.xml && test -f /tmp/robot-tests/merged-results/merged_log.html && test -f /tmp/robot-tests/merged-results/merged_report.html"; then
        echo "✅ Merger output files found. Proceeding with copy."
    else
        echo "❌ Merger output files not found. Checking for errors:"
        kubectl describe pod test-merger -n robot-tests
        print_warning "Will attempt to copy files anyway, but they might not exist."
    fi
    
    # Copy the merged results from minikube to local directory
    echo "Copying merged results to local directory..."
    mkdir -p ./merged-results
    
    # Use alternative approach to copy files with SSH and cat
    echo "Using ssh method to copy files from minikube VM..."
    
    # Copy output.xml
    if minikube ssh "test -f /tmp/robot-tests/merged-results/merged_output.xml"; then
        echo "Copying merged_output.xml..."
        minikube ssh "cat /tmp/robot-tests/merged-results/merged_output.xml" > ./merged-results/merged_output.xml
        if [ $? -eq 0 ] && [ -s "./merged-results/merged_output.xml" ]; then
            echo "✅ Successfully copied merged_output.xml"
            # Copy directly to the root with the correct name
            cp -f ./merged-results/merged_output.xml ./output.xml
            echo "✅ output.xml saved to repo root"
        else
            print_warning "Failed to copy merged_output.xml"
        fi
    else
        print_warning "merged_output.xml not found in minikube VM"
    fi
    
    # Copy log.html
    if minikube ssh "test -f /tmp/robot-tests/merged-results/merged_log.html"; then
        echo "Copying merged_log.html..."
        minikube ssh "cat /tmp/robot-tests/merged-results/merged_log.html" > ./merged-results/merged_log.html
        if [ $? -eq 0 ] && [ -s "./merged-results/merged_log.html" ]; then
            echo "✅ Successfully copied merged_log.html"
            # Copy directly to the root with the correct name
            cp -f ./merged-results/merged_log.html ./log.html
            echo "✅ log.html saved to repo root"
        else
            print_warning "Failed to copy merged_log.html"
        fi
    else
        print_warning "merged_log.html not found in minikube VM"
    fi
    
    # Copy report.html
    if minikube ssh "test -f /tmp/robot-tests/merged-results/merged_report.html"; then
        echo "Copying merged_report.html..."
        minikube ssh "cat /tmp/robot-tests/merged-results/merged_report.html" > ./merged-results/merged_report.html
        if [ $? -eq 0 ] && [ -s "./merged-results/merged_report.html" ]; then
            echo "✅ Successfully copied merged_report.html"
            # Copy directly to the root with the correct name
            cp -f ./merged-results/merged_report.html ./report.html
            echo "✅ report.html saved to repo root"
        else
            print_warning "Failed to copy merged_report.html"
        fi
    else
        print_warning "merged_report.html not found in minikube VM"
    fi
    
    # Cleanup section
    print_header "Cleaning up Kubernetes resources"
    kubectl delete pod/test-merger -n robot-tests --grace-period=0 --force
    kubectl delete -f worker-deployment.yaml -n robot-tests
fi

print_header "Done!"
