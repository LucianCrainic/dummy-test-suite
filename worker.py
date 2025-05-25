#!/usr/bin/env python3
"""
Kubernetes Test Runner

This script runs in a Kubernetes pod and:
1. Fetches a test from the control node API
2. Executes the test
3. Reports the result back to the control node
4. Repeats until no more tests are available

Usage:
    python worker.py
"""

import os
import json
import socket
import subprocess
import requests
import shutil
from datetime import datetime

# Configuration - These are set via environment variables in the pod
API_BASE_URL = os.environ.get('API_BASE_URL', 'http://localhost:8000')
NODE_ID = os.environ.get('NODE_ID', socket.gethostname())
TESTS_DIR = os.environ.get('TESTS_DIR', '/tests')
RESULTS_DIR = os.environ.get('RESULTS_DIR', '/results')
SHARED_OUTPUTS_DIR = os.environ.get('SHARED_OUTPUTS_DIR', '/shared-outputs')

def get_next_test():
    """Get the next test to run from the API."""
    max_retries = 3
    retry_delay = 1  # seconds
    
    for attempt in range(max_retries):
        try:
            response = requests.get(f"{API_BASE_URL}/api/next_test?node_id={NODE_ID}")
            
            if response.status_code == 200:
                test_data = response.json()
                return test_data
            elif response.status_code == 404:
                # No more tests
                return None
            elif response.status_code == 500 and "Database error" in response.text:
                # This could be a transaction conflict - retry after a delay
                print(f"Database error on attempt {attempt+1}/{max_retries}, retrying in {retry_delay} seconds...")
                import time
                time.sleep(retry_delay)
                # Increase delay for next retry (exponential backoff)
                retry_delay *= 2
            else:
                print(f"Error getting next test: {response.status_code}")
                if attempt < max_retries - 1:
                    print(f"Retrying... (Attempt {attempt+1}/{max_retries})")
                    time.sleep(retry_delay)
                    retry_delay *= 2
                else:
                    return None
        except requests.RequestException as e:
            print(f"Request exception: {e}")
            if attempt < max_retries - 1:
                print(f"Retrying... (Attempt {attempt+1}/{max_retries})")
                import time
                time.sleep(retry_delay)
                retry_delay *= 2
            else:
                return None
    
    return None

def run_test(test):
    """Run a Robot Framework test and return the result."""
    execution_id = test['execution_id']
    test_name = test['test_name']
    
    print(f"Running test: {test_name} (Execution ID: {execution_id})")
    
    # Create a unique directory for this test run
    output_dir = os.path.join(RESULTS_DIR, execution_id)
    os.makedirs(output_dir, exist_ok=True)
    
    # Ensure shared outputs directory exists
    os.makedirs(SHARED_OUTPUTS_DIR, exist_ok=True)
    
    # Build the robot command
    cmd = [
        "robot",
        "--outputdir", output_dir,
        "--xunit", "xunit.xml",
        "--log", "log.html",
        "--report", "report.html",
        "--output", "output.xml",
        "--test", test_name,
        TESTS_DIR
    ]
    
    print(f"Robot command: {' '.join(cmd)}")
    
    # Run the test
    start_time = datetime.now()
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False  # Don't raise exception on test failure
        )
        
        print(f"Robot command completed with return code: {result.returncode}")
        
        # Copy output.xml to shared directory with unique name
        output_xml_path = os.path.join(output_dir, "output.xml")
        if os.path.exists(output_xml_path):
            # Create a unique filename using execution_id and test_name
            safe_test_name = "".join(c for c in test_name if c.isalnum() or c in (' ', '-', '_')).rstrip()
            safe_test_name = safe_test_name.replace(' ', '_')
            shared_output_filename = f"{execution_id}_{safe_test_name}_output.xml"
            shared_output_path = os.path.join(SHARED_OUTPUTS_DIR, shared_output_filename)
            
            try:
                shutil.copy2(output_xml_path, shared_output_path)
                print(f"Copied output.xml to shared directory: {shared_output_filename}")
            except Exception as e:
                print(f"Warning: Failed to copy output.xml to shared directory: {e}")
        else:
            print(f"Warning: output.xml not found at {output_xml_path}")
        
        # Determine test status
        status = "completed" if result.returncode == 0 else "failed"
        
        # Extract results from the output XML if available
        result_info = {
            "status": status,
            "returncode": result.returncode,
            "execution_time": str(datetime.now() - start_time),
            "shared_output_file": shared_output_filename if os.path.exists(output_xml_path) else None
        }
        
        return status, json.dumps(result_info)
    
    except Exception as e:
        print(f"Error running test: {e}")
        return "failed", json.dumps({"error": str(e)})

def update_test_status(execution_id, status, result):
    """Update the test status in the API."""
    try:
        data = {
            "execution_id": execution_id,
            "status": status,
            "result": result
        }
        
        response = requests.post(
            f"{API_BASE_URL}/api/update_test",
            json=data
        )
        
        if response.status_code != 200:
            print(f"Error updating test status: {response.status_code}")
        
        return response.status_code == 200
    
    except requests.RequestException as e:
        print(f"Request exception: {e}")
        return False

def main():
    """Main function to run tests in a loop."""
    try:
        print(f"Starting test runner on node: {NODE_ID}")
        print(f"Using API URL: {API_BASE_URL}")
        
        # Test connectivity first
        print("Testing connectivity to API...")
        try:
            response = requests.get(f"{API_BASE_URL}/api/status", timeout=5)
            print(f"API connectivity test - Status: {response.status_code}")
            
            # Get information about how many tests are available
            try:
                status_data = response.json()
                total_tests = status_data.get('total_tests', 'unknown')
                pending_tests = status_data.get('status_counts', {}).get('pending', 'unknown')
                print(f"API reports {pending_tests} pending tests out of {total_tests} total tests")
            except Exception as e:
                print(f"Could not parse API status response: {e}")
                
        except Exception as e:
            print(f"API connectivity test failed: {e}")
            return
        
        tests_run = 0
        
        while True:
            # Get the next test with a timestamp to track time spent in test fetching
            import time
            start_time = time.time()
            print(f"Requesting next test from API...")
            test = get_next_test()
            request_time = time.time() - start_time
            
            if not test:
                print("No more tests available")
                break
            
            print(f"Received test: {test['test_name']} (Took {request_time:.2f}s to fetch)")
            print(f"Test details: ID={test['test_id']}, Execution ID={test['execution_id']}")
            
            # Run the test
            status, result = run_test(test)
            
            # Update the test status
            update_success = update_test_status(test['execution_id'], status, result)
            if not update_success:
                print(f"WARNING: Failed to update status for test {test['test_name']} (ID: {test['test_id']})")
            
            tests_run += 1
            print(f"Completed test {tests_run}: {test['test_name']} - {status}")
        
        print(f"Test runner completed. Total tests run: {tests_run}")
    except Exception as e:
        print(f"Exception in main(): {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()
