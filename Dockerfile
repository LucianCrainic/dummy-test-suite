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
COPY worker.py /app/worker.py
RUN chmod +x /app/worker.py

# Copy test files and entry script
COPY tests/ /tests/
COPY run.sh /app/

# Make sure the entry script is executable
RUN chmod +x /app/run.sh

# Create a volume for test results
VOLUME /results

# Set the entry point - default to run.sh but can be overridden
ENTRYPOINT ["/app/run.sh"]

# Default command runs all tests
CMD ["/tests"]
