#!/usr/bin/env bash

set -euo pipefail

STACK_NAME="snippet-searcher"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/../swarm/compose.yml"
NGINX_TEMPLATE_FILE="$SCRIPT_DIR/../swarm/nginx/default.conf"
NGINX_CONFIG_FILE="$SCRIPT_DIR/../swarm/nginx/default.rendered.conf"
ENGINE_PROXY_CONFIG_FILE="$SCRIPT_DIR/../swarm/nginx/engine-proxy.conf"
SYNTHETIC_SCRIPT_FILE="$SCRIPT_DIR/../swarm/synthetic/check.sh"
SYNTHETIC_EDGE_FILE="$SCRIPT_DIR/../swarm/synthetic/edge-check.mjs"
# How long to wait for every service to finish updating (or roll back) after the deploy. Updates go one task
# at a time with a 90 s monitor each, so a full deploy can take several minutes.
CONVERGE_TIMEOUT="${CONVERGE_TIMEOUT:-900}"

for var in SNIPPET_SERVICE_IMAGE PERMISSION_SERVICE_IMAGE PRINTSCRIPT_UI_IMAGE PRINTSCRIPT_ENGINE_IMAGE SYNTHETIC_CLIENT_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: $var is not set." >&2
        exit 1
    fi
done

REQUIRED_SECRETS=(
    service-postgres-password
    permission-postgres-password
    azure-storage-connection-string-v2
    auth0-m2m-client-secret
    new-relic-license-key
    synthetic-client-secret
)

if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q '^active$'; then
    echo "Error: Docker Swarm is not active on this node." >&2
    exit 1
fi

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
export DOMAIN   # the synthetic edge check calls https://$DOMAIN

NGINX_CONFIG_VERSION="$(sha256sum "$NGINX_CONFIG_FILE" | cut -c1-12)"
export NGINX_CONFIG_VERSION

SYNTHETIC_SCRIPT_VERSION="$(cat "$SYNTHETIC_SCRIPT_FILE" "$SYNTHETIC_EDGE_FILE" | sha256sum | cut -c1-12)"
export SYNTHETIC_SCRIPT_VERSION

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

# Swarm rolls a service back on its own when its new task fails the healthcheck (update_config
# failure_action: rollback). Wait until every service has settled and fail the deploy if any of
# them rolled back or is not running all its replicas.
echo "Waiting up to ${CONVERGE_TIMEOUT}s for the services to settle..."
deadline=$(( $(date +%s) + CONVERGE_TIMEOUT ))
while true; do
    pending=()
    rolled_back=()
    while read -r name; do
        state="$(docker service inspect "$name" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}')"
        case "$state" in
            rollback_*) rolled_back+=("$name ($state)") ;;
            updating) pending+=("$name (updating)") ;;
        esac
        desired="$(docker service inspect "$name" --format '{{if .Spec.Mode.Replicated}}{{.Spec.Mode.Replicated.Replicas}}{{end}}')"
        running="$(docker service ps "$name" --filter desired-state=running --format '{{.CurrentState}}' | grep -c '^Running' || true)"
        if [[ -n "$desired" && "$running" != "$desired" ]]; then
            pending+=("$name ($running/$desired running)")
        fi
    done < <(docker stack services "$STACK_NAME" --format '{{.Name}}')

    if [[ ${#rolled_back[@]} -gt 0 ]]; then
        echo "Error: these services failed their update and rolled back: ${rolled_back[*]}" >&2
        echo "See: docker service ps --no-trunc <service> and docker service logs <service>" >&2
        exit 1
    fi
    if [[ ${#pending[@]} -eq 0 ]]; then
        break
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
        echo "Error: services did not settle in ${CONVERGE_TIMEOUT}s: ${pending[*]}" >&2
        exit 1
    fi
    sleep 10
done

docker stack services "$STACK_NAME"
echo "Deployed to $DOMAIN. Follow the background worker with: docker service logs ${STACK_NAME}_snippet-worker"
