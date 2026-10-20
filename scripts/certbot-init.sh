#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBROOT="/var/www/certbot"
HOOK_TARGET="/etc/letsencrypt/renewal-hooks/deploy/snippet-searcher.sh"

for var in DOMAIN CERTBOT_EMAIL; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: $var is not set." >&2
        exit 1
    fi
done

if [[ "$EUID" -ne 0 ]]; then
    echo "Error: this script must be run as root." >&2
    exit 1
fi

if ! command -v certbot >/dev/null 2>&1; then
    echo "Error: certbot is not installed." >&2
    exit 1
fi

CERTBOT_ARGS=(
    certonly
    --webroot
    -w "$WEBROOT"
    -d "$DOMAIN"
    --cert-name "$DOMAIN"
    --email "$CERTBOT_EMAIL"
    --agree-tos
    --non-interactive
    --keep-until-expiring
)

if [[ "${CERTBOT_STAGING:-0}" == "1" ]]; then
    CERTBOT_ARGS+=(--staging)
fi

mkdir -p "$WEBROOT"
certbot "${CERTBOT_ARGS[@]}"

install -D -m 0755 "$SCRIPT_DIR/certbot-deploy-hook.sh" "$HOOK_TARGET"
RENEWED_LINEAGE="/etc/letsencrypt/live/$DOMAIN" "$HOOK_TARGET"

certbot renew --dry-run --cert-name "$DOMAIN"
