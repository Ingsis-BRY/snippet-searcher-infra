#!/usr/bin/env bash
# One-time (idempotent) setup of the overlay networks shared by every stack. They are external to the
# stacks on purpose: each stack can then be deployed, updated or removed on its own while the services
# keep reaching each other by their short names (redis, snippet-service, engine-proxy, ...).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=deploy-helpers.sh
source "$SCRIPT_DIR/deploy-helpers.sh"

require_swarm

if ! docker network inspect "$SNIPPET_NETWORK" >/dev/null 2>&1; then
    docker network create --driver overlay --attachable "$SNIPPET_NETWORK" >/dev/null
    echo "Created network $SNIPPET_NETWORK."
else
    echo "Network $SNIPPET_NETWORK already exists."
fi

# internal: the engine runs untrusted code and must have no outbound access.
if ! docker network inspect "$ENGINE_NETWORK" >/dev/null 2>&1; then
    docker network create --driver overlay --internal "$ENGINE_NETWORK" >/dev/null
    echo "Created network $ENGINE_NETWORK."
else
    echo "Network $ENGINE_NETWORK already exists."
fi
