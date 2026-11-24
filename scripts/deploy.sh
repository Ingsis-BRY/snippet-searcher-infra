#!/usr/bin/env bash

set -euo pipefail

STACK_NAME="snippet-searcher"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/../swarm/compose.yml"
NGINX_CONFIG_FILE="$SCRIPT_DIR/../swarm/nginx/default.conf"
ENGINE_PROXY_CONFIG_FILE="$SCRIPT_DIR/../swarm/nginx/engine-proxy.conf"

for var in SNIPPET_SERVICE_IMAGE PERMISSION_SERVICE_IMAGE PRINTSCRIPT_UI_IMAGE PRINTSCRIPT_ENGINE_IMAGE; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: $var is not set." >&2
        exit 1
    fi
done

REQUIRED_SECRETS=(
    service-postgres-password
    permission-postgres-password
    azure-storage-connection-string
    auth0-m2m-client-secret
    new-relic-license-key
)

if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q '^active$'; then
    echo "Error: Docker Swarm is not active on this node." >&2
    exit 1
fi

NGINX_CONFIG_VERSION="$(sha256sum "$NGINX_CONFIG_FILE" | cut -c1-12)"
export NGINX_CONFIG_VERSION

ENGINE_PROXY_CONFIG_VERSION="$(sha256sum "$ENGINE_PROXY_CONFIG_FILE" | cut -c1-12)"
export ENGINE_PROXY_CONFIG_VERSION

missing=()
for secret in "${REQUIRED_SECRETS[@]}"; do
    if ! docker secret inspect "$secret" >/dev/null 2>&1; then
        missing+=("$secret")
    fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing Docker secrets: ${missing[*]}" >&2
    echo "Create them with scripts/create-secrets.sh." >&2
    exit 1
fi

# TLS: the certificate secrets already used by nginx are reused, so Certbot renewals are kept.
# Only the first deployment reads TLS_CERT_FILE / TLS_KEY_FILE (a self-signed certificate).
CURRENT_TLS_CERT="$(docker service inspect "${STACK_NAME}_nginx" \
    --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{println .SecretName}}{{end}}' 2>/dev/null \
    | grep -E '^tls-cert-' || true)"

if [[ -n "${TLS_CERT_FILE:-}" || -n "${TLS_KEY_FILE:-}" ]]; then
    for var in TLS_CERT_FILE TLS_KEY_FILE; do
        if [[ -z "${!var:-}" || ! -f "${!var}" ]]; then
            echo "Error: $var must point to an existing file." >&2
            exit 1
        fi
    done
    TLS_VERSION="$(cat "$TLS_CERT_FILE" "$TLS_KEY_FILE" | sha256sum | cut -c1-12)"
    for pair in "tls-cert-$TLS_VERSION:$TLS_CERT_FILE" "tls-key-$TLS_VERSION:$TLS_KEY_FILE"; do
        if ! docker secret inspect "${pair%%:*}" >/dev/null 2>&1; then
            docker secret create --label "com.docker.stack.namespace=$STACK_NAME" "${pair%%:*}" "${pair#*:}" >/dev/null
        fi
    done
elif [[ -n "$CURRENT_TLS_CERT" ]]; then
    TLS_VERSION="${CURRENT_TLS_CERT#tls-cert-}"
else
    echo "Error: first deployment: set TLS_CERT_FILE and TLS_KEY_FILE (see README, TLS)." >&2
    exit 1
fi
export TLS_VERSION

docker stack deploy \
    --with-registry-auth \
    -c "$COMPOSE_FILE" \
    "$STACK_NAME"

echo "Deployed. Follow the background worker with: docker service logs snippet-searcher_snippet-worker"
