#!/usr/bin/env python3
"""
Test Distributor for Kubernetes Parallel Testing

This script manages the distribution of Robot Framework tests across multiple
Kubernetes pods for parallel execution. It uses a local SQLite database to
track test status and assigns tests to available nodes.

Usage:
    python k8s_test_distributor.py --replicas 5
"""

import os
import sys
import time
import sqlite3
import argparse
import subprocess
import json
import uuid
from datetime import datetime

# Constants
TEST_DB_PATH = "robot_tests.db"
RESULTS_DIR = "results"
NAMESPACE = "robot-tests"

def setup_execution_database():
    """Create or update a database to track test execution status."""
    if not os.path.exists(TEST_DB_PATH):
        print(f"Error: Test database '{TEST_DB_PATH}' not found.")
        print("Please run parse_robot_tests.py first to create the database.")
        sys.exit(1)

    conn = sqlite3.connect(TEST_DB_PATH)
    cursor = conn.cursor()
    
    # Add execution tracking tables if they don't exist
    cursor.execute('''
    CREATE TABLE IF NOT EXISTS test_executions (
        execution_id TEXT PRIMARY KEY,
        test_id INTEGER,
        node_id TEXT,
        status TEXT,
        start_time TIMESTAMP,
        end_time TIMESTAMP,
        result TEXT,
        FOREIGN KEY (test_id) REFERENCES test_cases(id)
    )
    ''')
    
    # Add a 'status' column to test_cases if it doesn't exist
    try:
        cursor.execute('SELECT status FROM test_cases LIMIT 1')
    except sqlite3.OperationalError:
        cursor.execute('ALTER TABLE test_cases ADD COLUMN status TEXT DEFAULT "pending"')
    
    conn.commit()
    return conn

def reset_test_statuses(conn):
    """Reset all test statuses to 'pending'."""
    cursor = conn.cursor()
    cursor.execute('UPDATE test_cases SET status = "pending"')
    conn.commit()
    print("Reset all test statuses to 'pending'")

def get_next_test(conn, node_id):
    """Get the next available test for a node."""
    cursor = conn.cursor()
    
    # Get the next pending test
    cursor.execute('''
    SELECT id, test_name, suite_name, file_path 
    FROM test_cases 
    WHERE status = "pending" 
    ORDER BY id
    LIMIT 1
    ''')
    
    test = cursor.fetchone()
    
    if not test:
        return None
    
    test_id, test_name, suite_name, file_path = test
    
    # Mark test as running
    cursor.execute('''
    UPDATE test_cases 
    SET status = "running" 
    WHERE id = ?
    ''', (test_id,))
    
    # Create execution record
    execution_id = str(uuid.uuid4())
    cursor.execute('''
    INSERT INTO test_executions 
    (execution_id, test_id, node_id, status, start_time) 
    VALUES (?, ?, ?, "running", ?)
    ''', (execution_id, test_id, node_id, datetime.now()))
    
    conn.commit()
    
    return {
        "execution_id": execution_id,
        "test_id": test_id,
        "test_name": test_name,
        "suite_name": suite_name,
        "file_path": file_path
    }

def update_test_status(conn, execution_id, status, result=None):
    """Update the status and result of a test execution."""
    cursor = conn.cursor()
    
    # Get the test_id for this execution
    cursor.execute('SELECT test_id FROM test_executions WHERE execution_id = ?', (execution_id,))
    result_row = cursor.fetchone()
    
    if not result_row:
        print(f"Error: Execution ID {execution_id} not found.")
        return False
    
    test_id = result_row[0]
    
    # Update execution record
    cursor.execute('''
    UPDATE test_executions 
    SET status = ?, end_time = ?, result = ? 
    WHERE execution_id = ?
    ''', (status, datetime.now(), result, execution_id))
    
    # Update test case status
    cursor.execute('''
    UPDATE test_cases 
    SET status = ? 
    WHERE id = ?
    ''', (status, test_id))
    
    conn.commit()
    return True

def create_kubernetes_resources(replicas):
    """Create Kubernetes namespace and resources for test execution."""
    # Create namespace if it doesn't exist
    try:
        subprocess.run(
            ["kubectl", "create", "namespace", NAMESPACE],
            check=False,
            capture_output=True
        )
        print(f"Created namespace: {NAMESPACE}")
    except subprocess.CalledProcessError:
        print(f"Namespace {NAMESPACE} already exists or could not be created")
    
    # Apply the deployment
    configmap_file = "k8s_test_runner_configmap.yaml"
    deployment_file = "k8s_test_runner_deployment.yaml"
    
    # Apply the resources
    for resource_file in [configmap_file, deployment_file]:
        try:
            subprocess.run(
                ["kubectl", "apply", "-f", resource_file, "-n", NAMESPACE],
                check=True
            )
            print(f"Applied {resource_file}")
        except subprocess.CalledProcessError as e:
            print(f"Error applying {resource_file}: {e}")
            sys.exit(1)
    
    # Scale the deployment to the desired number of replicas
    try:
        subprocess.run(
            ["kubectl", "scale", "deployment", "robot-test-runner", 
             "--replicas", str(replicas), "-n", NAMESPACE],
            check=True
        )
        print(f"Scaled deployment to {replicas} replicas")
    except subprocess.CalledProcessError as e:
        print(f"Error scaling deployment: {e}")
        sys.exit(1)

def get_running_pods():
    """Get a list of running pods in the test namespace."""
    try:
        result = subprocess.run(
            ["kubectl", "get", "pods", "-n", NAMESPACE, "-o", "json"],
            check=True,
            capture_output=True,
            text=True
        )
        pods_json = json.loads(result.stdout)
        
        running_pods = []
        for pod in pods_json["items"]:
            if pod["status"]["phase"] == "Running":
                running_pods.append(pod["metadata"]["name"])
        
        return running_pods
    except (subprocess.CalledProcessError, KeyError, json.JSONDecodeError) as e:
        print(f"Error getting pods: {e}")
        return []

def check_test_completion():
    """Check if all tests have been completed."""
    conn = sqlite3.connect(TEST_DB_PATH)
    cursor = conn.cursor()
    
    cursor.execute('SELECT COUNT(*) FROM test_cases WHERE status = "pending" OR status = "running"')
    remaining = cursor.fetchone()[0]
    
    cursor.execute('SELECT COUNT(*) FROM test_cases')
    total = cursor.fetchone()[0]
    
    cursor.execute('SELECT COUNT(*) FROM test_cases WHERE status = "completed"')
    completed = cursor.fetchone()[0]
    
    cursor.execute('SELECT COUNT(*) FROM test_cases WHERE status = "failed"')
    failed = cursor.fetchone()[0]
    
    conn.close()
    
    print(f"Progress: {completed + failed}/{total} tests processed ({completed} completed, {failed} failed)")
    
    return remaining == 0

def cleanup_kubernetes_resources():
    """Clean up Kubernetes resources after test execution."""
    try:
        subprocess.run(
            ["kubectl", "delete", "deployment", "robot-test-runner", "-n", NAMESPACE],
            check=False
        )
        print("Deleted test runner deployment")
    except subprocess.CalledProcessError:
        print("Error deleting deployment")

def main():
    """Main function to run the test distributor."""
    parser = argparse.ArgumentParser(description='Distribute tests across Kubernetes pods')
    parser.add_argument('--replicas', type=int, default=5,
                        help='Number of parallel test pods to run (default: 5)')
    parser.add_argument('--reset', action='store_true',
                        help='Reset all test statuses before starting')
    parser.add_argument('--cleanup', action='store_true',
                        help='Clean up Kubernetes resources after completion')
    
    args = parser.parse_args()
    
    print(f"Starting test distribution with {args.replicas} parallel pods")
    
    # Setup database
    conn = setup_execution_database()
    
    # Reset test statuses if requested
    if args.reset:
        reset_test_statuses(conn)
    
    # Create Kubernetes resources
    create_kubernetes_resources(args.replicas)
    
    print("Waiting for pods to start running...")
    time.sleep(10)  # Give some time for pods to start
    
    # Main monitoring loop
    try:
        while not check_test_completion():
            print("\nChecking pod status...")
            pods = get_running_pods()
            print(f"Running pods: {len(pods)}")
            
            time.sleep(10)  # Wait before checking again
    except KeyboardInterrupt:
        print("\nInterrupted by user. Cleaning up...")
    
    print("\nTest execution complete!")
    
    # Cleanup if requested
    if args.cleanup:
        cleanup_kubernetes_resources()
    
    conn.close()

if __name__ == "__main__":
    main()
