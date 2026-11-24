#!/bin/bash

# Pre-deploy script: fetch a service's secrets from Infisical into .env
# Usage: ./fetch-secrets-pre-deploy.sh <service-name> [target-dir]
#   target-dir: where to write .env (default: services/<service-name> in this repo).
#   For stacks whose compose file lives in another repo, e.g. axiom-data.
#
# Runs inside Komodo Periphery on the Pi as a stack's pre_deploy command.
# The credentials never come from the repo checkout: they are in a root-only
# file that is placed by hand on the Pi, outside every checkout:
#
#   /etc/komodo/secrets/infisical.env  (root, 0600)
#     INFISICAL_API_URL=http://infisical-backend:8080/api
#     INFISICAL_PROJECT_ID=<Homelab project id>
#     INFISICAL_CLIENT_ID=<pi-komodo client id>
#     INFISICAL_CLIENT_SECRET=<pi-komodo client secret>
#
# The pi-komodo machine identity can only read the Homelab project's prod
# environment, and only over the internal infisical_api network: Traefik
# answers 403 on its login path. Root secrets (/) are written first, then
# /<service-name>, so service values win when a key is in both. Prints key
# counts only, never values.

set -euo pipefail

SERVICE_NAME="${1:?usage: $0 <service-name> [target-dir]}"
ENVIRONMENT="prod"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_PATH="${2:-${SCRIPT_DIR}/../services/${SERVICE_NAME}}"
ENV_FILE="${SERVICE_PATH}/.env"
CREDS="${INFISICAL_CREDENTIALS_FILE:-/etc/komodo/secrets/infisical.env}"
INFISICAL_BIN="${INFISICAL_BIN:-/etc/komodo/bin/infisical}"

# The name becomes an Infisical folder path: no slashes, dots or spaces.
case "$SERVICE_NAME" in
    *[!a-z0-9_-]*)
        echo "❌ Bad service name: ${SERVICE_NAME}"
        exit 1
        ;;
esac

echo "🔐 Fetching secrets from Infisical for ${SERVICE_NAME}..."

if [ ! -x "$INFISICAL_BIN" ]; then
    echo "❌ Infisical CLI not found at $INFISICAL_BIN"
    exit 1
fi

if [ ! -f "$CREDS" ]; then
    echo "❌ ${CREDS} not found"
    exit 1
fi
perm="$(stat -c '%u %a' "$CREDS")"
if [ "$perm" != "0 600" ]; then
    echo "❌ ${CREDS} must be owned by root with mode 0600 (it is: uid/mode ${perm})"
    exit 1
fi

# Read the keys without sourcing the file as shell code.
cred() {
    local v
    v="$(sed -n "s/^$1=//p" "$CREDS" | tail -n 1 | tr -d '\r')"
    if [ -z "$v" ]; then
        echo "❌ $1 missing in ${CREDS}" >&2
        return 1
    fi
    printf '%s' "$v"
}
INFISICAL_API_URL="$(cred INFISICAL_API_URL)"
INFISICAL_PROJECT_ID="$(cred INFISICAL_PROJECT_ID)"
INFISICAL_UNIVERSAL_AUTH_CLIENT_ID="$(cred INFISICAL_CLIENT_ID)"
INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET="$(cred INFISICAL_CLIENT_SECRET)"
# The CLI reads the client id and secret from the environment, so they never
# appear in a process list.
export INFISICAL_API_URL INFISICAL_UNIVERSAL_AUTH_CLIENT_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
export INFISICAL_DISABLE_UPDATE_CHECK=true INFISICAL_DISABLE_TELEMETRY=true

echo "🔑 Authenticating with Infisical..."
if ! INFISICAL_TOKEN="$("$INFISICAL_BIN" login --method=universal-auth --plain --silent)" \
    || [ -z "$INFISICAL_TOKEN" ]; then
    echo "❌ Failed to authenticate with Infisical"
    exit 1
fi
unset INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
export INFISICAL_TOKEN
echo "✅ Authentication successful"

# Write to a private temp file next to the target, then move it into place,
# so a failed export never leaves a half-written .env behind.
umask 077
tmp="$(mktemp "${SERVICE_PATH}/.env.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

"$INFISICAL_BIN" export --env="${ENVIRONMENT}" \
    --projectId="${INFISICAL_PROJECT_ID}" \
    --path="/" \
    --format=dotenv > "$tmp"

"$INFISICAL_BIN" export --env="${ENVIRONMENT}" \
    --projectId="${INFISICAL_PROJECT_ID}" \
    --path="/${SERVICE_NAME}" \
    --format=dotenv >> "$tmp"

mv -f "$tmp" "$ENV_FILE"
trap - EXIT

echo "✅ Secrets fetched and saved to ${ENV_FILE}"
echo "📝 Total secrets: $(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" || true)"
