#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy.env}"
AZURE_CONFIG_DIR="${AZURE_CONFIG_DIR:-}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/deploy_app_only.sh
  ENV_FILE=./scripts/deploy.env ./scripts/deploy_app_only.sh

Required environment variables:
  RG
  WEBAPP_NAME

Optional environment variables:
  PACKAGE_PATH     default: /tmp/${WEBAPP_NAME}.zip
  AZURE_CONFIG_DIR default: use the current Azure CLI profile
  SKIP_BROWSE      default: false

This script only creates the ZIP deployment package and deploys it to an
existing Azure App Service web app. It does not provision or reconfigure Azure
resources, authentication, identities, or database settings.

If ENV_FILE exists, the script loads it automatically and exports the variables
defined there before validating the required configuration.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command not found: ${command_name}" >&2
    exit 1
  fi
}

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

require_command az
require_command zip

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

if [[ -n "${AZURE_CONFIG_DIR}" ]]; then
  mkdir -p "${AZURE_CONFIG_DIR}"
  export AZURE_CONFIG_DIR
fi

require_env RG
require_env WEBAPP_NAME

PACKAGE_PATH="${PACKAGE_PATH:-/tmp/${WEBAPP_NAME}.zip}"
SKIP_BROWSE="${SKIP_BROWSE:-false}"

log "Checking Azure CLI authentication context"
if ! az account show --only-show-errors >/dev/null 2>&1; then
  echo "Azure CLI is not authenticated in the active profile." >&2
  echo "Run 'az login' or set AZURE_CONFIG_DIR to the profile that contains your login." >&2
  exit 1
fi

log "Checking that the target web app exists"
az webapp show \
  --resource-group "${RG}" \
  --name "${WEBAPP_NAME}" \
  --only-show-errors >/dev/null

log "Building ZIP deployment package at ${PACKAGE_PATH}"
rm -f "${PACKAGE_PATH}"
(
  cd "${REPO_ROOT}"
  zip -r "${PACKAGE_PATH}" app.py requirements.txt templates >/dev/null
)

log "Deploying application package"
az webapp deploy \
  --resource-group "${RG}" \
  --name "${WEBAPP_NAME}" \
  --src-path "${PACKAGE_PATH}" \
  --type zip \
  --only-show-errors

cat <<EOF

App deployment completed.

Web app name: ${WEBAPP_NAME}
Web app URL: https://${WEBAPP_NAME}.azurewebsites.net
Package path: ${PACKAGE_PATH}
EOF

if [[ "${SKIP_BROWSE}" != "true" ]]; then
  log "Opening the deployed site in the browser"
  az webapp browse \
    --resource-group "${RG}" \
    --name "${WEBAPP_NAME}"
fi
