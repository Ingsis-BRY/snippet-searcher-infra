# Snippet Searcher Infrastructure

Infrastructure repository for deploying Snippet Searcher microservices
on Azure Virtual Machines using Docker Swarm.

## Architecture

The planned infrastructure consists of:

- **Azure Virtual Machines:** Ubuntu Server instances hosting the cluster.
- **Docker Engine:** container runtime installed on each VM.
- **Docker Swarm:** container orchestration across cluster nodes.
- **GitHub Container Registry (GHCR):** storage for published Docker images.
- **GitHub Actions:** automated infrastructure validation and deployment.

The initial cluster will consist of one manager node and one worker node.
The manager maintains the cluster's desired state and schedules tasks,
while worker nodes execute assigned tasks.

The manager may also run application containers.

## Services

The initial Swarm stack includes the following services:

| Service | Image | Purpose |
|---|---|---|
| `snippet-service` | `ghcr.io/ingsis-bry/snippet-service:latest` | Spring Boot application |
| `postgres` | `postgres:17` | Relational database |
| `azurite` | `mcr.microsoft.com/azure-storage/azurite` | Local Azure Blob Storage emulator |

### Networking

Services communicate through the `snippet-network` overlay network.

The application accesses its dependencies using their service names:

- PostgreSQL: `postgres:5432`
- Azurite Blob Storage: `azurite:10000`

The application publishes port `8080` through Docker Swarm's ingress
routing mesh.

PostgreSQL and Azurite do not expose published ports in the Swarm stack.

### Persistence

PostgreSQL and Azurite use named Docker volumes to preserve data beyond
the lifecycle of individual containers.

These volumes are local to the node where they are created. Docker Swarm
does not automatically replicate or migrate their data between nodes.

Persistent storage and recovery procedures must be considered before
the infrastructure is treated as production-ready.

### Configuration and Secrets

The application receives its database and storage configuration through
environment variables:

- `POSTGRES_DB`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `AZURE_STORAGE_CONNECTION_STRING`

Required variables must be provided when deploying the stack.

Credentials, access tokens, and connection strings must not be committed
to this repository. They must be supplied through an appropriate
secret-management mechanism.

## Environments and Branching Strategy

The repository uses two deployment environments:

- **`dev`:** development and integration.
- **`prod`:** stable, validated releases.

The intended workflow is:

1. Create a feature branch for a change.
2. Open a pull request targeting `dev`.
3. Validate and test the changes in the development environment.
4. Promote validated changes from `dev` to `prod` through a pull request.

The `main` branch may remain from the repository's initial setup, but
`dev` and `prod` are the intended environment branches.

## CI/CD

### Continuous Integration

The GitHub Actions workflow in `.github/workflows/ci.yml` validates
infrastructure changes.

It runs on:

- Pull requests targeting `dev` or `prod`.
- Pushes to `dev`.
- Manual workflow dispatch.

The workflow checks the Bash syntax of `scripts/deploy.sh` and validates
the Swarm Compose configuration using Docker Compose.

This validation does not deploy services or verify connectivity between
the application and its dependencies.

### Continuous Deployment

Deployment is initially performed using the script:

`scripts/deploy.sh`

The script checks that an image reference is provided and that Docker
Swarm is active before executing `docker stack deploy`.

Automated deployments to the development and production environments
will be configured after the Azure VMs and Swarm cluster are ready.

## Repository Structure

```text
.
├── .github/
│   └── workflows/
│       └── ci.yml
├── swarm/
│   └── compose.yml
├── scripts/
│   └── deploy.sh
├── docs/
│   └── architecture.md
├── .gitignore
└── README.md