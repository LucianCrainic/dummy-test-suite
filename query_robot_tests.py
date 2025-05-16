#!/usr/bin/env python3
"""
Robot Framework Test Database Query Tool

This script provides a simple interface to query the test database
created by the parse_robot_tests.py script.

Usage:
    python query_robot_tests.py [options]
"""

import os
import sys
import sqlite3
import argparse
from datetime import datetime

def get_connection():
    """Connect to the SQLite database."""
    db_path = 'robot_tests.db'
    
    if not os.path.exists(db_path):
        print(f"Error: Database file '{db_path}' not found.")
        print("Please run parse_robot_tests.py first to create the database.")
        sys.exit(1)
    
    return sqlite3.connect(db_path)

def list_all_tests(conn):
    """List all tests in the database."""
    cursor = conn.cursor()
    cursor.execute('SELECT suite_name, test_name FROM test_cases ORDER BY suite_name, test_name')
    results = cursor.fetchall()
    
    if not results:
        print("No tests found in the database.")
        return
    
    current_suite = None
    
    for suite_name, test_name in results:
        if suite_name != current_suite:
            current_suite = suite_name
            print(f"\n{suite_name}:")
        print(f"  - {test_name}")

def search_tests(conn, search_term):
    """Search for tests containing the given search term."""
    cursor = conn.cursor()
    search_pattern = f"%{search_term}%"
    
    cursor.execute('''
    SELECT suite_name, test_name 
    FROM test_cases 
    WHERE test_name LIKE ? 
    ORDER BY suite_name, test_name
    ''', (search_pattern,))
    
    results = cursor.fetchall()
    
    if not results:
        print(f"No tests found matching '{search_term}'.")
        return
    
    print(f"\nTests matching '{search_term}':")
    print("------------------------" + "-" * len(search_term))
    
    current_suite = None
    
    for suite_name, test_name in results:
        if suite_name != current_suite:
            current_suite = suite_name
            print(f"\n{suite_name}:")
        print(f"  - {test_name}")

def get_test_details(conn, test_id=None, test_name=None):
    """Get details for a specific test by ID or name."""
    cursor = conn.cursor()
    
    if test_id:
        cursor.execute('''
        SELECT id, test_name, file_path, suite_name, parsed_date 
        FROM test_cases 
        WHERE id = ?
        ''', (test_id,))
    elif test_name:
        cursor.execute('''
        SELECT id, test_name, file_path, suite_name, parsed_date 
        FROM test_cases 
        WHERE test_name LIKE ?
        ''', (f"%{test_name}%",))
    else:
        print("Error: Either test_id or test_name must be provided.")
        return
    
    results = cursor.fetchall()
    
    if not results:
        print("No matching tests found.")
        return
    
    for test_id, name, path, suite, parsed_date in results:
        print("\nTest Details:")
        print(f"  ID:         {test_id}")
        print(f"  Name:       {name}")
        print(f"  Suite:      {suite}")
        print(f"  File Path:  {path}")
        print(f"  Parsed:     {parsed_date}")

def get_database_stats(conn):
    """Get statistics about the test database."""
    cursor = conn.cursor()
    
    # Get total count
    cursor.execute('SELECT COUNT(*) FROM test_cases')
    total_count = cursor.fetchone()[0]
    
    # Get suite count
    cursor.execute('SELECT COUNT(DISTINCT suite_name) FROM test_cases')
    suite_count = cursor.fetchone()[0]
    
    # Get file count
    cursor.execute('SELECT COUNT(DISTINCT file_path) FROM test_cases')
    file_count = cursor.fetchone()[0]
    
    # Get last parsed date
    cursor.execute('SELECT MAX(parsed_date) FROM test_cases')
    last_parsed = cursor.fetchone()[0]
    
    print("\nDatabase Statistics:")
    print(f"  Total Tests:      {total_count}")
    print(f"  Total Suites:     {suite_count}")
    print(f"  Total Files:      {file_count}")
    print(f"  Last Updated:     {last_parsed}")

def main():
    """Main function to parse arguments and run queries."""
    parser = argparse.ArgumentParser(description='Query the Robot Framework test database')
    
    # Create a group for mutually exclusive options
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--list', action='store_true', help='List all tests')
    group.add_argument('--search', help='Search for tests containing the given string')
    group.add_argument('--id', type=int, help='Get details for a test with the given ID')
    group.add_argument('--name', help='Get details for tests with names containing the given string')
    group.add_argument('--stats', action='store_true', help='Show database statistics')
    
    args = parser.parse_args()
    
    # Connect to the database
    conn = get_connection()
    
    try:
        if args.list:
            list_all_tests(conn)
        elif args.search:
            search_tests(conn, args.search)
        elif args.id:
            get_test_details(conn, test_id=args.id)
        elif args.name:
            get_test_details(conn, test_name=args.name)
        elif args.stats:
            get_database_stats(conn)
    finally:
        conn.close()

if __name__ == "__main__":
    main()
