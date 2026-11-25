#!/usr/bin/env bash
# Helpers shared by deploy.sh and create-networks.sh. Sourced, never executed.

# Networks shared by every stack. Created once by scripts/create-networks.sh.
SNIPPET_NETWORK="snippet-network"
ENGINE_NETWORK="engine-network"

require_swarm() {
    if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q '^active$'; then
        echo "Error: Docker Swarm is not active on this node." >&2
        exit 1
    fi
}

# require_secrets <secret>...: fail with the full list of Docker secrets that do not exist yet.
require_secrets() {
    local missing=() secret
    for secret in "$@"; do
        if ! docker secret inspect "$secret" >/dev/null 2>&1; then
            missing+=("$secret")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: missing Docker secrets: ${missing[*]}" >&2
        echo "Create them with scripts/create-secrets.sh." >&2
        exit 1
    fi
}

# require_networks <network>...: the external networks must exist before any stack that uses them.
require_networks() {
    local missing=() network
    for network in "$@"; do
        if ! docker network inspect "$network" >/dev/null 2>&1; then
            missing+=("$network")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: missing Docker networks: ${missing[*]}" >&2
        echo "Create them once with scripts/create-networks.sh." >&2
        exit 1
    fi
}

# resolve_image <ENV_VAR> <running-service-name>
# Picks the image a stack is deployed with, so that redeploying a stack (for example because its compose
# file changed) never rolls the service back to a stale tag:
#   1. DEPLOY_IMAGE, the tag the service's own pipeline asked for;
#   2. the variable itself, only when USE_CONFIGURED_IMAGES=true (prod: the image variables of the GitHub
#      environment are what gets promoted);
#   3. the image the service is running right now;
#   4. the variable itself, for the very first deployment (GitHub environment variable).
resolve_image() {
    local var="$1" service="$2" running=""
    if [[ -n "${DEPLOY_IMAGE:-}" ]]; then
        printf -v "$var" '%s' "$DEPLOY_IMAGE"
        echo "$var: using the requested image ${!var}"
    elif [[ "${USE_CONFIGURED_IMAGES:-}" == "true" && -n "${!var:-}" ]]; then
        echo "$var: using the configured image ${!var}"
    else
        running="$(docker service inspect "$service" \
            --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || true)"
        if [[ -n "$running" ]]; then
            printf -v "$var" '%s' "$running"
            echo "$var: keeping the running image ${!var}"
        elif [[ -n "${!var:-}" ]]; then
            echo "$var: first deployment, using ${!var}"
        else
            echo "Error: $var is not set and $service is not running: pass the image to deploy." >&2
            exit 1
        fi
    fi
    export "${var?}"
}

# wait_for_stack <stack> <timeout-seconds>
# Swarm rolls a service back on its own when its new task fails the healthcheck (update_config
# failure_action: rollback). Wait until every service of the stack has settled and fail the deploy if
# any of them rolled back or is not running all its replicas.
wait_for_stack() {
    local stack="$1" timeout="$2" deadline name state desired running
    local pending rolled_back
    echo "Waiting up to ${timeout}s for the services of $stack to settle..."
    deadline=$(( $(date +%s) + timeout ))
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
        done < <(docker stack services "$stack" --format '{{.Name}}')

        if [[ ${#rolled_back[@]} -gt 0 ]]; then
            echo "Error: these services failed their update and rolled back: ${rolled_back[*]}" >&2
            echo "See: docker service ps --no-trunc <service> and docker service logs <service>" >&2
            return 1
        fi
        if [[ ${#pending[@]} -eq 0 ]]; then
            return 0
        fi
        if [[ $(date +%s) -ge $deadline ]]; then
            echo "Error: services did not settle in ${timeout}s: ${pending[*]}" >&2
            return 1
        fi
        sleep 10
    done
}
