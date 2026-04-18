#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_PATH="${API_PATH:-/api/logins}"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy.env}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd jq
require_cmd curl
require_cmd python

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

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

echo "Tenant ID: $TENANT_ID"
echo "Client ID: $CLIENT_ID"
echo "Scope: $SCOPE"
echo "API URL: $API_URL"
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
