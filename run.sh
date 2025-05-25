#!/bin/bash

# Entry point script for running Robot Framework tests

# Define paths
TESTS_DIR="/tests"
RESULTS_DIR="/results"

# Create results directory if it doesn't exist
mkdir -p $RESULTS_DIR

# Function to print section headers
print_header() {
    echo "================================================"
    echo "$1"
    echo "================================================"
}

# Check if a test name is provided (if more than one argument is given)
if [ $# -gt 1 ]; then
    # Combine all arguments after the first one as the test name
    shift
    TEST_NAME="$*"
    print_header "Running Robot Framework test: '$TEST_NAME'"
    
    # Search for the test in all test files and execute it if found
    # The --test option allows running tests by name
    robot --outputdir $RESULTS_DIR \
          --xunit xunit.xml \
          --log log.html \
          --report report.html \
          --output output.xml \
          --test "$TEST_NAME" \
          $TESTS_DIR
else
    # Parse command-line arguments for directory-based running
    TEST_PATH=${1:-"$TESTS_DIR"}  # Default to all tests if none specified
    print_header "Running Robot Framework tests from: $TEST_PATH"

    # Run the tests and generate reports
    robot --outputdir $RESULTS_DIR \
          --xunit xunit.xml \
          --log log.html \
          --report report.html \
          --output output.xml \
          $TEST_PATH
fi

EXIT_CODE=$?

print_header "Tests completed with exit code: $EXIT_CODE"

# Display test summary
if [ -f "$RESULTS_DIR/output.xml" ]; then
    echo "Test Summary:"
    echo "-------------"
    python -c "
import xml.etree.ElementTree as ET
root = ET.parse('$RESULTS_DIR/output.xml').getroot()
stats = root.find('statistics/total/stat')
print(f'Total: {stats.attrib.get(\"total\", \"N/A\")}')
print(f'Passed: {stats.attrib.get(\"pass\", \"N/A\")}')
print(f'Failed: {stats.attrib.get(\"fail\", \"N/A\")}')
"
fi

# Return the test run exit code
exit $EXIT_CODE
