#!/usr/bin/env bash

set -euo pipefail

STACK_NAME="snippet-searcher"
SERVICE_NAME="${STACK_NAME}_nginx"

if [[ -z "${RENEWED_LINEAGE:-}" ]]; then
    echo "Error: RENEWED_LINEAGE is not set." >&2
    exit 1
fi

CERT_FILE="$RENEWED_LINEAGE/fullchain.pem"
KEY_FILE="$RENEWED_LINEAGE/privkey.pem"

for file in "$CERT_FILE" "$KEY_FILE"; do
    if [[ ! -f "$file" ]]; then
        echo "Error: $file does not exist." >&2
        exit 1
    fi
done

if ! docker service inspect "$SERVICE_NAME" >/dev/null 2>&1; then
    echo "Error: service $SERVICE_NAME does not exist." >&2
    exit 1
fi

TLS_VERSION="$(cat "$CERT_FILE" "$KEY_FILE" | sha256sum | cut -c1-12)"
NEW_CERT_SECRET="tls-cert-$TLS_VERSION"
NEW_KEY_SECRET="tls-key-$TLS_VERSION"

mapfile -t CURRENT_SECRETS < <(
    docker service inspect "$SERVICE_NAME" \
        --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{println .SecretName}}{{end}}' \
        | grep -E '^tls-(cert|key)-' || true
)

if [[ " ${CURRENT_SECRETS[*]} " == *" $NEW_CERT_SECRET "* && " ${CURRENT_SECRETS[*]} " == *" $NEW_KEY_SECRET "* ]]; then
    echo "$SERVICE_NAME already uses TLS version $TLS_VERSION."
    exit 0
fi

create_secret() {
    if ! docker secret inspect "$1" >/dev/null 2>&1; then
        docker secret create --label "com.docker.stack.namespace=$STACK_NAME" "$1" "$2" >/dev/null
    fi
}

create_secret "$NEW_CERT_SECRET" "$CERT_FILE"
create_secret "$NEW_KEY_SECRET" "$KEY_FILE"

UPDATE_ARGS=()
for secret in "${CURRENT_SECRETS[@]}"; do
    UPDATE_ARGS+=(--secret-rm "$secret")
done
UPDATE_ARGS+=(
    --secret-add "source=$NEW_CERT_SECRET,target=tls_cert"
    --secret-add "source=$NEW_KEY_SECRET,target=tls_key,mode=0400"
)

docker service update --quiet "${UPDATE_ARGS[@]}" "$SERVICE_NAME" >/dev/null

for secret in "${CURRENT_SECRETS[@]}"; do
    docker secret rm "$secret" >/dev/null 2>&1 || true
done

echo "$SERVICE_NAME updated to TLS version $TLS_VERSION."
