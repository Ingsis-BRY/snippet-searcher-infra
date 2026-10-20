# Snippet Searcher Infrastructure

Infrastructure repository for deploying Snippet Searcher microservices
using Docker Swarm on Azure Virtual Machines.

## Architecture

The infrastructure consists of:

- Azure Virtual Machines running Ubuntu Server.
- Docker Engine installed on each virtual machine.
- Docker Swarm for container orchestration.
- GitHub Container Registry (GHCR) for Docker images.
- GitHub Actions for continuous deployment.

## Environments

- `dev`: development and integration environment.
- `prod`: production environment.

Changes are integrated into `dev` through pull requests.
Validated changes are promoted from `dev` to `prod` through pull requests.

## Repository Structure

- `swarm/`: Docker Swarm stack configuration.
- `scripts/`: deployment and infrastructure scripts.
- `docs/`: architecture and infrastructure documentation.
- `.github/workflows/`: CI/CD workflows.

## Deployment

Deployment instructions will be documented once the Azure
Virtual Machines and Docker Swarm cluster are configured.