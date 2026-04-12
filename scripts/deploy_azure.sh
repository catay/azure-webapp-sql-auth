#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy.env}"
AZURE_CONFIG_DIR="${AZURE_CONFIG_DIR:-/tmp/.azure-${USER:-codex}}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/deploy_azure.sh
  ENV_FILE=./scripts/deploy.env ./scripts/deploy_azure.sh

Required environment variables:
  RG
  LOCATION
  APP_PLAN
  WEBAPP_NAME
  SQL_SERVER_NAME
  SQL_DB_NAME
  SQL_AAD_ADMIN_NAME
  SQL_AAD_ADMIN_OBJECT_ID

Optional environment variables:
  SQL_AAD_ADMIN_PRINCIPAL_TYPE         default: User
  APP_PLAN_SKU                         default: F1
  SQL_DB_EDITION                       default: GeneralPurpose
  SQL_DB_FAMILY                        default: Gen5
  SQL_DB_CAPACITY                      default: 2
  SQL_DB_COMPUTE_MODEL                 default: Serverless
  SQL_DB_AUTO_PAUSE_DELAY              default: 60
  SQL_DB_BACKUP_REDUNDANCY             default: Local
  SQL_DB_FREE_LIMIT_EXHAUSTION_BEHAVIOR default: AutoPause
  RUNTIME                              default: PYTHON|3.12
  AAD_APP_NAME                         default: app-${WEBAPP_NAME}
  AAD_APP_CLIENT_ID                    default: resolved from display name or created
  AAD_APP_OBJECT_ID                    default: resolved from client ID or display name
  AAD_APP_CLIENT_SECRET                default: rotated/generated during script run
  FLASK_SECRET_KEY                     default: generated for this run
  PACKAGE_PATH                         default: /tmp/${WEBAPP_NAME}.zip
  AZURE_CONFIG_DIR                     default: /tmp/.azure-${USER}
  SKIP_ZIP_DEPLOY                      default: false
  SKIP_BROWSE                          default: false

This script provisions the Azure resources, configures Easy Auth, creates a ZIP
deployment package, and deploys the Flask app. Creating the database user for the
web app managed identity still requires running the SQL shown at the end of the script
while connected as the configured Microsoft Entra admin.

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

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "${value}"
}

looks_like_guid() {
  local value="$1"
  [[ "${value}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

ensure_web_redirect_uri() {
  local app_object_id="$1"
  local redirect_uri="$2"
  local redirect_uris_json="["
  local seen=false
  local uri
  local existing_redirect_uris=()
  local graph_application_uri="https://graph.microsoft.com/v1.0/applications/${app_object_id}"

  while IFS= read -r uri; do
    [[ -z "${uri}" ]] && continue
    existing_redirect_uris+=("${uri}")
    if [[ "${uri}" == "${redirect_uri}" ]]; then
      seen=true
    fi
  done < <(
    az rest \
      --method GET \
      --uri "${graph_application_uri}?\$select=web" \
      --query "web.redirectUris[]" -o tsv 2>/dev/null || true
  )

  if [[ "${seen}" == "false" ]]; then
    existing_redirect_uris+=("${redirect_uri}")
  fi

  for uri in "${existing_redirect_uris[@]}"; do
    redirect_uris_json+="\"$(json_escape "${uri}")\","
  done

  if [[ "${redirect_uris_json}" == *"," ]]; then
    redirect_uris_json="${redirect_uris_json%,}"
  fi
  redirect_uris_json+="]"

  az rest \
    --method PATCH \
    --uri "${graph_application_uri}" \
    --headers "Content-Type=application/json" \
    --body "{\"web\":{\"redirectUris\":${redirect_uris_json}}}" >/dev/null
}

resolve_app_object_id() {
  local app_client_id="$1"

  az ad app list \
    --all \
    --query "[?appId=='${app_client_id}'][0].id" -o tsv
}

resolve_app_client_id() {
  local app_object_id="$1"

  az rest \
    --method GET \
    --uri "https://graph.microsoft.com/v1.0/applications/${app_object_id}?\$select=appId" \
    --query "appId" -o tsv
}

app_object_exists() {
  local app_object_id="$1"

  az rest \
    --method GET \
    --uri "https://graph.microsoft.com/v1.0/applications/${app_object_id}?\$select=id" \
    --only-show-errors >/dev/null 2>&1
}

resolve_app_object_id_by_display_name() {
  local app_name="$1"
  az rest \
    --method GET \
    --uri "https://graph.microsoft.com/v1.0/applications?\$select=id,appId,displayName" \
    --query "value[?displayName=='${app_name}'] | [0].id" -o tsv
}

resolve_app_client_id_by_display_name() {
  local app_name="$1"
  az rest \
    --method GET \
    --uri "https://graph.microsoft.com/v1.0/applications?\$select=id,appId,displayName" \
    --query "value[?displayName=='${app_name}'] | [0].appId" -o tsv
}

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command not found: ${command_name}" >&2
    exit 1
  fi
}

require_command az
require_command zip
require_command openssl

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

mkdir -p "${AZURE_CONFIG_DIR}"
export AZURE_CONFIG_DIR

require_env RG
require_env LOCATION
require_env APP_PLAN
require_env WEBAPP_NAME
require_env SQL_SERVER_NAME
require_env SQL_DB_NAME
require_env SQL_AAD_ADMIN_NAME
require_env SQL_AAD_ADMIN_OBJECT_ID

SQL_AAD_ADMIN_PRINCIPAL_TYPE="${SQL_AAD_ADMIN_PRINCIPAL_TYPE:-User}"
APP_PLAN_SKU="${APP_PLAN_SKU:-F1}"
SQL_DB_EDITION="${SQL_DB_EDITION:-GeneralPurpose}"
SQL_DB_FAMILY="${SQL_DB_FAMILY:-Gen5}"
SQL_DB_CAPACITY="${SQL_DB_CAPACITY:-2}"
SQL_DB_COMPUTE_MODEL="${SQL_DB_COMPUTE_MODEL:-Serverless}"
SQL_DB_AUTO_PAUSE_DELAY="${SQL_DB_AUTO_PAUSE_DELAY:-60}"
SQL_DB_BACKUP_REDUNDANCY="${SQL_DB_BACKUP_REDUNDANCY:-Local}"
SQL_DB_FREE_LIMIT_EXHAUSTION_BEHAVIOR="${SQL_DB_FREE_LIMIT_EXHAUSTION_BEHAVIOR:-AutoPause}"
RUNTIME="${RUNTIME:-PYTHON|3.12}"
TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
AAD_APP_NAME="${AAD_APP_NAME:-app-${WEBAPP_NAME}}"
AAD_APP_REDIRECT_URI="${AAD_APP_REDIRECT_URI:-https://${WEBAPP_NAME}.azurewebsites.net/.auth/login/aad/callback}"
AAD_APP_CLIENT_ID="${AAD_APP_CLIENT_ID:-}"
AAD_APP_OBJECT_ID="${AAD_APP_OBJECT_ID:-}"
AAD_APP_CLIENT_SECRET="${AAD_APP_CLIENT_SECRET:-}"
FLASK_SECRET_KEY="${FLASK_SECRET_KEY:-}"
PACKAGE_PATH="${PACKAGE_PATH:-/tmp/${WEBAPP_NAME}.zip}"
SKIP_ZIP_DEPLOY="${SKIP_ZIP_DEPLOY:-false}"
SKIP_BROWSE="${SKIP_BROWSE:-false}"

log "Ensuring Azure CLI authV2 extension is available"
az extension add --name authV2 --upgrade --only-show-errors >/dev/null 2>&1 || true

log "Ensuring resource group exists"
az group create \
  --name "${RG}" \
  --location "${LOCATION}" \
  --only-show-errors >/dev/null

if az appservice plan show --name "${APP_PLAN}" --resource-group "${RG}" >/dev/null 2>&1; then
  log "App Service plan already exists; reusing ${APP_PLAN}"
else
  log "Creating App Service plan"
  az appservice plan create \
    --name "${APP_PLAN}" \
    --resource-group "${RG}" \
    --location "${LOCATION}" \
    --is-linux \
    --sku "${APP_PLAN_SKU}"
fi

if az webapp show --resource-group "${RG}" --name "${WEBAPP_NAME}" >/dev/null 2>&1; then
  log "Web app already exists; reusing ${WEBAPP_NAME}"
else
  log "Creating Linux web app"
  az webapp create \
    --resource-group "${RG}" \
    --plan "${APP_PLAN}" \
    --name "${WEBAPP_NAME}" \
    --runtime "${RUNTIME}"
fi

log "Enabling system-assigned managed identity on the web app"
WEBAPP_MI_PRINCIPAL_ID="$(az webapp identity assign \
  --resource-group "${RG}" \
  --name "${WEBAPP_NAME}" \
  --query principalId -o tsv)"

if az sql server show --name "${SQL_SERVER_NAME}" --resource-group "${RG}" >/dev/null 2>&1; then
  log "Azure SQL logical server already exists; reusing ${SQL_SERVER_NAME}"
else
  log "Creating Azure SQL logical server with Entra-only authentication"
  az sql server create \
    --name "${SQL_SERVER_NAME}" \
    --resource-group "${RG}" \
    --location "${LOCATION}" \
    --external-admin-name "${SQL_AAD_ADMIN_NAME}" \
    --external-admin-principal-type "${SQL_AAD_ADMIN_PRINCIPAL_TYPE}" \
    --external-admin-sid "${SQL_AAD_ADMIN_OBJECT_ID}" \
    --enable-ad-only-auth
fi

SQL_ADMIN_COUNT="$(az sql server ad-admin list \
  --resource-group "${RG}" \
  --server "${SQL_SERVER_NAME}" \
  --query "length(@)" -o tsv)"

if [[ "${SQL_ADMIN_COUNT}" == "0" ]]; then
  log "Creating Azure SQL Microsoft Entra admin"
  az sql server ad-admin create \
    --resource-group "${RG}" \
    --server "${SQL_SERVER_NAME}" \
    --display-name "${SQL_AAD_ADMIN_NAME}" \
    --object-id "${SQL_AAD_ADMIN_OBJECT_ID}"
else
  log "Updating Azure SQL Microsoft Entra admin"
  az sql server ad-admin update \
    --resource-group "${RG}" \
    --server "${SQL_SERVER_NAME}" \
    --display-name "${SQL_AAD_ADMIN_NAME}" \
    --object-id "${SQL_AAD_ADMIN_OBJECT_ID}"
fi

log "Ensuring Azure SQL Entra-only authentication is enabled"
az sql server ad-only-auth enable \
  --resource-group "${RG}" \
  --name "${SQL_SERVER_NAME}"

if az sql db show --resource-group "${RG}" --server "${SQL_SERVER_NAME}" --name "${SQL_DB_NAME}" >/dev/null 2>&1; then
  log "Azure SQL Database already exists; reusing ${SQL_DB_NAME}"
else
  log "Creating Azure SQL Database using the current free-offer serverless baseline"
  az sql db create \
    --resource-group "${RG}" \
    --server "${SQL_SERVER_NAME}" \
    --name "${SQL_DB_NAME}" \
    --edition "${SQL_DB_EDITION}" \
    --family "${SQL_DB_FAMILY}" \
    --capacity "${SQL_DB_CAPACITY}" \
    --compute-model "${SQL_DB_COMPUTE_MODEL}" \
    --auto-pause-delay "${SQL_DB_AUTO_PAUSE_DELAY}" \
    --backup-storage-redundancy "${SQL_DB_BACKUP_REDUNDANCY}" \
    --use-free-limit true \
    --free-limit-exhaustion-behavior "${SQL_DB_FREE_LIMIT_EXHAUSTION_BEHAVIOR}"
fi

if az sql server firewall-rule show \
  --resource-group "${RG}" \
  --server "${SQL_SERVER_NAME}" \
  --name "AllowAzureServices" >/dev/null 2>&1; then
  log "SQL firewall rule AllowAzureServices already exists"
else
  log "Allowing Azure services through the SQL server firewall for sample setup"
  az sql server firewall-rule create \
    --resource-group "${RG}" \
    --server "${SQL_SERVER_NAME}" \
    --name "AllowAzureServices" \
    --start-ip-address 0.0.0.0 \
    --end-ip-address 0.0.0.0
fi

if [[ -z "${AAD_APP_CLIENT_ID}" ]]; then
  AAD_APP_MATCH_COUNT="$(az ad app list \
    --all \
    --query "[?displayName=='${AAD_APP_NAME}'] | length(@)" -o tsv)"

  if [[ "${AAD_APP_MATCH_COUNT}" == "0" ]]; then
    log "Creating the Microsoft Entra app registration used by Easy Auth"
    AAD_APP_CLIENT_ID="$(az ad app create \
      --display-name "${AAD_APP_NAME}" \
      --web-redirect-uris "${AAD_APP_REDIRECT_URI}" \
      --query appId -o tsv)"
    AAD_APP_OBJECT_ID="$(resolve_app_object_id "${AAD_APP_CLIENT_ID}")"
  elif [[ "${AAD_APP_MATCH_COUNT}" == "1" ]]; then
    log "Microsoft Entra app registration already exists; reusing ${AAD_APP_NAME}"
    AAD_APP_OBJECT_ID="$(az ad app list \
      --all \
      --query "[?displayName=='${AAD_APP_NAME}'][0].id" -o tsv)"
    AAD_APP_CLIENT_ID="$(az ad app list \
      --all \
      --query "[?displayName=='${AAD_APP_NAME}'][0].appId" -o tsv)"
  else
    echo "Multiple Microsoft Entra app registrations matched display name '${AAD_APP_NAME}'." >&2
    echo "Set AAD_APP_CLIENT_ID explicitly in ${ENV_FILE} and rerun." >&2
    exit 1
  fi
else
  log "Using provided Microsoft Entra app registration client ID"
fi

if [[ -n "${AAD_APP_CLIENT_ID}" ]] && ! looks_like_guid "${AAD_APP_CLIENT_ID}"; then
  log "Provided AAD_APP_CLIENT_ID is not a GUID; ignoring it and resolving from the existing app registration"
  AAD_APP_CLIENT_ID=""
fi

if [[ -n "${AAD_APP_OBJECT_ID}" ]] && ! app_object_exists "${AAD_APP_OBJECT_ID}"; then
  log "Provided AAD_APP_OBJECT_ID does not resolve to an Entra application; ignoring it and resolving from the existing app registration"
  AAD_APP_OBJECT_ID=""
fi

if [[ -z "${AAD_APP_OBJECT_ID}" && -n "${AAD_APP_CLIENT_ID}" ]]; then
  AAD_APP_OBJECT_ID="$(resolve_app_object_id "${AAD_APP_CLIENT_ID}")"
fi

if [[ -z "${AAD_APP_CLIENT_ID}" && -n "${AAD_APP_OBJECT_ID}" ]]; then
  AAD_APP_CLIENT_ID="$(resolve_app_client_id "${AAD_APP_OBJECT_ID}")"
fi

if [[ -z "${AAD_APP_CLIENT_ID}" || -z "${AAD_APP_OBJECT_ID}" ]]; then
  if [[ -z "${AAD_APP_OBJECT_ID}" ]]; then
    AAD_APP_OBJECT_ID="$(resolve_app_object_id_by_display_name "${AAD_APP_NAME}")"
  fi
  if [[ -z "${AAD_APP_CLIENT_ID}" ]]; then
    AAD_APP_CLIENT_ID="$(resolve_app_client_id_by_display_name "${AAD_APP_NAME}")"
  fi
fi

if [[ -z "${AAD_APP_OBJECT_ID}" ]]; then
  echo "Could not resolve the Microsoft Entra application object ID for client ID '${AAD_APP_CLIENT_ID}'." >&2
  echo "Set AAD_APP_CLIENT_ID or AAD_APP_OBJECT_ID explicitly in ${ENV_FILE} and rerun." >&2
  exit 1
fi

if [[ -z "${AAD_APP_CLIENT_ID}" ]]; then
  echo "Could not resolve the Microsoft Entra application client ID for object ID '${AAD_APP_OBJECT_ID}'." >&2
  echo "Set AAD_APP_CLIENT_ID explicitly in ${ENV_FILE} and rerun." >&2
  exit 1
fi

log "Ensuring the Easy Auth redirect URI is present on the Microsoft Entra app registration"
ensure_web_redirect_uri "${AAD_APP_OBJECT_ID}" "${AAD_APP_REDIRECT_URI}"

if [[ -z "${AAD_APP_CLIENT_SECRET}" ]]; then
  log "Resetting the Easy Auth app registration client secret for this deployment"
  AAD_APP_CLIENT_SECRET="$(az ad app credential reset \
    --id "${AAD_APP_CLIENT_ID}" \
    --query password -o tsv)"
fi

if [[ -z "${FLASK_SECRET_KEY}" ]]; then
  EXISTING_FLASK_SECRET_KEY="$(az webapp config appsettings list \
    --resource-group "${RG}" \
    --name "${WEBAPP_NAME}" \
    --query "[?name=='FLASK_SECRET_KEY'] | [0].value" -o tsv)"

  if [[ -n "${EXISTING_FLASK_SECRET_KEY}" ]]; then
    FLASK_SECRET_KEY="${EXISTING_FLASK_SECRET_KEY}"
    log "Reusing existing FLASK_SECRET_KEY from web app settings"
  else
    FLASK_SECRET_KEY="$(openssl rand -hex 32)"
    log "Generated a new FLASK_SECRET_KEY for the web app"
  fi
fi

log "Configuring App Service application settings"
az webapp config appsettings set \
  --resource-group "${RG}" \
  --name "${WEBAPP_NAME}" \
  --settings \
    SQL_SERVER_NAME="${SQL_SERVER_NAME}.database.windows.net" \
    SQL_DATABASE_NAME="${SQL_DB_NAME}" \
    FLASK_SECRET_KEY="${FLASK_SECRET_KEY}" \
    MICROSOFT_PROVIDER_AUTHENTICATION_SECRET="${AAD_APP_CLIENT_SECRET}" \
    SCM_DO_BUILD_DURING_DEPLOYMENT=true

AUTH_CONFIG_VERSION="$(az webapp auth config-version show \
  --resource-group "${RG}" \
  --name "${WEBAPP_NAME}" \
  --query configVersion -o tsv)"

if [[ "${AUTH_CONFIG_VERSION}" == "v1" ]]; then
  log "Upgrading App Service Authentication from Auth V1 to Auth V2"
  az webapp auth config-version upgrade \
    --resource-group "${RG}" \
    --name "${WEBAPP_NAME}"
fi

log "Configuring App Service Authentication"
az webapp auth update \
  --resource-group "${RG}" \
  --name "${WEBAPP_NAME}" \
  --enabled true \
  --action RedirectToLoginPage \
  --redirect-provider Microsoft \
  --require-https true

az webapp auth microsoft update \
  --resource-group "${RG}" \
  --name "${WEBAPP_NAME}" \
  --client-id "${AAD_APP_CLIENT_ID}" \
  --client-secret-setting-name MICROSOFT_PROVIDER_AUTHENTICATION_SECRET \
  --tenant-id "${TENANT_ID}" \
  --yes

if [[ "${SKIP_ZIP_DEPLOY}" != "true" ]]; then
  log "Building ZIP deployment package at ${PACKAGE_PATH}"
  rm -f "${PACKAGE_PATH}"
  zip -r "${PACKAGE_PATH}" app.py requirements.txt templates

  log "Deploying application package"
  az webapp deploy \
    --resource-group "${RG}" \
    --name "${WEBAPP_NAME}" \
    --src-path "${PACKAGE_PATH}" \
    --type zip
fi

cat <<EOF

Deployment steps completed.

Subscription ID: ${SUBSCRIPTION_ID}
Tenant ID: ${TENANT_ID}
Web app name: ${WEBAPP_NAME}
Web app URL: https://${WEBAPP_NAME}.azurewebsites.net
Web app managed identity principal ID: ${WEBAPP_MI_PRINCIPAL_ID}
SQL server: ${SQL_SERVER_NAME}.database.windows.net
SQL database: ${SQL_DB_NAME}
Easy Auth app registration client ID: ${AAD_APP_CLIENT_ID}

Next required step:
Connect to database '${SQL_DB_NAME}' on server '${SQL_SERVER_NAME}.database.windows.net'
as the Microsoft Entra admin '${SQL_AAD_ADMIN_NAME}' and run:

CREATE USER [${WEBAPP_NAME}] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [${WEBAPP_NAME}];
ALTER ROLE db_datawriter ADD MEMBER [${WEBAPP_NAME}];
ALTER ROLE db_ddladmin ADD MEMBER [${WEBAPP_NAME}];

Validation checklist after the SQL grants:
1. Browse to https://${WEBAPP_NAME}.azurewebsites.net/dashboard while signed out.
2. Confirm you are redirected to Microsoft sign-in.
3. Confirm sign-in succeeds and the dashboard loads.
4. Confirm a login row appears.
5. Refresh once and confirm no second row is inserted in the same browser session.
6. Confirm /healthz returns 200 OK.
EOF

if [[ "${SKIP_BROWSE}" != "true" ]]; then
  log "Opening the deployed site in the browser"
  az webapp browse \
    --resource-group "${RG}" \
    --name "${WEBAPP_NAME}"
fi
