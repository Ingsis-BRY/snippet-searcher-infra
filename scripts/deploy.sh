#!/usr/bin/env bash
# Deploys ONE stack: scripts/deploy.sh <infra|service|permission|engine|ui>
#
# Each stack is deployed, converged and rolled back on its own, so publishing a new image of one
# microservice only touches that microservice. See README (Continuous Deployment).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy-helpers.sh
source "$SCRIPT_DIR/deploy-helpers.sh"

STACKS_DIR="$SCRIPT_DIR/../swarm/stacks"
# How long to wait for every service to finish updating (or roll back) after the deploy. Updates go one task
# at a time with a 90 s monitor each, so a full deploy can take several minutes.
CONVERGE_TIMEOUT="${CONVERGE_TIMEOUT:-900}"

usage() {
    echo "Usage: $0 <infra|service|permission|engine|ui>" >&2
    exit 1
}

[[ $# -eq 1 ]] || usage

# The shared stack keeps the historical name `snippet-searcher`: its data volumes are named after it.
case "$1" in
    infra) STACK_NAME="snippet-searcher" ;;
    service) STACK_NAME="snippet-service" ;;
    permission) STACK_NAME="snippet-permission" ;;
    engine) STACK_NAME="snippet-engine" ;;
    ui) STACK_NAME="snippet-ui" ;;
    *) usage ;;
esac
COMPOSE_FILE="$STACKS_DIR/$1.yml"

# Two stacks may be deployed at the same time by different pipelines; on a small VM they take turns.
mkdir -p /var/lock
exec 9>/var/lock/snippet-swarm-deploy.lock
if ! flock -n 9; then
    echo "Another deployment is running on this VM, waiting for it to finish..."
    flock 9
fi

require_swarm

case "$1" in
    infra)
        NGINX_TEMPLATE_FILE="$SCRIPT_DIR/../swarm/nginx/default.conf"
        NGINX_CONFIG_FILE="$SCRIPT_DIR/../swarm/nginx/default.rendered.conf"
        SYNTHETIC_SCRIPT_FILE="$SCRIPT_DIR/../swarm/synthetic/check.sh"

        if [[ -z "${SYNTHETIC_CLIENT_ID:-}" ]]; then
            echo "Error: SYNTHETIC_CLIENT_ID is not set." >&2
            exit 1
        fi
        require_networks "$SNIPPET_NETWORK"
        require_secrets service-postgres-password permission-postgres-password new-relic-license-key synthetic-client-secret

        # Each environment has its own DuckDNS subdomain (and certificate). nginx's own $variables are left alone:
        # only the literal ${DOMAIN} placeholder is replaced.
        if [[ -z "${DOMAIN:-}" ]]; then
            DOMAIN="snippet-searcher-bry.duckdns.org"
            echo "Warning: DOMAIN is not set, using $DOMAIN. Set the DOMAIN variable of this GitHub environment." >&2
        fi
        if [[ ! "$DOMAIN" =~ ^[a-z0-9.-]+$ ]]; then
            echo "Error: DOMAIN must be a plain host name, got '$DOMAIN'." >&2
            exit 1
        fi
        sed "s/\${DOMAIN}/$DOMAIN/g" "$NGINX_TEMPLATE_FILE" > "$NGINX_CONFIG_FILE"

        NGINX_CONFIG_VERSION="$(sha256sum "$NGINX_CONFIG_FILE" | cut -c1-12)"
        export NGINX_CONFIG_VERSION
        SYNTHETIC_SCRIPT_VERSION="$(sha256sum "$SYNTHETIC_SCRIPT_FILE" | cut -c1-12)"
        export SYNTHETIC_SCRIPT_VERSION

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
        ;;

    service)
        require_networks "$SNIPPET_NETWORK"
        require_secrets service-postgres-password azure-storage-connection-string-v2 auth0-m2m-client-secret new-relic-license-key
        resolve_image SNIPPET_SERVICE_IMAGE "${STACK_NAME}_snippet-service"
        ;;

    permission)
        require_networks "$SNIPPET_NETWORK"
        require_secrets permission-postgres-password new-relic-license-key
        resolve_image PERMISSION_SERVICE_IMAGE "${STACK_NAME}_snippet-permission-service"
        ;;

    engine)
        require_networks "$SNIPPET_NETWORK" "$ENGINE_NETWORK"
        ENGINE_PROXY_CONFIG_VERSION="$(sha256sum "$SCRIPT_DIR/../swarm/nginx/engine-proxy.conf" | cut -c1-12)"
        export ENGINE_PROXY_CONFIG_VERSION
        resolve_image PRINTSCRIPT_ENGINE_IMAGE "${STACK_NAME}_printscript-engine"
        ;;

    ui)
        require_networks "$SNIPPET_NETWORK"
        resolve_image PRINTSCRIPT_UI_IMAGE "${STACK_NAME}_printscript-ui"
        ;;
esac

docker stack deploy \
    --with-registry-auth \
    -c "$COMPOSE_FILE" \
    "$STACK_NAME"

wait_for_stack "$STACK_NAME" "$CONVERGE_TIMEOUT"

docker stack services "$STACK_NAME"
echo "Stack $STACK_NAME deployed."
