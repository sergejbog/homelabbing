#!/bin/bash

# Pre-deploy script: Fetch secrets from Infisical and create .env file
# Usage: ./fetch-secrets-pre-deploy.sh [service-name]

set -e

SERVICE_NAME="${1:-komodo}"
ENVIRONMENT="prod"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_PATH="${SCRIPT_DIR}/../services/${SERVICE_NAME}"
ENV_FILE="${SERVICE_PATH}/.env"

echo "🔐 Fetching secrets from Infisical for ${SERVICE_NAME}..."

# Use infisical from the persistent shared mount (/etc/komodo/bin),
# which is available inside the periphery container via the volume mount.
# Falls back to system PATH if available.
INFISICAL_BIN="/etc/komodo/bin/infisical"
if [ ! -x "$INFISICAL_BIN" ]; then
    if command -v infisical &> /dev/null; then
        INFISICAL_BIN="infisical"
    else
        echo "❌ Infisical CLI not found at $INFISICAL_BIN or in PATH"
        echo "Install it on the host: cp \$(which infisical) /etc/komodo/bin/infisical"
        exit 1
    fi
fi
echo "Using infisical at: $INFISICAL_BIN"

# Load Infisical credentials from .env file
if [ -f "${SCRIPT_DIR}/.env" ]; then
    . "${SCRIPT_DIR}/.env"
    # Export variables for Infisical CLI
    export INFISICAL_API_URL
    export INFISICAL_CLIENT_ID
    export INFISICAL_CLIENT_SECRET
    export INFISICAL_PROJECT_ID
else
    echo "❌ Error: ${SCRIPT_DIR}/.env not found"
    echo "Please create it with INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET, and INFISICAL_API_URL"
    exit 1
fi

# Authenticate with Infisical using universal auth
echo "🔑 Authenticating with Infisical..."
export INFISICAL_TOKEN=$($INFISICAL_BIN login \
    --method=universal-auth \
    --client-id="${INFISICAL_CLIENT_ID}" \
    --client-secret="${INFISICAL_CLIENT_SECRET}" \
    --plain --silent)

if [ $? -ne 0 ]; then
    echo "❌ Failed to authenticate with Infisical"
    exit 1
fi
echo "✅ Authentication successful"

# Export secrets to .env file
# Root secrets (/) come first — shared vars like DOMAIN_NAME, LETSENCRYPT_EMAIL, etc.
# Service-specific secrets are appended after, so they override root values if keys overlap.
cd "${SERVICE_PATH}"

$INFISICAL_BIN export --env="${ENVIRONMENT}" \
    --projectId="${INFISICAL_PROJECT_ID}" \
    --path="/" \
    --format=dotenv > "${ENV_FILE}"

$INFISICAL_BIN export --env="${ENVIRONMENT}" \
    --projectId="${INFISICAL_PROJECT_ID}" \
    --path="/${SERVICE_NAME}" \
    --format=dotenv >> "${ENV_FILE}"

if [ $? -eq 0 ]; then
    echo "✅ Secrets fetched and saved to ${ENV_FILE}"
    echo "📝 Total secrets: $(grep -cE '^[^#].*=' "${ENV_FILE}" 2>/dev/null || echo 0)"
else
    echo "❌ Failed to fetch secrets"
    exit 1
fi
