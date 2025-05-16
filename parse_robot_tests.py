#!/usr/bin/env python3
"""
Robot Framework Test Parser

This script scans a directory for Robot Framework test files (.robot),
parses them to extract test names, and stores them in a SQLite database.

Usage:
    python parse_robot_tests.py /path/to/tests
"""

import os
import sys
import sqlite3
import argparse
import re
from datetime import datetime

def create_database():
    """Create a SQLite database to store test information."""
    conn = sqlite3.connect('robot_tests.db')
    cursor = conn.cursor()
    
    # Create table for test cases
    cursor.execute('''
    CREATE TABLE IF NOT EXISTS test_cases (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        test_name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        suite_name TEXT NOT NULL,
        parsed_date TIMESTAMP NOT NULL
    )
    ''')
    
    conn.commit()
    return conn, cursor

def parse_robot_file(file_path):
    """Parse a Robot Framework file and extract test names."""
    test_cases = []
    suite_name = os.path.basename(os.path.dirname(file_path))
    
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Remove any comment lines at the beginning (like the filepath comment)
    content = re.sub(r'^//.*?\n', '', content)
    
    # Find the Test Cases section
    test_section_match = re.search(r'\*\*\*\s*Test Cases\s*\*\*\*(.*?)(?:\*\*\*|$)', 
                                 content, re.DOTALL)
    
    if test_section_match:
        test_section = test_section_match.group(1)
        
        # Extract test names (lines that don't start with spaces and are not empty)
        tests = re.findall(r'^([^\s].+?)$', test_section, re.MULTILINE)
        
        for test in tests:
            test_name = test.strip()
            if test_name:  # Skip empty lines
                test_cases.append({
                    'test_name': test_name,
                    'file_path': file_path,
                    'suite_name': suite_name
                })
    
    return test_cases

def scan_directory(directory_path):
    """Scan directory for Robot Framework files and parse them."""
    all_tests = []
    
    for root, _, files in os.walk(directory_path):
        for file in files:
            if file.lower().endswith('.robot'):
                file_path = os.path.join(root, file)
                tests = parse_robot_file(file_path)
                all_tests.extend(tests)
    
    return all_tests

def store_in_database(conn, cursor, tests):
    """Store test information in the database."""
    current_time = datetime.now()
    
    # First, clear existing data
    cursor.execute('DELETE FROM test_cases')
    
    # Insert new data
    for test in tests:
        cursor.execute('''
        INSERT INTO test_cases (test_name, file_path, suite_name, parsed_date)
        VALUES (?, ?, ?, ?)
        ''', (test['test_name'], test['file_path'], test['suite_name'], current_time))
    
    conn.commit()
    return cursor.rowcount

def print_summary(tests, stored_count):
    """Print a summary of the parsing operation."""
    suite_count = len(set(test['suite_name'] for test in tests))
    file_count = len(set(test['file_path'] for test in tests))
    
    print("\n===== Summary =====")
    print(f"Total test suites found: {suite_count}")
    print(f"Total robot files scanned: {file_count}")
    print(f"Total test cases found: {len(tests)}")
    print(f"Tests stored in database: {stored_count}")
    print("====================\n")

def list_tests_in_db(conn):
    """List all tests stored in the database."""
    cursor = conn.cursor()
    cursor.execute('SELECT suite_name, test_name FROM test_cases ORDER BY suite_name, test_name')
    results = cursor.fetchall()
    
    if not results:
        print("No tests found in the database.")
        return
    
    current_suite = None
    print("\nTests in database:")
    print("------------------")
    
    for suite_name, test_name in results:
        if suite_name != current_suite:
            current_suite = suite_name
            print(f"\n{suite_name}:")
        print(f"  - {test_name}")

def main():
    """Main function to parse arguments and run the parser."""
    parser = argparse.ArgumentParser(description='Parse Robot Framework tests and store them in a database')
    parser.add_argument('directory', help='Directory containing Robot Framework test files')
    parser.add_argument('--list', action='store_true', help='List all tests in database after parsing')
    
    args = parser.parse_args()
    
    if not os.path.isdir(args.directory):
        print(f"Error: {args.directory} is not a valid directory")
        sys.exit(1)
    
    print(f"Scanning directory: {args.directory}")
    
    # Create database
    conn, cursor = create_database()
    
    # Scan directory and get tests
    tests = scan_directory(args.directory)
    
    if not tests:
        print("No Robot Framework tests found in the specified directory")
        sys.exit(0)
    
    # Store in database
    stored_count = store_in_database(conn, cursor, tests)
    
    # Print summary
    print_summary(tests, stored_count)
    
    # List tests if requested
    if args.list:
        list_tests_in_db(conn)
    
    conn.close()
    
    print(f"Database saved to: {os.path.abspath('robot_tests.db')}")

if __name__ == "__main__":
    main()
