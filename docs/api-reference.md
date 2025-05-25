# API Reference

This document provides comprehensive API documentation for the Robot Framework Parallel Test Suite's REST API server.

## Overview

The API server (`server.py`) provides a RESTful interface for coordinating test execution across multiple worker pods. It manages test distribution, status tracking, and execution coordination using a SQLite database backend.

**Base URL**: `http://test-api-service:8000` (within cluster)  
**Local Access**: `http://localhost:8000` (via port forwarding)

## Authentication

Currently, the API does not implement authentication. In production environments, consider implementing:
- API keys
- JWT tokens
- Service mesh authentication
- Kubernetes RBAC

## API Endpoints

### Test Management

#### Get Next Test
Retrieves the next available test for execution by a worker pod.

```http
GET /api/next_test?node_id={node_id}
```

**Parameters:**
- `node_id` (query, optional): Identifier for the requesting worker node

**Response (200 OK):**
```json
{
  "execution_id": "550e8400-e29b-41d4-a716-446655440000",
  "test_id": 42,
  "test_name": "T01_01 Passing Test - Verify String Match",
  "suite_name": "T01",
  "file_path": "/tests/T01/T01_tests.robot"
}
```

**Response (404 Not Found):**
```json
{
  "message": "No tests available"
}
```

**Response (500 Internal Server Error):**
```json
{
  "error": "Database not found"
}
```

**Example:**
```bash
curl "http://localhost:8000/api/next_test?node_id=worker-pod-1"
```

#### Update Test Status
Updates the execution status of a test after completion.

```http
POST /api/update_test
```

**Request Body:**
```json
{
  "execution_id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "completed",
  "result_data": "{\"status\": \"completed\", \"returncode\": 0, \"execution_time\": \"0:00:05.123456\"}"
}
```

**Response (200 OK):**
```json
{
  "message": "Test status updated successfully"
}
```

**Response (400 Bad Request):**
```json
{
  "error": "Missing required fields: execution_id, status"
}
```

**Response (404 Not Found):**
```json
{
  "error": "Execution not found"
}
```

**Example:**
```bash
curl -X POST http://localhost:8000/api/update_test \
  -H "Content-Type: application/json" \
  -d '{
    "execution_id": "550e8400-e29b-41d4-a716-446655440000",
    "status": "completed",
    "result_data": "{\"returncode\": 0}"
  }'
```

### Status and Monitoring

#### Get System Status
Returns comprehensive status information about test execution.

```http
GET /api/status
```

**Response (200 OK):**
```json
{
  "total_tests": 25,
  "status_counts": {
    "pending": 5,
    "running": 3,
    "completed": 15,
    "failed": 2
  },
  "execution_summary": {
    "total_executions": 20,
    "active_workers": 3,
    "completion_percentage": 80.0
  },
  "recent_executions": [
    {
      "execution_id": "550e8400-e29b-41d4-a716-446655440000",
      "test_name": "T01_01 Passing Test",
      "node_id": "worker-pod-1",
      "status": "completed",
      "start_time": "2025-01-01T10:00:00",
      "end_time": "2025-01-01T10:00:05"
    }
  ]
}
```

**Example:**
```bash
curl http://localhost:8000/api/status
```

#### Reset Test Statuses
Resets all test execution statuses to pending state.

```http
POST /api/reset
```

**Response (200 OK):**
```json
{
  "message": "All test statuses have been reset to pending",
  "reset_count": 25
}
```

**Example:**
```bash
curl -X POST http://localhost:8000/api/reset
```

### Web Interface

#### Dashboard
Provides a web-based dashboard for monitoring test execution.

```http
GET /
```

**Response**: HTML dashboard with real-time status updates

**Features:**
- Live test execution progress
- Worker node status
- Recent test completions
- Error summaries

## Data Models

### Test Case
```json
{
  "id": 1,
  "test_name": "T01_01 Passing Test - Verify String Match",
  "file_path": "/tests/T01/T01_tests.robot",
  "suite_name": "T01",
  "parsed_date": "2025-01-01T09:00:00",
  "status": "pending"
}
```

### Test Execution
```json
{
  "id": 1,
  "execution_id": "550e8400-e29b-41d4-a716-446655440000",
  "test_id": 1,
  "node_id": "worker-pod-1",
  "status": "completed",
  "start_time": "2025-01-01T10:00:00",
  "end_time": "2025-01-01T10:00:05",
  "result_data": "{\"returncode\": 0, \"execution_time\": \"0:00:05\"}"
}
```

## Status Values

### Test Status
- `pending`: Test has not been assigned to any worker
- `running`: Test is currently being executed
- `completed`: Test execution finished successfully
- `failed`: Test execution encountered an error

### Execution Status
- `running`: Execution is in progress
- `completed`: Execution finished successfully
- `failed`: Execution failed or encountered an error

## Error Handling

### HTTP Status Codes
- `200 OK`: Request successful
- `400 Bad Request`: Invalid request parameters or body
- `404 Not Found`: Requested resource not found
- `500 Internal Server Error`: Database or server error

### Error Response Format
```json
{
  "error": "Descriptive error message",
  "details": "Additional error details (optional)"
}
```

## Database Operations

### Transaction Safety
The API uses SQLite with exclusive transactions to ensure data consistency:

```python
# Example transaction for test assignment
cursor.execute('BEGIN IMMEDIATE TRANSACTION')
# ... find and assign test ...
cursor.execute('UPDATE test_cases SET status = ? WHERE id = ?', ('running', test_id))
conn.commit()
```

### Connection Management
- Database connections are created per request
- Automatic connection cleanup on request completion
- Row factory enabled for dictionary-style access

## Monitoring and Observability

### Health Checks
```bash
# Basic connectivity test
curl -f http://localhost:8000/api/status

# Detailed health information
curl -s http://localhost:8000/api/status | jq '.status_counts'
```

### Metrics Collection
The API exposes several metrics useful for monitoring:

```bash
# Get completion percentage
curl -s http://localhost:8000/api/status | jq '.execution_summary.completion_percentage'

# Count active workers
curl -s http://localhost:8000/api/status | jq '.execution_summary.active_workers'

# Get failure rate
curl -s http://localhost:8000/api/status | jq '.status_counts.failed'
```

## Client Examples

### Python Client
```python
import requests
import json

class TestAPIClient:
    def __init__(self, base_url):
        self.base_url = base_url
    
    def get_next_test(self, node_id):
        response = requests.get(
            f"{self.base_url}/api/next_test",
            params={"node_id": node_id}
        )
        if response.status_code == 200:
            return response.json()
        return None
    
    def update_test_status(self, execution_id, status, result_data=None):
        payload = {
            "execution_id": execution_id,
            "status": status,
            "result_data": result_data
        }
        response = requests.post(
            f"{self.base_url}/api/update_test",
            json=payload
        )
        return response.status_code == 200
    
    def get_status(self):
        response = requests.get(f"{self.base_url}/api/status")
        return response.json()

# Usage
client = TestAPIClient("http://localhost:8000")
test = client.get_next_test("my-worker")
if test:
    # Execute test...
    client.update_test_status(test["execution_id"], "completed")
```

### Shell Script Client
```bash
#!/bin/bash
API_URL="http://localhost:8000"
NODE_ID="shell-worker"

# Get next test
get_next_test() {
    curl -s "${API_URL}/api/next_test?node_id=${NODE_ID}"
}

# Update test status
update_test_status() {
    local execution_id="$1"
    local status="$2"
    local result_data="$3"
    
    curl -s -X POST "${API_URL}/api/update_test" \
        -H "Content-Type: application/json" \
        -d "{
            \"execution_id\": \"${execution_id}\",
            \"status\": \"${status}\",
            \"result_data\": \"${result_data}\"
        }"
}

# Get system status
get_status() {
    curl -s "${API_URL}/api/status" | jq '.'
}
```

## Performance Considerations

### Database Optimization
- Use connection pooling for high-concurrency scenarios
- Consider read replicas for status queries
- Monitor database lock contention

### Caching Strategies
- Cache frequently accessed test metadata
- Implement result caching for status endpoints
- Use ETags for conditional requests

### Rate Limiting
Consider implementing rate limiting for production deployments:
- Per-worker request limits
- Global API rate limits
- Burst protection mechanisms

## Security Considerations

### Input Validation
All API endpoints validate input parameters:
- Required field validation
- Data type checking
- SQL injection prevention

### Database Security
- Use parameterized queries exclusively
- Implement proper access controls
- Regular security updates

### Network Security
- Use HTTPS in production
- Implement proper CORS policies
- Network segmentation for API access

This API reference provides comprehensive documentation for integrating with and extending the Robot Framework Parallel Test Suite's coordination API.
