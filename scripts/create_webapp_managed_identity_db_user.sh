#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  SQL_SERVER_FQDN=<server.database.windows.net> \
  SQL_DATABASE_NAME=<database> \
  DB_USER_NAME=<database-user-name> \
  MANAGED_IDENTITY_OBJECT_ID=<entra-object-id> \
  USE_OBJECT_ID=true \
  ./scripts/create_webapp_managed_identity_db_user.sh

Required environment variables:
  SQL_SERVER_FQDN
  SQL_DATABASE_NAME
  DB_USER_NAME

Required when USE_OBJECT_ID=true:
  MANAGED_IDENTITY_OBJECT_ID

Optional environment variables:
  USE_OBJECT_ID   default: true
  MAX_ATTEMPTS    default: 12
  RETRY_DELAY_SEC default: 10

This helper expects sqlcmd with support for:
  --authentication-method ActiveDirectoryDefault
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
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

require_command sqlcmd

require_env SQL_SERVER_FQDN
require_env SQL_DATABASE_NAME
require_env DB_USER_NAME

USE_OBJECT_ID="${USE_OBJECT_ID:-true}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-12}"
RETRY_DELAY_SEC="${RETRY_DELAY_SEC:-10}"

if [[ "${USE_OBJECT_ID}" == "true" ]]; then
  require_env MANAGED_IDENTITY_OBJECT_ID
fi

db_user_name_identifier="${DB_USER_NAME//]/]]}"
db_user_name_literal="${DB_USER_NAME//\'/\'\'}"
managed_identity_object_id="${MANAGED_IDENTITY_OBJECT_ID:-}"
managed_identity_object_id_literal="${managed_identity_object_id//\'/\'\'}"

if [[ "${USE_OBJECT_ID}" == "true" ]]; then
  create_user_statement="CREATE USER [${db_user_name_identifier}] FROM EXTERNAL PROVIDER WITH OBJECT_ID = '${managed_identity_object_id_literal}';"
else
  create_user_statement="CREATE USER [${db_user_name_identifier}] FROM EXTERNAL PROVIDER;"
fi

read -r -d '' SQL_QUERY <<EOF || true
SET NOCOUNT ON;

IF DATABASE_PRINCIPAL_ID(N'${db_user_name_literal}') IS NULL
BEGIN
  ${create_user_statement}
END;

IF NOT EXISTS (
  SELECT 1
  FROM sys.database_role_members AS role_members
  INNER JOIN sys.database_principals AS roles
    ON roles.principal_id = role_members.role_principal_id
  INNER JOIN sys.database_principals AS members
    ON members.principal_id = role_members.member_principal_id
  WHERE roles.name = N'db_datareader'
    AND members.name = N'${db_user_name_literal}'
)
BEGIN
  ALTER ROLE db_datareader ADD MEMBER [${db_user_name_identifier}];
END;

IF NOT EXISTS (
  SELECT 1
  FROM sys.database_role_members AS role_members
  INNER JOIN sys.database_principals AS roles
    ON roles.principal_id = role_members.role_principal_id
  INNER JOIN sys.database_principals AS members
    ON members.principal_id = role_members.member_principal_id
  WHERE roles.name = N'db_datawriter'
    AND members.name = N'${db_user_name_literal}'
)
BEGIN
  ALTER ROLE db_datawriter ADD MEMBER [${db_user_name_identifier}];
END;

IF NOT EXISTS (
  SELECT 1
  FROM sys.database_role_members AS role_members
  INNER JOIN sys.database_principals AS roles
    ON roles.principal_id = role_members.role_principal_id
  INNER JOIN sys.database_principals AS members
    ON members.principal_id = role_members.member_principal_id
  WHERE roles.name = N'db_ddladmin'
    AND members.name = N'${db_user_name_literal}'
)
BEGIN
  ALTER ROLE db_ddladmin ADD MEMBER [${db_user_name_identifier}];
END;
EOF

attempt=1
sqlcmd_output_file="$(mktemp)"
trap 'rm -f "${sqlcmd_output_file}"' EXIT

while (( attempt <= MAX_ATTEMPTS )); do
  log "Ensuring database user ${DB_USER_NAME} exists in ${SQL_DATABASE_NAME} on ${SQL_SERVER_FQDN} (attempt ${attempt}/${MAX_ATTEMPTS})"

  if sqlcmd \
    -S "${SQL_SERVER_FQDN}" \
    -d "${SQL_DATABASE_NAME}" \
    --authentication-method ActiveDirectoryDefault \
    -b \
    -Q "${SQL_QUERY}" >"${sqlcmd_output_file}" 2>&1; then
    if [[ -s "${sqlcmd_output_file}" ]]; then
      cat "${sqlcmd_output_file}"
    fi
    log "Managed identity database user is configured."
    exit 0
  fi

  cat "${sqlcmd_output_file}" >&2

  if grep -Eqi "unknown flag: --authentication-method|flag provided but not defined|unknown shorthand flag|unknown authentication method|unsupported authentication method" "${sqlcmd_output_file}"; then
    echo "The installed sqlcmd does not support --authentication-method ActiveDirectoryDefault." >&2
    echo "Install a sqlcmd build that supports Microsoft Entra Default authentication, or run the SQL manually." >&2
    exit 1
  fi

  if (( attempt == MAX_ATTEMPTS )); then
    break
  fi

  log "Attempt ${attempt} failed. Waiting ${RETRY_DELAY_SEC}s before retrying."
  sleep "${RETRY_DELAY_SEC}"
  attempt=$((attempt + 1))
done

echo "Failed to create or update the managed identity database user after ${MAX_ATTEMPTS} attempts." >&2
exit 1
