#!/usr/bin/env python3
"""
Test Results Merger

This script monitors the test execution and merges all output.xml files
when all tests are completed using Robot Framework's rebot command.
"""

import os
import sys
import time
import glob
import subprocess
import sqlite3
import requests
from datetime import datetime

# Configuration
API_BASE_URL = os.environ.get('API_BASE_URL', 'http://test-api-service:8000')
SHARED_OUTPUTS_DIR = os.environ.get('SHARED_OUTPUTS_DIR', '/shared-outputs')
MERGED_RESULTS_DIR = os.environ.get('MERGED_RESULTS_DIR', '/merged-results')
DATABASE_PATH = os.environ.get('DATABASE_PATH', '/app/robot_tests.db')
POLLING_INTERVAL = int(os.environ.get('POLLING_INTERVAL', '10'))  # seconds

def get_test_status():
    """Get the current status of all tests from the database."""
    try:
        conn = sqlite3.connect(DATABASE_PATH)
        cursor = conn.cursor()
        
        # Get total test count and completed/failed count
        cursor.execute("SELECT COUNT(*) FROM test_cases")
        total_tests = cursor.fetchone()[0]
        
        cursor.execute("""
            SELECT COUNT(*) FROM test_executions 
            WHERE status IN ('completed', 'failed')
        """)
        finished_tests = cursor.fetchone()[0]
        
        cursor.execute("SELECT COUNT(*) FROM test_executions WHERE status = 'completed'")
        passed_tests = cursor.fetchone()[0]
        
        cursor.execute("SELECT COUNT(*) FROM test_executions WHERE status = 'failed'")
        failed_tests = cursor.fetchone()[0]
        
        conn.close()
        
        return {
            'total': total_tests,
            'finished': finished_tests,
            'passed': passed_tests,
            'failed': failed_tests,
            'all_completed': total_tests == finished_tests
        }
    except Exception as e:
        print(f"Error checking test status: {e}")
        return None

def get_output_xml_files():
    """Get all output.xml files from the shared directory."""
    pattern = os.path.join(SHARED_OUTPUTS_DIR, "*_output.xml")
    xml_files = glob.glob(pattern)
    xml_files.sort()  # Sort for consistent ordering
    return xml_files

def merge_test_results():
    """Merge all output.xml files using rebot."""
    print("All tests completed! Starting to merge results...")
    
    # Ensure merged results directory exists
    os.makedirs(MERGED_RESULTS_DIR, exist_ok=True)
    
    # Get all output.xml files
    xml_files = get_output_xml_files()
    
    if not xml_files:
        print("Warning: No output.xml files found to merge!")
        return False
    
    print(f"Found {len(xml_files)} output.xml files to merge:")
    for xml_file in xml_files:
        print(f"  - {os.path.basename(xml_file)}")
    
    # Prepare rebot command
    merged_output_path = os.path.join(MERGED_RESULTS_DIR, "merged_output.xml")
    merged_log_path = os.path.join(MERGED_RESULTS_DIR, "merged_log.html")
    merged_report_path = os.path.join(MERGED_RESULTS_DIR, "merged_report.html")
    
    cmd = [
        "rebot",
        "--merge",
        "--output", merged_output_path,
        "--log", merged_log_path,
        "--report", merged_report_path,
        "--name", "Merged Test Results",
        "--doc", f"Merged results from {len(xml_files)} parallel test executions"
    ] + xml_files
    
    print(f"Running merge command: {' '.join(cmd[:8])} ... ({len(xml_files)} files)")
    
    try:
        # Run rebot to merge results
        start_time = datetime.now()
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False
        )
        
        end_time = datetime.now()
        merge_duration = end_time - start_time
        
        if result.returncode == 0:
            print(f"✅ Successfully merged test results in {merge_duration}")
            print(f"📊 Merged files created:")
            print(f"   - Output: {merged_output_path}")
            print(f"   - Log: {merged_log_path}")
            print(f"   - Report: {merged_report_path}")
            
            # Print some statistics from the merged output
            print_merge_statistics(merged_output_path)
            return True
        else:
            print(f"❌ Error merging test results (exit code: {result.returncode})")
            print(f"STDOUT: {result.stdout}")
            print(f"STDERR: {result.stderr}")
            return False
            
    except Exception as e:
        print(f"❌ Exception during merge: {e}")
        return False

def print_merge_statistics(merged_output_path):
    """Print statistics from the merged output file."""
    try:
        # Parse the merged XML to get statistics
        import xml.etree.ElementTree as ET
        tree = ET.parse(merged_output_path)
        root = tree.getroot()
        
        # Count tests and suites
        tests = root.findall(".//test")
        suites = root.findall(".//suite")
        
        passed_tests = len([t for t in tests if t.find("status").get("status") == "PASS"])
        failed_tests = len([t for t in tests if t.find("status").get("status") == "FAIL"])
        
        print(f"📈 Merge Statistics:")
        print(f"   - Total Suites: {len(suites)}")
        print(f"   - Total Tests: {len(tests)}")
        print(f"   - Passed: {passed_tests}")
        print(f"   - Failed: {failed_tests}")
        print(f"   - Success Rate: {(passed_tests/len(tests)*100):.1f}%" if tests else "N/A")
        
    except Exception as e:
        print(f"Could not parse merge statistics: {e}")

def monitor_and_merge():
    """Main monitoring loop."""
    print("🔍 Starting test results merger...")
    print(f"📁 Monitoring shared outputs directory: {SHARED_OUTPUTS_DIR}")
    print(f"📁 Merged results will be saved to: {MERGED_RESULTS_DIR}")
    print(f"🗄️ Database path: {DATABASE_PATH}")
    print(f"⏱️ Polling interval: {POLLING_INTERVAL} seconds")
    print("-" * 60)
    
    while True:
        status = get_test_status()
        
        if status is None:
            print("⚠️ Could not get test status, retrying in 30 seconds...")
            time.sleep(30)
            continue
        
        print(f"📊 Test Progress: {status['finished']}/{status['total']} completed "
              f"(✅ {status['passed']} passed, ❌ {status['failed']} failed)")
        
        if status['all_completed']:
            print("🎉 All tests completed!")
            
            # Wait a moment for any final file operations to complete
            time.sleep(5)
            
            # Merge the results
            if merge_test_results():
                print("✅ Test results merger completed successfully!")
                break
            else:
                print("❌ Test results merger failed!")
                sys.exit(1)
        else:
            print(f"⏳ Waiting for remaining {status['total'] - status['finished']} tests to complete...")
            time.sleep(POLLING_INTERVAL)

if __name__ == "__main__":
    try:
        monitor_and_merge()
    except KeyboardInterrupt:
        print("\n🛑 Test results merger interrupted by user")
        sys.exit(0)
    except Exception as e:
        print(f"💥 Fatal error in test results merger: {e}")
        sys.exit(1)
