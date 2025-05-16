# Dummy Test Suite with Robot Framework

A simple Robot Framework test suite containing three test files (T01, T02, T03) with a mix of passing and failing tests.

## Project Structure

```
├── Dockerfile              # Docker configuration for running tests
├── docker-compose.yml      # Docker compose configuration
├── requirements.txt        # Python dependencies
├── run_tests.sh            # Test runner script
└── tests/                  # Test directory
    ├── T01/                # Test category 1
    │   └── T01_tests.robot # Test file 1
    ├── T02/                # Test category 2
    │   └── T02_tests.robot # Test file 2
    └── T03/                # Test category 3
        └── T03_tests.robot # Test file 3
```

## Test Categories

- **T01**: Basic tests with string operations and file system checks
- **T02**: Math and calculation tests
- **T03**: List and dictionary operation tests

Each test file contains a mix of passing and failing tests to demonstrate different test outcomes.

## Running Tests

### Using Docker

Build the Docker image:

```bash
docker build -t dummy-test-suite .
```

Run all tests:

```bash
docker run -v $(pwd)/results:/results dummy-test-suite
```

Run a specific test category:

```bash
docker run -v $(pwd)/results:/results dummy-test-suite /tests/T01
```

Run a specific test by name:

```bash
docker run -v $(pwd)/results:/results dummy-test-suite /tests "T01_01 Passing Test - Verify String Match"
```

### Using Docker Compose

Run all tests:

```bash
docker-compose up --build
```

Run a specific test category:

```bash
docker-compose run --build robot-tests /tests/T01
```

Run a specific test by name:

```bash
docker-compose run --build robot-tests /tests "T01_01 Passing Test - Verify String Match"
```

### Without Docker

Install dependencies:

```bash
pip install -r requirements.txt
```

Run the tests:

```bash
./run_tests.sh ./tests
```

Run a specific test by name:

```bash
./run_tests.sh ./tests "T01_01 Passing Test - Verify String Match"
```

## Test Results

Test results will be available in the `results` directory after running the tests.

## Test Database Tools

The project includes tools for parsing test names and storing them in a local database.

### Parsing Tests

To parse all Robot Framework tests and store them in a database:

```bash
./parse_robot_tests.py tests
```

This will scan all `.robot` files in the specified directory, extract test names, and store them in a SQLite database (`robot_tests.db`).

To list all tests after parsing:

```bash
./parse_robot_tests.py tests --list
```

### Querying the Database

Several options are available to query the test database:

```bash
# List all tests in the database
./query_robot_tests.py --list

# Search for tests containing a specific string
./query_robot_tests.py --search "Passing"

# Get details for a specific test by ID
./query_robot_tests.py --id 1

# Get details for tests with names containing a string
./query_robot_tests.py --name "String Match"

# Show database statistics
./query_robot_tests.py --stats
```

## Parallel Test Execution with Kubernetes

This project includes a Kubernetes-based solution for running tests in parallel across multiple nodes.

### Prerequisites

- Docker
- Kubernetes cluster (or Minikube for local development)
- kubectl

### Architecture

The system consists of:
1. A test API server that manages test distribution and status
2. Multiple test runner pods that execute tests in parallel
3. A shared database that tracks test status and results

### Setup and Run

1. Parse your tests and create a database:
   ```bash
   ./parse_robot_tests.py tests --list
   ```

2. Run the Kubernetes setup script:
   ```bash
   ./run_k8s_tests.sh --replicas 5 --reset --cleanup
   ```
   
   Options:
   - `--replicas N`: Number of parallel test runners (default: 5)
   - `--reset`: Reset all test statuses before starting
   - `--cleanup`: Clean up Kubernetes resources after completion

### Monitoring Tests

You can monitor the test execution in several ways:

1. Check pod status:
   ```bash
   kubectl get pods -n robot-tests
   ```

2. View test runner logs:
   ```bash
   kubectl logs -f deployment/robot-test-runner -n robot-tests
   ```

3. Access the API status endpoint:
   ```bash
   kubectl port-forward service/test-api-service 8000:8000 -n robot-tests
   ```
   Then visit: http://localhost:8000/api/status

### How It Works

1. The API server exposes endpoints for:
   - Getting the next available test
   - Updating test statuses
   - Viewing the overall test progress

2. Each test runner pod:
   - Requests a test from the API
   - Executes the test
   - Reports the result back
   - Repeats until no more tests are available

3. Tests are automatically distributed across all available pods,
   maximizing parallelism while ensuring each test runs only once.
