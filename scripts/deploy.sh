#!/usr/bin/env bash

set -euo pipefail

STACK_NAME="snippet-searcher"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/../swarm/compose.yml"

if [[ -z "${SNIPPET_SERVICE_IMAGE:-}" ]]; then
    echo "Error: SNIPPET_SERVICE_IMAGE is not set." >&2
    exit 1
fi

if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q '^active$'; then
    echo "Error: Docker Swarm is not active on this node." >&2
    exit 1
fi

docker stack deploy \
    --with-registry-auth \
    -c "$COMPOSE_FILE" \
    "$STACK_NAME"