#!/usr/bin/env bash
# Creates the application Docker secrets on the Swarm manager. Run once per VM.
# Values are read from the terminal (not echoed) and sent to Docker over stdin:
# they never touch a file, the command line or the shell history.

set -euo pipefail

SECRETS=(
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

for name in "${SECRETS[@]}"; do
    if docker secret inspect "$name" >/dev/null 2>&1; then
        echo "$name already exists, skipping (Docker secrets are immutable; see README to rotate)."
        continue
    fi
    read -r -s -p "Value for $name: " value
    echo
    # a value pasted from a browser or Windows can carry a trailing  or spaces: drop them
    value="${value//$''/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -z "$value" ]]; then
        echo "Error: empty value for $name." >&2
        exit 1
    fi
    printf '%s' "$value" | docker secret create "$name" - >/dev/null
    unset value
    echo "Created $name."
done
