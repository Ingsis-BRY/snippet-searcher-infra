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
| `nginx` | `nginx:1.28-alpine` | Reverse proxy, TLS termination and public entry point |
| `snippet-service` | `$SNIPPET_SERVICE_IMAGE` (e.g. `ghcr.io/ingsis-bry/snippet-service:<tag>`) | Spring Boot application |
| `postgres` | `postgres:17` | Relational database |
| `azurite` | `mcr.microsoft.com/azure-storage/azurite` | Local Azure Blob Storage emulator |

### Networking

Services communicate through the `snippet-network` overlay network.

The application accesses its dependencies using their service names:

- PostgreSQL: `postgres:5432`
- Azurite Blob Storage: `azurite:10000`

Nginx publishes ports `80` and `443` through Docker Swarm's ingress
routing mesh. Port `80` redirects every request to HTTPS, except
`/nginx-health`. Port `443` terminates TLS and forwards requests to
`snippet-service:8080`. Its configuration lives
in `swarm/nginx/default.conf` and is delivered to the container as a
Swarm config.

Swarm configs are immutable, so the config name includes a hash of the
file (`NGINX_CONFIG_VERSION`), computed by `scripts/deploy.sh`. Changing
the file produces a new config and Nginx is redeployed with it.

The application, PostgreSQL and Azurite do not expose published ports in
the Swarm stack.

### TLS

The TLS certificate and private key are delivered to Nginx as Swarm
secrets. They are read from files on the machine running
`scripts/deploy.sh`:

- `TLS_CERT_FILE`: certificate chain in PEM format.
- `TLS_KEY_FILE`: private key in PEM format.

The secret names include a hash of both files (`TLS_VERSION`), so
replacing the certificate produces new secrets on the next deployment.

Certificate and key files must never be committed to this repository.

For local testing, a self-signed certificate can be generated with:

```bash
mkdir -p certs
openssl req -x509 -nodes -newkey rsa:2048 -days 365     -subj "/CN=localhost"     -keyout certs/tls.key -out certs/tls.crt
```

### Persistence

PostgreSQL and Azurite use named Docker volumes to preserve data beyond
the lifecycle of individual containers. Both services are constrained
to the manager node so they always run next to their volumes.

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

Deployment also requires `SNIPPET_SERVICE_IMAGE`, `TLS_CERT_FILE` and
`TLS_KEY_FILE`.

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

The GitHub Actions workflow in `.github/workflows/CI.yml` validates
infrastructure changes.

It runs on:

- Pull requests targeting `dev` or `prod`.
- Pushes to `dev`.
- Manual workflow dispatch.

The workflow checks the Bash syntax of `scripts/deploy.sh`, validates
the Swarm Compose configuration using Docker Compose, and validates the
Nginx configuration with `nginx -t`.

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
│       └── CI.yml
├── swarm/
│   ├── nginx/
│   │   └── default.conf
│   └── compose.yml
├── scripts/
│   └── deploy.sh
├── .gitignore
└── README.md
```
