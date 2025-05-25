#!/usr/bin/env python3
"""
Test API Server

This script runs an API server that provides test information to Kubernetes pods
and receives test results. It interfaces with the SQLite database.

Usage:
    python server.py
"""

import os
import sqlite3
import uuid
from datetime import datetime
from flask import Flask, request, jsonify, render_template

# Constants
TEST_DB_PATH = "robot_tests.db"
TEMPLATES_DIR = os.path.join(os.path.dirname(__file__), "templates")

app = Flask(__name__, template_folder=TEMPLATES_DIR)

def get_db_connection():
    """Get a connection to the test database."""
    if not os.path.exists(TEST_DB_PATH):
        app.logger.error(f"Database file '{TEST_DB_PATH}' not found.")
        return None
    
    conn = sqlite3.connect(TEST_DB_PATH)
    conn.row_factory = sqlite3.Row  # This enables accessing columns by name
    return conn

@app.route('/api/next_test', methods=['GET'])
def next_test():
    """API endpoint to get the next available test."""
    node_id = request.args.get('node_id', 'unknown-node')
    
    conn = get_db_connection()
    if not conn:
        return jsonify({"error": "Database not found"}), 500
    
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
        conn.close()
        return jsonify({"message": "No tests available"}), 404
    
    test_id = test['id']
    
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
    conn.close()
    
    response = {
        "execution_id": execution_id,
        "test_id": test_id,
        "test_name": test['test_name'],
        "suite_name": test['suite_name'],
        "file_path": test['file_path']
    }
    
    app.logger.info(f"Assigned test {test['test_name']} to node {node_id}")
    return jsonify(response), 200

@app.route('/api/update_test', methods=['POST'])
def update_test():
    """API endpoint to update test status."""
    data = request.json
    
    if not data or 'execution_id' not in data or 'status' not in data:
        return jsonify({"error": "Missing required fields"}), 400
    
    execution_id = data['execution_id']
    status = data['status']
    result = data.get('result', None)
    
    conn = get_db_connection()
    if not conn:
        return jsonify({"error": "Database not found"}), 500
    
    cursor = conn.cursor()
    
    # Get the test_id for this execution
    cursor.execute('SELECT test_id FROM test_executions WHERE execution_id = ?', (execution_id,))
    result_row = cursor.fetchone()
    
    if not result_row:
        conn.close()
        return jsonify({"error": "Execution ID not found"}), 404
    
    test_id = result_row['test_id']
    
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
    
    # Get the test name for logging
    cursor.execute('SELECT test_name FROM test_cases WHERE id = ?', (test_id,))
    test_row = cursor.fetchone()
    test_name = test_row['test_name'] if test_row else 'Unknown test'
    
    conn.commit()
    conn.close()
    
    app.logger.info(f"Updated test {test_name} (ID: {test_id}) status to {status}")
    return jsonify({"message": "Test status updated"}), 200

@app.route('/api/status', methods=['GET'])
def status():
    """API endpoint to get current test status summary."""
    conn = get_db_connection()
    if not conn:
        return jsonify({"error": "Database not found"}), 500
    
    cursor = conn.cursor()
    
    # Get counts by status
    cursor.execute('''
    SELECT status, COUNT(*) as count
    FROM test_cases
    GROUP BY status
    ''')
    
    status_counts = {}
    for row in cursor.fetchall():
        status_counts[row['status']] = row['count']
    
    # Get total count
    cursor.execute('SELECT COUNT(*) as total FROM test_cases')
    total = cursor.fetchone()['total']
    
    # Get most recent executions
    cursor.execute('''
    SELECT e.execution_id, e.status, e.start_time, e.end_time, 
           t.test_name, e.node_id
    FROM test_executions e
    JOIN test_cases t ON e.test_id = t.id
    ORDER BY e.start_time DESC
    LIMIT 10
    ''')
    
    recent_executions = []
    for row in cursor.fetchall():
        recent_executions.append({
            'execution_id': row['execution_id'],
            'test_name': row['test_name'],
            'status': row['status'],
            'node_id': row['node_id'],
            'start_time': row['start_time'],
            'end_time': row['end_time']
        })
    
    conn.close()
    
    return jsonify({
        'total_tests': total,
        'status_counts': status_counts,
        'recent_executions': recent_executions
    }), 200

@app.route('/api/reset', methods=['POST'])
def reset_tests():
    """API endpoint to reset all test statuses to pending."""
    conn = get_db_connection()
    if not conn:
        return jsonify({"error": "Database not found"}), 500
    
    cursor = conn.cursor()
    cursor.execute('UPDATE test_cases SET status = "pending"')
    conn.commit()
    
    rowcount = cursor.rowcount
    conn.close()
    
    app.logger.info(f"Reset {rowcount} tests to pending status")
    return jsonify({"message": f"Reset {rowcount} tests to pending status"}), 200

@app.route('/', methods=['GET'])
def dashboard():
    """Serve the main dashboard page."""
    return render_template('dashboard.html')

@app.route('/api/dashboard', methods=['GET'])
def dashboard_data():
    """API endpoint to get dashboard data."""
    conn = get_db_connection()
    if not conn:
        return jsonify({"error": "Database not found"}), 500
    
    cursor = conn.cursor()
    
    # Get all test executions for analysis
    cursor.execute('''
    SELECT e.execution_id, e.status, e.start_time, e.end_time, 
           t.test_name, e.node_id
    FROM test_executions e
    JOIN test_cases t ON e.test_id = t.id
    ORDER BY e.start_time DESC
    ''')
    
    recent_executions = []
    for row in cursor.fetchall():
        recent_executions.append({
            'execution_id': row['execution_id'],
            'test_name': row['test_name'],
            'status': row['status'],
            'node_id': row['node_id'],
            'start_time': row['start_time'],
            'end_time': row['end_time']
        })
    
    # Get status counts
    cursor.execute('''
    SELECT status, COUNT(*) as count
    FROM test_cases
    GROUP BY status
    ''')
    
    status_counts = {}
    for row in cursor.fetchall():
        status_counts[row['status']] = row['count']
    
    # Get total count
    cursor.execute('SELECT COUNT(*) as total FROM test_cases')
    total = cursor.fetchone()['total']
    
    # Get test suite information
    cursor.execute('''
    SELECT SUBSTR(test_name, 1, 3) as suite, COUNT(*) as count
    FROM test_cases
    GROUP BY suite
    ''')
    
    suite_counts = {}
    for row in cursor.fetchall():
        suite_counts[row['suite']] = row['count']
    
    # Get node distribution
    cursor.execute('''
    SELECT node_id, COUNT(*) as count
    FROM test_executions
    GROUP BY node_id
    ''')
    
    node_counts = {}
    for row in cursor.fetchall():
        # Extract the last part of the node ID for cleaner display
        node_id = row['node_id'].split('-')[-1] if row['node_id'] else 'unknown'
        node_counts[node_id] = row['count']
    
    conn.close()
    
    return jsonify({
        'total_tests': total,
        'status_counts': status_counts,
        'suite_counts': suite_counts,
        'node_counts': node_counts,
        'recent_executions': recent_executions
    }), 200

if __name__ == "__main__":
    port = int(os.environ.get('PORT', 8000))
    host = os.environ.get('HOST', '0.0.0.0')
    
    # Create database tables if they don't exist
    conn = get_db_connection()
    if conn:
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
        conn.close()
    
    print(f"Starting Test API Server on {host}:{port}")
    app.run(host=host, port=port, debug=True)
