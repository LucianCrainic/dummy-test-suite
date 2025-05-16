FROM python:3.11-slim

LABEL maintainer="Test Suite Maintainer"
LABEL description="Docker image for running Robot Framework test suite"

# Set environment variables
ENV PYTHONUNBUFFERED=1

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Set up work directory
WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt requests

# Add k8s test runner if it exists
COPY k8s_test_runner.py /app/k8s_test_runner.py
RUN chmod +x /app/k8s_test_runner.py

# Copy test files and entry script
COPY tests/ /tests/
COPY run_tests.sh /app/

# Make sure the entry script is executable
RUN chmod +x /app/run_tests.sh

# Create a volume for test results
VOLUME /results

# Set the entry point - default to run_tests.sh but can be overridden
ENTRYPOINT ["/app/run_tests.sh"]

# Default command runs all tests
CMD ["/tests"]
