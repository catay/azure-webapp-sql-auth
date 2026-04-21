#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
API_PATH="${API_PATH:-/api/logins}"
HEALTH_PATH="${HEALTH_PATH:-/healthz}"
HEALTH_MAX_ATTEMPTS="${HEALTH_MAX_ATTEMPTS:-20}"
HEALTH_RETRY_SECONDS="${HEALTH_RETRY_SECONDS:-15}"
HEALTH_CONNECT_TIMEOUT_SECONDS="${HEALTH_CONNECT_TIMEOUT_SECONDS:-10}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-30}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/test_daemon_api.sh <env-file>
  ENV_FILE=./infra/terraform/environments/dev/dev.env ./scripts/test_daemon_api.sh

Required environment variables:
  ENV_FILE
  TENANT_ID
  CLIENT_ID
  SCOPE
  TOKEN_URL
  API_URL

ENV_FILE must point to a non-empty file. You can pass it as the first argument
or by setting the ENV_FILE environment variable.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  echo "Unexpected arguments." >&2
  usage >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  ENV_FILE="$1"
elif [[ -n "${ENV_FILE:-}" ]]; then
  ENV_FILE="${ENV_FILE}"
else
  echo "Missing required ENV_FILE." >&2
  usage >&2
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

resolve_health_url() {
  if [[ -n "${HEALTH_URL:-}" ]]; then
    printf '%s\n' "${HEALTH_URL}"
    return 0
  fi

  if [[ "${API_URL}" == *"${API_PATH}" ]]; then
    printf '%s%s\n' "${API_URL%"${API_PATH}"}" "${HEALTH_PATH}"
    return 0
  fi

  echo "Unable to derive HEALTH_URL from API_URL=${API_URL}." >&2
  echo "Set HEALTH_URL explicitly or adjust API_PATH/HEALTH_PATH." >&2
  exit 1
}

wait_for_health() {
  local attempt curl_exit http_code status

  for ((attempt = 1; attempt <= HEALTH_MAX_ATTEMPTS; attempt += 1)); do
    curl_exit=0
    http_code="$(
      curl -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout "${HEALTH_CONNECT_TIMEOUT_SECONDS}" \
        --max-time "${HEALTH_TIMEOUT_SECONDS}" \
        "${HEALTH_URL}"
    )" || curl_exit=$?

    if [[ ${curl_exit} -eq 0 && "${http_code}" == "200" ]]; then
      echo "Health check passed."
      return 0
    fi

    if [[ ${curl_exit} -ne 0 ]]; then
      status="curl exit ${curl_exit}"
    else
      status="HTTP ${http_code}"
    fi

    if [[ ${attempt} -eq ${HEALTH_MAX_ATTEMPTS} ]]; then
      echo "Health check failed after ${HEALTH_MAX_ATTEMPTS} attempts (${status})." >&2
      return 1
    fi

    echo "Health check attempt ${attempt}/${HEALTH_MAX_ATTEMPTS} returned ${status}; retrying in ${HEALTH_RETRY_SECONDS}s..."
    sleep "${HEALTH_RETRY_SECONDS}"
  done
}

require_cmd jq
require_cmd curl
require_cmd python

if [[ ! -f "${ENV_FILE}" || ! -s "${ENV_FILE}" ]]; then
  echo "ENV_FILE must exist and be non-empty: ${ENV_FILE}" >&2
  usage >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

CLIENT_ID="${CLIENT_ID:-}"
CLIENT_SECRET="${CLIENT_SECRET:-}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-}"
DAEMON_CLIENT_SECRET_NAME="${DAEMON_CLIENT_SECRET_NAME:-}"

if [[ -z "${CLIENT_SECRET}" || "${CLIENT_SECRET}" == "null" ]] && [[ -n "${KEY_VAULT_NAME}" && -n "${DAEMON_CLIENT_SECRET_NAME}" ]]; then
  require_cmd az
  CLIENT_SECRET="$(az keyvault secret show \
    --vault-name "${KEY_VAULT_NAME}" \
    --name "${DAEMON_CLIENT_SECRET_NAME}" \
    --query value -o tsv)"
fi

if [ -z "${CLIENT_ID}" ] || [ -z "${CLIENT_SECRET}" ] || [ "${CLIENT_ID}" = "null" ] || [ "${CLIENT_SECRET}" = "null" ]; then
  echo "Daemon client environment variables are not available." >&2
  echo "Set CLIENT_ID and either CLIENT_SECRET or KEY_VAULT_NAME plus DAEMON_CLIENT_SECRET_NAME." >&2
  exit 1
fi

HEALTH_URL="$(resolve_health_url)"

echo "Tenant ID: $TENANT_ID"
echo "Client ID: $CLIENT_ID"
echo "Scope: $SCOPE"
echo "API URL: $API_URL"
echo "Health URL: $HEALTH_URL"
echo
echo "Waiting for health endpoint..."
wait_for_health
echo
echo "Requesting access token..."

TOKEN_RESPONSE="$(curl -sS -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode "scope=$SCOPE" \
  --data-urlencode "grant_type=client_credentials")"

ACCESS_TOKEN="$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.access_token // empty')"

if [ -z "$ACCESS_TOKEN" ]; then
  echo "Token request failed:" >&2
  printf '%s\n' "$TOKEN_RESPONSE" | jq . >&2 || printf '%s\n' "$TOKEN_RESPONSE" >&2
  exit 1
fi

echo "Access token acquired."
echo
echo "Decoded token payload:"

python - <<'PY' "$ACCESS_TOKEN"
import base64
import json
import sys

token = sys.argv[1]
payload = token.split(".")[1]
payload += "=" * (-len(payload) % 4)
decoded = json.loads(base64.urlsafe_b64decode(payload))
print(json.dumps(decoded, indent=2, sort_keys=True))
PY

echo
echo "Calling API..."
curl -sS \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Accept: application/json" \
  "$API_URL" | jq
echo
