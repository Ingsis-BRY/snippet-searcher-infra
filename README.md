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

To create a VM step by step with the Azure CLI, see
[`docs/azure-vm-setup.md`](docs/azure-vm-setup.md).

## Services

The initial Swarm stack includes the following services:

| Service | Image | Purpose |
|---|---|---|
| `nginx` | `nginx:1.28-alpine` | Reverse proxy, TLS termination and public entry point |
| `snippet-service` | `$SNIPPET_SERVICE_IMAGE` (e.g. `ghcr.io/ingsis-bry/snippet-service:<tag>`) | Spring Boot application |
| `printscript-ui` | `$PRINTSCRIPT_UI_IMAGE` (e.g. `ghcr.io/ingsis-bry/printscript-ui:<tag>`) | React/Vite frontend served by its own Nginx |
| `snippet-service-db` | `postgres:17` | Snippet service database |
| `snippet-permission-service` | `$PERMISSION_SERVICE_IMAGE` (e.g. `ghcr.io/ingsis-bry/snippet-permission-service:<tag>`) | Snippet permissions |
| `snippet-permission-db` | `postgres:17` | Permission database |
| `azurite` | `mcr.microsoft.com/azure-storage/azurite` | Local Azure Blob Storage emulator |

### Networking

Services communicate through the `snippet-network` overlay network.

The application accesses its dependencies using their service names:

- Snippet service database: `snippet-service-db:5432`
- Azurite Blob Storage: `azurite:10000`
- Permission service: `snippet-permission-service:8080`
- Permission database: `snippet-permission-db:5432`

Nginx publishes ports `80` and `443` through Docker Swarm's ingress
routing mesh. Port `80` redirects every request to HTTPS, except
`/nginx-health`. Port `443` terminates TLS and routes requests:

- `/api/*` to `snippet-service:8080`, with the `/api` prefix removed.
- everything else to `printscript-ui:80`.

The UI is a static build: 
- `VITE_API_BASE_URL`, `VITE_AUTH0_DOMAIN` and`VITE_AUTH0_CLIENT_ID` are baked into its image at build time
- `VITE_API_BASE_URL` must be `https://<domain>/api`. 
- The `printscript-ui`service has no published ports.

Nginx configuration lives in `swarm/nginx/default.conf` and is delivered to the container as a
Swarm config.

Swarm configs are immutable, so the config name includes a hash of the
file (`NGINX_CONFIG_VERSION`), computed by `scripts/deploy.sh`. Changing
the file produces a new config and Nginx is redeployed with it.

- Only Nginx publishes ports in the Swarm stack. 
- The other services, including `snippet-permission-service`, are reachable only inside the
`snippet-network` overlay network.

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
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -subj "/CN=localhost" \
    -keyout certs/tls.key -out certs/tls.crt
```

### Let's Encrypt

Trusted certificates are issued by Let's Encrypt using Certbot on the
manager node and the HTTP-01 webroot challenge. Nginx serves
`/.well-known/acme-challenge/` on port `80` from `/var/www/certbot`,
a directory on the manager that is bind-mounted into the container.
Nginx is constrained to the manager node for this reason.

Prerequisites:

- A DuckDNS subdomain (`<name>.duckdns.org`) whose IP points to the
  manager VM's public IP. The Azure public IP must be static; if it
  changes, update it on duckdns.org.
- Ports `80` and `443` open in the VM's network security group.
- Certbot installed on the manager: `sudo snap install --classic certbot`.

The webroot challenge does not use the DuckDNS API, so no DuckDNS token
is required.

First-time setup on the manager:

1. Create the webroot: `sudo mkdir -p /var/www/certbot`.
2. Deploy the stack with a self-signed certificate (see above).
3. Request the certificate and install the renewal hook:

   ```bash
   sudo DOMAIN=<name>.duckdns.org CERTBOT_EMAIL=<email> scripts/certbot-init.sh
   ```

   Set `CERTBOT_STAGING=1` to test against the Let's Encrypt staging
   environment first. Before requesting the real certificate, remove the
   staging one with `sudo certbot delete --cert-name <name>.duckdns.org`.

`scripts/certbot-init.sh` issues the certificate, installs
`scripts/certbot-deploy-hook.sh` as a Certbot deploy hook, switches Nginx
to the new certificate and runs `certbot renew --dry-run`.

Renewal is automatic. The Certbot snap runs `certbot renew` twice a day,
and after each successful renewal the deploy hook creates new TLS
secrets and updates only the Nginx service, so renewal does not require
the application's credentials.

Later full deployments must use the Let's Encrypt files and run as root,
since `/etc/letsencrypt` is only readable by root:

```bash
sudo -E TLS_CERT_FILE=/etc/letsencrypt/live/<name>.duckdns.org/fullchain.pem \
    TLS_KEY_FILE=/etc/letsencrypt/live/<name>.duckdns.org/privkey.pem \
    scripts/deploy.sh
```

### Persistence

The snippet service database, the permission database and Azurite use named Docker volumes
to preserve data beyond the lifecycle of individual containers. They are
constrained to the manager node so they always run next to their volumes.

These volumes are local to the node where they are created. Docker Swarm
does not automatically replicate or migrate their data between nodes.

Persistent storage and recovery procedures must be considered before
the infrastructure is treated as production-ready.

### Configuration and Secrets

`snippet-service` and its database (`snippet-service-db`) receive their
database settings from the following variables, passed to the containers
as `POSTGRES_DB`, `POSTGRES_USER` and `POSTGRES_PASSWORD`:

- `SERVICE_POSTGRES_DB`
- `SERVICE_POSTGRES_USER`
- `SERVICE_POSTGRES_PASSWORD`

The permission service and its database use their own variables, passed
to the containers the same way:

- `PERMISSION_POSTGRES_DB`
- `PERMISSION_POSTGRES_USER`
- `PERMISSION_POSTGRES_PASSWORD`

`snippet-service` stores snippet content in Azure Blob Storage through
`AZURE_STORAGE_CONNECTION_STRING`. With the in-stack Azurite emulator it
must point to the `azurite` service:

```text
DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://azurite:10000/devstoreaccount1;
```

`devstoreaccount1` and its key are Azurite's public, well-known emulator
defaults, not a real credential. A real Azure Storage account needs its
own connection string, which is a secret.

Both services validate Auth0 access tokens and need:

- `AUTH0_DOMAIN`: tenant domain, `snippet-searcher-bry.us.auth0.com`
- `AUTH0_AUDIENCE`: identifier of the Auth0 API, `https://snippet-searcher-api`

`snippet-service` also searches users in the Auth0 Management API with
the machine-to-machine application `Snippet Searcher Backend`
(`read:users`):

- `AUTH0_M2M_CLIENT_ID`
- `AUTH0_M2M_CLIENT_SECRET` (secret)

Both services also need `NEW_RELIC_LICENSE_KEY` (secret).

Deployment also requires `SNIPPET_SERVICE_IMAGE`,
`PERMISSION_SERVICE_IMAGE`, `PRINTSCRIPT_UI_IMAGE`, `TLS_CERT_FILE` and `TLS_KEY_FILE`.

#### Stack variables reference

`swarm/compose.yml` fails to render if any of these variables is missing.

| Variable | Used by | Description |
|---|---|---|
| `SNIPPET_SERVICE_IMAGE` | `snippet-service` | Image reference, e.g. `ghcr.io/ingsis-bry/snippet-service:<tag>` |
| `PERMISSION_SERVICE_IMAGE` | `snippet-permission-service` | Image reference, e.g. `ghcr.io/ingsis-bry/snippet-permission-service:<tag>` |
| `PRINTSCRIPT_UI_IMAGE` | `printscript-ui` | Image reference, e.g. `ghcr.io/ingsis-bry/printscript-ui:<tag>` |
| `SERVICE_POSTGRES_DB` | `snippet-service`, `snippet-service-db` | Snippet service database name |
| `SERVICE_POSTGRES_USER` | `snippet-service`, `snippet-service-db` | Snippet service database user |
| `SERVICE_POSTGRES_PASSWORD` | `snippet-service`, `snippet-service-db` | Snippet service database password (secret) |
| `PERMISSION_POSTGRES_DB` | `snippet-permission-service`, `snippet-permission-db` | Permission database name |
| `PERMISSION_POSTGRES_USER` | `snippet-permission-service`, `snippet-permission-db` | Permission database user |
| `PERMISSION_POSTGRES_PASSWORD` | `snippet-permission-service`, `snippet-permission-db` | Permission database password (secret) |
| `AZURE_STORAGE_CONNECTION_STRING` | `snippet-service` | Blob Storage connection string (Azurite form above) |
| `AUTH0_DOMAIN` | `snippet-service`, `snippet-permission-service` | Auth0 tenant domain |
| `AUTH0_AUDIENCE` | `snippet-service`, `snippet-permission-service` | Auth0 API identifier |
| `AUTH0_M2M_CLIENT_ID` | `snippet-service` | Auth0 Management API M2M client ID |
| `AUTH0_M2M_CLIENT_SECRET` | `snippet-service` | Auth0 Management API M2M client secret (secret) |
| `NEW_RELIC_LICENSE_KEY` | `snippet-service`, `snippet-permission-service` | New Relic license key (secret) |
| `TLS_CERT_FILE` | `nginx` | Path to the PEM certificate chain |
| `TLS_KEY_FILE` | `nginx` | Path to the PEM private key |
| `NGINX_CONFIG_VERSION` | `nginx` | Computed by `scripts/deploy.sh`; do not set manually |
| `TLS_VERSION` | `nginx` | Computed by `scripts/deploy.sh`; do not set manually |

[`swarm/.env.example`](swarm/.env.example) lists the variables to provide
by hand. Copy it to `swarm/.env` (git-ignored), fill in the values and
load it into the shell before deploying, since `docker stack deploy` does
not read `.env` files:

```bash
set -a; source swarm/.env; set +a
scripts/deploy.sh
```

The UI is a static build, so its Auth0 settings (`VITE_AUTH0_DOMAIN`,
`VITE_AUTH0_CLIENT_ID`, `VITE_AUTH0_AUDIENCE`) and `VITE_API_BASE_URL` are
set when its image is built, not here. The public URL of each environment
(`https://<domain>`) must be added to the Allowed Callback URLs, Allowed
Logout URLs and Allowed Web Origins of the `Snippet Searcher UI`
application in Auth0.

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

The workflow checks the Bash syntax of the scripts in `scripts/`, lints
them with ShellCheck, validates the Swarm Compose configuration using
Docker Compose, and validates the Nginx configuration with `nginx -t`.

This validation does not deploy services or verify connectivity between
the application and its dependencies.

### Continuous Deployment

Deployment is initially performed using the script:

`scripts/deploy.sh`

The script checks that the three image references are provided and that Docker
Swarm is active before executing `docker stack deploy`.

Automated deployments to the development and production environments
will be configured after the Azure VMs and Swarm cluster are ready.

## Repository Structure

```text
.
├── .github/
│   └── workflows/
│       └── CI.yml
├── docs/
│   ├── azure-vm-setup.md
│   └── azure-vm.env.example
├── swarm/
│   ├── nginx/
│   │   └── default.conf
│   ├── .env.example
│   └── compose.yml
├── scripts/
│   ├── certbot-deploy-hook.sh
│   ├── certbot-init.sh
│   └── deploy.sh
├── .gitattributes
├── .gitignore
└── README.md
```
