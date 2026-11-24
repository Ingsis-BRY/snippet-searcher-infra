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
| `printscript-engine` | `$PRINTSCRIPT_ENGINE_IMAGE` (e.g. `ghcr.io/ingsis-bry/printscript-engine:<tag>`) | PrintScript engine (validate and interactive run), 2 replicas, internal only |
| `engine-proxy` | `nginx:1.28-alpine` | Internal proxy that picks the engine by the `X-Language` header and spreads requests over its replicas |
| `printscript-ui` | `$PRINTSCRIPT_UI_IMAGE` (e.g. `ghcr.io/ingsis-bry/printscript-ui:<tag>`) | React/Vite frontend served by its own Nginx |
| `snippet-worker` | `$SNIPPET_SERVICE_IMAGE` (same image, Spring profile `worker`) | Background consumer of the Redis stream: lint, format, run tests, re-validate on parser upgrade. No HTTP server, no published ports |
| `redis` | `redis:7.4-alpine` | Redis Streams broker (AOF persistence), internal only |
| `snippet-service-db` | `postgres:17` | Snippet service database |
| `snippet-permission-service` | `$PERMISSION_SERVICE_IMAGE` (e.g. `ghcr.io/ingsis-bry/snippet-permission-service:<tag>`) | Snippet permissions |
| `snippet-permission-db` | `postgres:17` | Permission database |
| `azurite` | `mcr.microsoft.com/azure-storage/azurite` | Local Azure Blob Storage emulator |

### Asynchronous processing

`snippet-service` (profile `api`, the producer) publishes jobs to the Redis Stream `snippet.analysis`
when a snippet is created or updated, when a user saves lint/format rules, and when tests change.
`snippet-worker` (the same image with `SPRING_PROFILES_ACTIVE=worker`) consumes them through the
consumer group `snippet-workers`. Jobs that fail permanently, or exceed the delivery limit, go to the
dead-letter stream `snippet.analysis.dlq`. Pending entries are reclaimed after a crash, and a periodic
sweeper republishes work lost while Redis was down. When the PrintScript library version reported by the
engine changes, the worker re-validates every snippet.

Inspect it on the manager node:

```bash
REDIS=$(docker ps -q -f name=snippet-searcher_redis)
docker exec "$REDIS" redis-cli XINFO GROUPS snippet.analysis    # pending / lag per group
docker exec "$REDIS" redis-cli XLEN snippet.analysis.dlq        # failed jobs
docker exec "$REDIS" redis-cli XRANGE snippet.analysis.dlq - + COUNT 5
docker service logs snippet-searcher_snippet-worker
```

### Networking

Services communicate through the `snippet-network` overlay network.

The application accesses its dependencies using their service names:

- Snippet service database: `snippet-service-db:5432`
- Azurite Blob Storage: `azurite:10000`
- Permission service: `snippet-permission-service:8080`
- Permission database: `snippet-permission-db:5432`
- Redis: `redis:6379` (no password, reachable only inside the overlay network)

Nginx publishes ports `80` and `443` through Docker Swarm's ingress
routing mesh. Port `80` redirects every request to HTTPS, except
`/nginx-health`. Port `443` terminates TLS and routes requests:

- `/api/snippets/{id}/run` (WebSocket) to `snippet-service:8080`, with the `/api` prefix removed.
- `/api/*` to `snippet-service:8080`, with the `/api` prefix removed.
- everything else to `printscript-ui:80`.

The UI is a static build that calls the API on its own origin (`/api`), so the same image
serves every environment. Only its Auth0 settings (`VITE_AUTH0_DOMAIN`, `VITE_AUTH0_CLIENT_ID`,
`VITE_AUTH0_AUDIENCE`) are baked in, and they are the same tenant everywhere. The
`printscript-ui` service has no published ports.

Each environment has its own DuckDNS subdomain and certificate. `swarm/nginx/default.conf` is a
template with a `${DOMAIN}` placeholder in `server_name`; `scripts/deploy.sh` renders it with the
environment's `DOMAIN` into `swarm/nginx/default.rendered.conf` (git-ignored) and delivers that to
the container as a Swarm config. Only the literal `${DOMAIN}` is replaced, so nginx's own
`$variables` are untouched.

Swarm configs are immutable, so the config name includes a hash of the rendered file
(`NGINX_CONFIG_VERSION`), computed by `scripts/deploy.sh`. Changing the file or the domain produces
a new config and Nginx is redeployed with it.

Nginx writes one JSON line per request (`request_id`, status, timings, `traceparent`) and forwards
its `$request_id` upstream as `X-Request-Id`.

- Only Nginx publishes ports in the Swarm stack.
- The other services, including `snippet-permission-service`, are reachable only inside the
`snippet-network` overlay network.

### Engine and interactive run

`snippet-service` validates and runs snippets through the PrintScript
engine. It calls `ENGINE_URL` (`http://engine-proxy:80`). `engine-proxy`
and `printscript-engine` sit on the internal overlay network
`engine-network`; only `engine-proxy` is also on `snippet-network`, and
neither publishes ports. `printscript-engine` uses `endpoint_mode: dnsrr`
so DNS returns one address per replica and the proxy's `resolve` and
`proxy_next_upstream` work per replica.

The proxy config is `swarm/nginx/engine-proxy.conf`, a byte-identical copy
of `nginx/engine-proxy.conf` in the `printscript-engine` repo (the source of
truth: keep both in sync). Like the nginx config, it is a Swarm config named
with a hash of the file (`ENGINE_PROXY_CONFIG_VERSION`, computed by
`scripts/deploy.sh`).

The interactive run is a WebSocket at `/api/snippets/{id}/run`. Nginx has a
dedicated location for it with `Upgrade`/`Connection` forwarding and 360 s
timeouts. The browser sends the access token in the `Sec-WebSocket-Protocol`
header (`snippet-run.v1, bearer.<jwt>`), never in the URL, so it does not
reach the access or error logs (the default log format does not include
that header).

### TLS

The TLS certificate and private key are delivered to Nginx as Swarm
secrets (`tls-cert-<version>` and `tls-key-<version>`, where the version is a
hash of both files).

On the **first** deployment only, `scripts/deploy.sh` creates them from the
files named by `TLS_CERT_FILE` (certificate chain, PEM) and `TLS_KEY_FILE`
(private key, PEM), normally a self-signed certificate. Afterwards it reuses
the secrets that `nginx` already has, so automated deployments need no
certificate files and never overwrite the Let's Encrypt certificate that the
Certbot deploy hook installed.

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

Later full deployments (manual or from GitHub Actions) reuse the TLS secrets
that Certbot installed and do not need the certificate files.

### Persistence

The snippet service database, the permission database, Azurite and Redis (`redis-data`) use named Docker volumes
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

`snippet-worker` reuses `SNIPPET_SERVICE_IMAGE` and every `snippet-service` variable (shared through a YAML anchor in `swarm/compose.yml`). `REDIS_HOST` and `REDIS_PORT` are set in the compose file; no new variable has to be provided.

Deployment also requires `SNIPPET_SERVICE_IMAGE`,
`PERMISSION_SERVICE_IMAGE`, `PRINTSCRIPT_UI_IMAGE` and `PRINTSCRIPT_ENGINE_IMAGE`.

#### Docker secrets

Passwords and keys are Docker secrets that already exist in the Swarm. They
are created once per VM with `scripts/create-secrets.sh` (values are typed at
a hidden prompt and go to Docker over stdin; nothing is written to a file or
to the shell history). `swarm/compose.yml` declares them as `external` and
`scripts/deploy.sh` stops if one is missing. No `.env` file is used.

| Secret | Mounted in | As | Description |
|---|---|---|---|
| `service-postgres-password` | `snippet-service`, `snippet-worker`, `snippet-service-db` | `POSTGRES_PASSWORD` / `postgres_password` | Snippet service database password |
| `permission-postgres-password` | `snippet-permission-service`, `snippet-permission-db` | `POSTGRES_PASSWORD` / `postgres_password` | Permission database password |
| `azure-storage-connection-string-v2` | `snippet-service`, `snippet-worker` | `azure.storage.connection-string` | Azure Blob (Azurite) connection string |
| `auth0-m2m-client-secret` | `snippet-service`, `snippet-worker` | `AUTH0_M2M_CLIENT_SECRET` | Secret of the Auth0 Management API M2M application (user search) |
| `new-relic-license-key` | `snippet-service`, `snippet-worker`, `snippet-permission-service`, `synthetic-check` | `NEW_RELIC_LICENSE_KEY` | New Relic ingest license key |
| `synthetic-client-secret` | `synthetic-check` | `SYNTHETIC_CLIENT_SECRET` | Secret of the Auth0 M2M application the synthetic check logs in with |

The Spring services read them through `SPRING_CONFIG_IMPORT=configtree:/run/secrets/`:
each file is named after the placeholder in `application.yml`, so the
applications need no change. The New Relic agent only reads environment
variables, so the entrypoint exports `NEW_RELIC_LICENSE_KEY` from its secret
file before starting the same `java` command as the image. The Postgres images
use their native `POSTGRES_PASSWORD_FILE`.

Docker secrets are immutable. To rotate one, remove the services that use it
(or the whole stack), `docker secret rm <name>`, create it again with
`scripts/create-secrets.sh` and redeploy.

The remaining settings (images, database names and users, Auth0 domain,
audience and client ID) are not secret. They are environment variables
supplied at deploy time; in GitHub Actions they are the `vars` of the
`dev` / `prod` environment.

#### Stack variables reference

`swarm/compose.yml` fails to render if any of these variables is missing. Secrets are listed above; `TLS_CERT_FILE` and `TLS_KEY_FILE` are only read on the first deployment.

| Variable | Used by | Description |
|---|---|---|
| `SNIPPET_SERVICE_IMAGE` | `snippet-service` | Image reference, e.g. `ghcr.io/ingsis-bry/snippet-service:<tag>` |
| `PERMISSION_SERVICE_IMAGE` | `snippet-permission-service` | Image reference, e.g. `ghcr.io/ingsis-bry/snippet-permission-service:<tag>` |
| `PRINTSCRIPT_UI_IMAGE` | `printscript-ui` | Image reference, e.g. `ghcr.io/ingsis-bry/printscript-ui:<tag>` |
| `PRINTSCRIPT_ENGINE_IMAGE` | `printscript-engine` | Image reference, e.g. `ghcr.io/ingsis-bry/printscript-engine:<tag>` |
| `ENGINE_URL` | `snippet-service` | Set in `swarm/compose.yml` to `http://engine-proxy:80`; not provided by hand |
| `SERVICE_POSTGRES_DB` | `snippet-service`, `snippet-service-db` | Snippet service database name |
| `SERVICE_POSTGRES_USER` | `snippet-service`, `snippet-service-db` | Snippet service database user |
| `PERMISSION_POSTGRES_DB` | `snippet-permission-service`, `snippet-permission-db` | Permission database name |
| `PERMISSION_POSTGRES_USER` | `snippet-permission-service`, `snippet-permission-db` | Permission database user |
| `AUTH0_DOMAIN` | `snippet-service`, `snippet-permission-service` | Auth0 tenant domain |
| `AUTH0_AUDIENCE` | `snippet-service`, `snippet-permission-service` | Auth0 API identifier |
| `AUTH0_M2M_CLIENT_ID` | `snippet-service` | Auth0 Management API M2M client ID |
| `DOMAIN` | `nginx` (rendered by `deploy.sh`) | This environment's public host: `snippet-searcher-bry.duckdns.org` (dev), `snippet-searcher-bry-prod.duckdns.org` (prod). Defaults to `snippet-searcher-bry.duckdns.org` with a warning |
| `DEPLOY_ENVIRONMENT` | New Relic app names, `synthetic-check` | `dev` or `prod`; set by the CD workflow |
| `SYNTHETIC_CLIENT_ID` | `synthetic-check` | Client ID of the Auth0 M2M application authorized for the API (`read:snippets`, `write:snippets`) |
| `SYNTHETIC_SCRIPT_VERSION` | `synthetic-check` | Computed by `scripts/deploy.sh`; do not set manually |
| `NGINX_CONFIG_VERSION` | `nginx` | Computed by `scripts/deploy.sh`; do not set manually |
| `ENGINE_PROXY_CONFIG_VERSION` | `engine-proxy` | Computed by `scripts/deploy.sh`; do not set manually |
| `TLS_VERSION` | `nginx` | Computed by `scripts/deploy.sh`; do not set manually |

The UI is a static build, so its Auth0 settings (`VITE_AUTH0_DOMAIN`,
`VITE_AUTH0_CLIENT_ID`, `VITE_AUTH0_AUDIENCE`) are set when its image is built, not here. It needs
no API URL: it calls `/api` on whatever domain serves it. The public URL of each environment
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
Docker Compose, and validates the Nginx and engine proxy configurations with `nginx -t`.

This validation does not deploy services or verify connectivity between
the application and its dependencies.

### Continuous Deployment

Deployments run `scripts/deploy.sh` on the target VM over SSH:

| Workflow | Target | Trigger |
|---|---|---|
| `.github/workflows/CD-dev.yml` | dev VM | Push to `dev` (a merged PR into `dev`), or manual dispatch |
| `.github/workflows/CD-prod.yml` | prod VM | A pull request from `dev` into `prod` is **merged**. PRs from other branches, unmerged PRs and direct pushes never deploy |

Each workflow uses the GitHub Environment of the same name (`dev`, `prod`;
add required reviewers to `prod`) and never runs two deployments of the same
environment at once. The VM checks out the exact commit that triggered the run.

Environment **secrets**: `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`
(a dedicated deploy key, not a personal one) and `DEPLOY_KNOWN_HOSTS`
(`ssh-keyscan <host>`).

Environment **variables** (not secret): `DEPLOY_PATH` (absolute path of the
repository clone on the VM), `SNIPPET_SERVICE_IMAGE`,
`PERMISSION_SERVICE_IMAGE`, `PRINTSCRIPT_UI_IMAGE`,
`PRINTSCRIPT_ENGINE_IMAGE`, `SERVICE_POSTGRES_DB`, `SERVICE_POSTGRES_USER`,
`PERMISSION_POSTGRES_DB`, `PERMISSION_POSTGRES_USER`, `AUTH0_DOMAIN`,
`AUTH0_AUDIENCE`, `AUTH0_M2M_CLIENT_ID`, `DOMAIN` (this environment's subdomain) and
`SYNTHETIC_CLIENT_ID`.

`deploy.sh` does not stop at `docker stack deploy`. Every stateless service has a healthcheck and
`update_config` with `order: start-first`, `failure_action: rollback` and a 60 s monitor, so Swarm
starts the new task, waits for it to be healthy and rolls back on its own if it isn't. The script
then waits (up to `CONVERGE_TIMEOUT`, 600 s) for every service to settle and **fails the
deployment** if one rolled back or isn't running all its replicas, which marks the GitHub run red.
To roll back by hand, redeploy an older commit (`workflow_dispatch` on CD-dev) or point the image
variables at an older `:<sha>` tag.

Order matters when a change spans repositories: merge and publish the service images first, then
the infra change that depends on them (for example, healthchecks need images with `/actuator/health`).

Before the first automated deployment, on each VM: clone this repository at
`DEPLOY_PATH`, run `scripts/create-secrets.sh`, and do the first deployment
by hand with a self-signed certificate (see TLS). The deploy user needs
passwordless `sudo`.

GitHub-hosted runners have no fixed IP and SSH is closed to everyone but
the administrator. Each workflow logs in to Azure with OIDC, creates a
temporary NSG rule (`Allow-GitHub-Deploy-Dev` / `Allow-GitHub-Deploy-Prod`) allowing port 22 from the runner's
IP only, deploys, and deletes the rule in a final step that always runs. The
Azure identity can only edit security rules of that one NSG; see
`docs/azure-vm-setup.md`, section 4.4.1. Add the environment variables
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
`AZURE_RESOURCE_GROUP` and `AZURE_NSG_NAME`.

## Observability

- **APM and logs:** the New Relic Java agent runs in `snippet-service`, `snippet-worker` and
  `snippet-permission-service`, with app names suffixed by environment (`snippet-service-dev`,
  `snippet-service-prod`, ...). Their logs go to stdout as JSON (Elastic Common Schema,
  `LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs`) and the agent forwards them.
- **Correlation:** Micrometer Tracing gives each request a `traceId` that appears in every log line
  and travels to `snippet-permission-service` and the engine in the W3C `traceparent` header. Jobs
  sent to the worker through Redis carry it too: the worker logs it as `jobTraceId` (its own calls
  get their own `traceId`), so searching one id finds a change from the API to the background work.
- **The engine** has no agent: it runs on an internal network with no internet access, by design.
  It is observed through `snippet-service`'s external calls to `engine-proxy` and its JSON logs.
- **Synthetic check:** the `synthetic-check` service creates, reads and deletes a snippet through
  the API every minute, logged in as an Auth0 machine-to-machine application, and sends
  `snippet_searcher.synthetic.success` and `snippet_searcher.synthetic.duration_ms` to New Relic
  (`swarm/synthetic/check.sh`).
- **Alerts:** `scripts/newrelic-alerts.sh dev|prod` creates the policy *Snippet Searcher (env)*
  through NerdGraph, with `NEW_RELIC_API_KEY` (a user key) and `NEW_RELIC_ACCOUNT_ID` in the
  environment. Conditions: synthetic check failing or silent, API error rate above 5 %, API p95
  latency above 2 s, worker errors. Notifications are attached in New Relic (Alerts > Workflows).

### Service level objectives

| SLO | Target | Measured by |
|---|---|---|
| Availability | 99 % of synthetic checks succeed over 7 days | `snippet_searcher.synthetic.success` |
| Latency | p95 of API requests under 1 s (alert at 2 s) | `Transaction` duration of `snippet-service-<env>` |
| Background processing | No job stays pending more than 10 min (then the sweeper requeues it) | worker logs, DLQ length |

### Setting up the synthetic check (once per environment)

1. In Auth0, create a **Machine to Machine** application, authorize it for the
   `https://snippet-searcher-api` API with `read:snippets` and `write:snippets`.
2. Add its client ID as the `SYNTHETIC_CLIENT_ID` variable of the GitHub environment.
3. On the VM, run `scripts/create-secrets.sh` and paste its client secret for
   `synthetic-client-secret` (existing secrets are skipped).

### Dashboard

`observability/dashboard-dev.json` and `dashboard-prod.json` are ready to import in New Relic
(**Dashboards > Import dashboard**, paste the file). Page *Tiempo real*: requests per minute, p95, error
rate, synthetic check, traffic by source (users, Cypress, Locust, synthetic, told apart by `User-Agent`),
latency percentiles, endpoints, time in Postgres vs external services, logs and memory. Page *Prueba de
carga*: Locust traffic only, and CPU. They are generated by `observability/build_dashboard.py` (account id
and environment as arguments).

## Load Testing

[Locust](https://locust.io) scenarios in `load/`, run from any machine against a deployed environment.
Simulated users list, search, create, read, format and delete snippets; they authenticate with the
synthetic check's Auth0 M2M application and send `User-Agent: snippet-searcher-locust`. Snippets they
create are deleted right away.

| File | What it runs |
|---|---|
| `load/locustfile.py` | Users and tasks; constant load (`-u`, `-r`, `-t`) |
| `load/demo.py` | 4 minutes for a live demo: ramp to 15 users, peak of 40, back to 10 |
| `load/extended.py` | About 40 minutes in phases: 10, 25 (15 min), 50, 80 (spike), 25, 10 users; stops by itself above 10 % failures |

Setup, once per machine:

```bash
python -m venv load/.venv
load/.venv/bin/pip install -r load/requirements.txt      # Windows: load\.venv\Scripts\pip
# put the M2M application's client secret in load/client_secret, one line (git-ignored), or export SYNTHETIC_CLIENT_SECRET
```

Run (web UI on http://localhost:8089):

```bash
load/.venv/bin/locust -f load/demo.py --host https://snippet-searcher-bry.duckdns.org --autostart
load/.venv/bin/locust -f load/extended.py --host https://snippet-searcher-bry.duckdns.org --headless     --csv load/results/extended --html load/results/extended.html
```

On Windows, `powershell -ExecutionPolicy Bypass -File load\demo.ps1 [-Env prod]` runs the demo scenario and
opens the charts. Results go to `load/results/` (git-ignored).

Last extended run, dev, 2026-11-24 (`load/reports/2026-11-24-dev-extended.html`): 50,265 requests, 0
failures; 61 req/s at 80 users with p95 140 ms; p95 flat at 140 to 150 ms across every phase.

## Repository Structure

```text
.
├── .github/
│   └── workflows/
│       ├── CD-dev.yml
│       ├── CD-prod.yml
│       └── CI.yml
├── docs/
│   ├── azure-vm-setup.md
│   └── azure-vm.env.example
├── swarm/
│   ├── nginx/
│   │   ├── default.conf          (template: ${DOMAIN})
│   │   └── engine-proxy.conf
│   ├── synthetic/
│   │   └── check.sh
│   └── compose.yml
├── load/
│   ├── locustfile.py, demo.py, extended.py, demo.ps1, requirements.txt
│   └── reports/
├── observability/
│   ├── build_dashboard.py
│   ├── dashboard-dev.json
│   └── dashboard-prod.json
├── scripts/
│   ├── certbot-deploy-hook.sh
│   ├── certbot-init.sh
│   ├── create-secrets.sh
│   ├── deploy.sh
│   └── newrelic-alerts.sh
├── .gitattributes
├── .gitignore
└── README.md
```
