# Azure App Service + Azure SQL + Easy Auth Specification

## 1. Objective

Build a small production-style sample application that runs on Azure App Service, uses Flask, stores login audit data in Azure SQL Database, and relies on Azure App Service Authentication ("Easy Auth") with Microsoft Entra ID for user sign-in.

The application must:

- Require users to authenticate before accessing the app.
- Use the web app's system-assigned managed identity to connect to Azure SQL Database without a SQL username/password in application settings.
- Record a login event for each authenticated user.
- Show recorded user and application login events on a dashboard after sign-in.
- Expose a protected JSON API endpoint that returns recent login events.
- Allow a Microsoft Entra daemon client application to call the login events API by using OAuth 2.0 client credentials.
- Use the current Azure SQL Database free offer for the sample database so the baseline deployment stays in the no-cost tier when the subscription is eligible and monthly limits are not exceeded.

This document is the implementation contract. An agent should be able to build the app and the infrastructure from this file alone.

## 2. Scope

### In scope

- One Flask web application deployed to Azure App Service.
- One Azure SQL logical server and one Azure SQL Database.
- Easy Auth configured on the App Service app with Microsoft Entra ID.
- One Azure Key Vault used to store generated Microsoft Entra client secrets.
- A simple schema for login audit records.
- A dashboard page that displays the recorded login data.
- A JSON API endpoint that returns recent login audit rows.
- A daemon client application registration that can be granted application permission to the login events API.
- Azure CLI commands to provision and configure the required Azure resources.

### Out of scope

- Complex authorization such as RBAC inside the app.
- Multi-tenant sign-in.
- Background jobs, queues, or analytics pipelines.
- CI/CD pipeline setup.
- Advanced UI frameworks.
- Local Docker support.

## 3. Required Architecture

### Azure resources

The solution uses these resources:

- Resource group.
- App Service plan.
- Azure App Service (Linux, Python runtime).
- Azure SQL logical server.
- Azure SQL Database configured for the current Azure SQL Database free offer.
- Azure Key Vault for generated client secrets.
- One Microsoft Entra app registration for Easy Auth.

### Authentication flow

The authentication model is:

1. A browser requests the web app.
2. Easy Auth intercepts unauthenticated requests.
3. Easy Auth redirects the user to Microsoft Entra ID.
4. After successful sign-in, Easy Auth injects authenticated user information into request headers.
5. Flask reads the injected headers and treats the request as authenticated.
6. Flask writes a login record into Azure SQL.
7. Flask renders the dashboard with recent user and application login events.

The application must not implement its own OpenID Connect flow in Flask. Authentication is handled by App Service Authentication.

### Daemon client flow

The machine-to-machine access model is:

1. A daemon application is registered in Microsoft Entra ID as a confidential client.
2. The App Service app registration exposes an API Application ID URI and an application permission for reading login events.
3. The daemon application receives admin consent for that application permission.
4. The daemon application requests an access token by using the OAuth 2.0 client credentials grant.
5. The daemon sends `Authorization: Bearer <token>` to `GET /api/logins`.
6. App Service Authentication validates the token and injects principal headers for Flask.
7. Flask authorizes the application principal by checking the required app role before returning the JSON payload.

This flow is app-only. It must not depend on an interactive user session.

### Database access flow

The database access model is:

1. The App Service web app has a system-assigned managed identity enabled.
2. Azure SQL is configured for Microsoft Entra authentication.
3. The managed identity is created as a contained database user in the target database.
4. Flask obtains an access token for `https://database.windows.net/.default`.
5. Flask connects to Azure SQL using that token and the ODBC SQL Server driver.

The application must not store a SQL password in code, repo files, or app settings.

## 4. Implementation Decisions

These decisions are fixed to reduce ambiguity for the implementing agent.

### Runtime and libraries

- Language: Python 3.12.
- Web framework: Flask.
- Database driver: `pyodbc`.
- Azure identity library: `azure-identity`.
- Optional packaging: `requirements.txt`.
- App entrypoint: `app.py`.
- Microsoft Entra daemon flow: OAuth 2.0 client credentials.

### Fixed daemon authorization values

These values are part of the implementation contract:

- App role value required for daemon access to `GET /api/logins`: `read_login_events`
- Default Application ID URI for the App Service API: `api://<easy-auth-client-id>`

### Secrets management

- The Easy Auth app registration client secret must be stored in Azure Key Vault.
- The daemon client app registration secret must be stored in Azure Key Vault when the daemon client is created.
- The Azure Key Vault must use Azure RBAC for data-plane authorization rather than legacy access policies.
- The App Service app setting `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` must be configured as an App Service Key Vault reference, not as a raw secret value.
- The web app must use its system-assigned managed identity to resolve Key Vault references.
- The web app managed identity must be assigned the `Key Vault Secrets User` role on the vault.
- The identity that provisions or rotates secrets must be assigned a write-capable Key Vault data-plane role such as `Key Vault Secrets Officer` or `Key Vault Administrator`.

### App Service hosting assumptions

- Hosting target is Azure App Service on Linux.
- Easy Auth is enabled at the platform level.
- Unauthenticated requests are redirected to Microsoft Entra sign-in.
- HTTPS is required.

### Azure SQL tier assumption

The Azure SQL Database for this sample must use the current Azure SQL Database free offer baseline instead of the legacy `Basic` tier.

Use these assumptions:

- Service tier: `GeneralPurpose`
- Compute tier: `Serverless`
- Free offer enabled with `--use-free-limit`
- Free-limit exhaustion behavior: `AutoPause`
- Backup storage redundancy: `Local`

This keeps the sample aligned with the current Azure SQL free-offer model described by Microsoft Learn, where free usage is applied to eligible General Purpose serverless databases rather than DTU-based `Basic` databases.

### User identity source inside Flask

The application must use Easy Auth request headers as the source of user identity.

Preferred approach:

- Read `X-MS-CLIENT-PRINCIPAL` from the incoming request.
- Base64-decode the header value.
- Parse the JSON payload.
- Extract claims needed for:
  - User object ID.
  - Display name.
  - Preferred username or email.
  - Identity provider.

The implementing agent should assume the decoded payload uses the common Easy Auth shape:

```json
{
  "auth_typ": "aad",
  "name_typ": "name",
  "role_typ": "roles",
  "claims": [
    { "typ": "name", "val": "Alice Smith" },
    { "typ": "preferred_username", "val": "alice@contoso.com" },
    {
      "typ": "http://schemas.microsoft.com/identity/claims/objectidentifier",
      "val": "00000000-0000-0000-0000-000000000000"
    }
  ]
}
```

Use this claim precedence:

- Object ID:
  - `http://schemas.microsoft.com/identity/claims/objectidentifier`
  - fallback `oid`
- Display name:
  - `name`
- Email / username:
  - `preferred_username`
  - fallback `email`
  - fallback `upn`

If the decoded principal payload is missing, the request should be treated as unauthenticated and return HTTP 401 for JSON endpoints or redirect to `/.auth/login/aad` for browser routes.

### Application identity source inside Flask

The daemon client calls are also delivered through Easy Auth headers. The Flask app must support application principals in addition to user principals.

Preferred claim handling for application principals:

- Client application ID:
  - `azp`
  - fallback `appid`
  - fallback `client_id`
- Application object ID:
  - `http://schemas.microsoft.com/identity/claims/objectidentifier`
  - fallback `oid`
- App roles:
  - `roles`
- App-only hint:
  - `idtyp=app` when present
  - otherwise treat the token as app-only when `oid == sub` and a client application ID exists

Implementation rule:

- The app must distinguish between:
  - interactive user principals
  - application principals
- `GET /dashboard` must allow only interactive user principals.
- `GET /api/logins` must allow:
  - interactive user principals
  - application principals that contain the `read_login_events` app role

## 5. Functional Requirements

### FR-1: Protected application

All user-facing app routes must require authentication.

- Anonymous users must not be able to access the dashboard.
- App Service Authentication should enforce this before Flask handles the request.
- The app must expose `/healthz` anonymously for operational checks.

### FR-2: Login auditing

The app must record one login event whenever an authenticated user first reaches the dashboard in a new browser session.

Implementation rule:

- Use Flask session state to avoid inserting duplicate audit rows on page refresh in the same browser session.
- Set a session flag after the first successful insert.
- If a new browser session is started, insert a new login row again.

This rule is intentionally simple and sufficient for the sample app.

Additional rule for daemon access:

- When an authorized application principal successfully calls `GET /api/logins`, the app must record an application login event.
- This application event should be recorded per successful API call.

### FR-3: Dashboard

The dashboard must show:

- The current signed-in user summary.
- A table of recent user and application login events.

The table must include:

- Login timestamp in UTC.
- Principal type.
- Display name.
- Email or preferred username.
- Client application ID when the row represents an application principal.
- Microsoft Entra object ID.

### FR-4: Login events API

The app must expose a protected JSON endpoint for recent login events.

Implementation rules:

- Route: `GET /api/logins`
- Authentication is required.
- The endpoint returns HTTP 200 with `application/json`.
- The response body must be an object with a `login_events` array.
- Each item in `login_events` must include:
  - `login_at`
  - `principal_type`
  - `display_name`
  - `email`
  - `client_app_id`
  - `aad_object_id`
  - `identity_provider`
- Rows must be ordered from newest to oldest.
- The endpoint should return the same most recent 50 rows shown on the dashboard.
- The endpoint must insert an audit row when the caller is an authorized application principal.
- The endpoint should not insert an additional audit row when the caller is a user principal that is only reading the API.
- The endpoint must allow:
  - authenticated user principals
  - authenticated application principals with the `read_login_events` app role
- The endpoint must reject authenticated application principals that do not have the required app role.

If the request is unauthenticated, the endpoint must return HTTP 401 with a JSON body:

```json
{
  "error": "authentication_required"
}
```

If the request is authenticated but the application principal is missing the required app role, the endpoint must return HTTP 403 with a JSON body:

```json
{
  "error": "insufficient_role"
}
```

### FR-5: Database bootstrap

The application should initialize the required table if it does not exist yet.

Implementation rule:

- Schema creation may happen during app startup or through a dedicated helper function called before querying.
- Table creation must be idempotent.

### FR-6: Operational simplicity

The implementation should prefer the smallest number of files and moving parts that still keep the app understandable.

## 6. Suggested Flask Routes

The implementation should use these routes unless there is a strong reason to change them:

- `GET /`
  - Redirects to `/dashboard`.
- `GET /dashboard`
  - Requires authentication.
  - Allows only authenticated user principals.
  - Records the login event for the current browser session if not already recorded.
  - Loads recent user and application login rows from Azure SQL.
  - Renders the main HTML page.
- `GET /api/logins`
  - Requires authentication.
  - Allows authenticated user principals.
  - Allows authenticated application principals that contain the `read_login_events` app role.
  - Records an application login row when called by an authorized application principal.
  - Loads recent user and application login rows from Azure SQL.
  - Returns the rows as JSON.
  - Does not insert an additional audit row for user principals that are only reading the API.
- `GET /healthz`
  - Returns `200 OK` and a simple body like `ok`.
  - Must remain anonymous to support health checks.
- `GET /.auth/me`
  - Provided by Easy Auth, not implemented by Flask.
- `GET /.auth/login/aad`
  - Provided by Easy Auth, not implemented by Flask.
- `GET /.auth/logout`
  - Provided by Easy Auth, not implemented by Flask.

## 7. Database Schema

Use one table named `user_logins`.

### Table definition

Required columns:

- `id INT IDENTITY(1,1) PRIMARY KEY`
- `aad_object_id NVARCHAR(64) NOT NULL`
- `principal_type NVARCHAR(32) NOT NULL`
- `display_name NVARCHAR(256) NOT NULL`
- `email NVARCHAR(256) NULL`
- `client_app_id NVARCHAR(64) NULL`
- `identity_provider NVARCHAR(64) NOT NULL`
- `login_at DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET()`

### Recommended indexes

- Primary key on `id`.
- Nonclustered index on `login_at DESC`.
- Optional nonclustered index on `aad_object_id`.

### DDL

```sql
IF NOT EXISTS (
    SELECT 1
    FROM sys.tables
    WHERE name = 'user_logins'
)
BEGIN
    CREATE TABLE dbo.user_logins (
        id INT IDENTITY(1,1) PRIMARY KEY,
        aad_object_id NVARCHAR(64) NOT NULL,
        principal_type NVARCHAR(32) NOT NULL
            CONSTRAINT DF_user_logins_principal_type DEFAULT 'user',
        display_name NVARCHAR(256) NOT NULL,
        email NVARCHAR(256) NULL,
        client_app_id NVARCHAR(64) NULL,
        identity_provider NVARCHAR(64) NOT NULL,
        login_at DATETIMEOFFSET NOT NULL
            CONSTRAINT DF_user_logins_login_at DEFAULT SYSDATETIMEOFFSET()
    );

    CREATE INDEX IX_user_logins_login_at
        ON dbo.user_logins (login_at DESC);

    CREATE INDEX IX_user_logins_aad_object_id
        ON dbo.user_logins (aad_object_id);
END

IF COL_LENGTH('dbo.user_logins', 'principal_type') IS NULL
BEGIN
    ALTER TABLE dbo.user_logins
    ADD principal_type NVARCHAR(32) NOT NULL
        CONSTRAINT DF_user_logins_principal_type_upgrade DEFAULT 'user' WITH VALUES;
END

IF COL_LENGTH('dbo.user_logins', 'client_app_id') IS NULL
BEGIN
    ALTER TABLE dbo.user_logins
    ADD client_app_id NVARCHAR(64) NULL;
END
```

## 8. App Configuration

The app should use environment variables for deploy-time configuration.

Required app settings:

- `SQL_SERVER_NAME`
  - Example: `myapp-sqlsrv.database.windows.net`
- `SQL_DATABASE_NAME`
  - Example: `myappdb`
- `FLASK_SECRET_KEY`
  - Used for Flask session signing.

Optional app settings:

- `PORT`
- `WEBSITES_PORT`

The app must not define or expect:

- `SQL_USERNAME`
- `SQL_PASSWORD`

## 9. Database Connection Requirements

### Required connection behavior

The app must:

- Obtain an Entra access token using `DefaultAzureCredential`.
- Request the scope `https://database.windows.net/.default`.
- Connect to Azure SQL using ODBC Driver 18 for SQL Server.
- Encrypt the connection.
- Validate the certificate.

### Recommended implementation pattern

Use a helper function similar to this behavior:

1. Read server and database from environment variables.
2. Get token bytes for Azure SQL.
3. Pass token to `pyodbc.connect` using the SQL access token attribute.
4. Use a short timeout.

### Connection string requirements

The effective connection settings must include:

- Driver: `ODBC Driver 18 for SQL Server`
- Server: `<server>.database.windows.net` or full hostname from app settings
- Database: target database name
- Encrypt: `yes`
- TrustServerCertificate: `no`

## 10. Easy Auth Requirements

### Required provider

- Identity provider: Microsoft Entra ID only.

### Required behavior

- App Service Authentication must be enabled.
- Unauthenticated requests must be redirected to sign-in.
- The site must use the Microsoft provider as the default sign-in provider.
- The App Service app registration must expose an Application ID URI that daemon clients can request with `/.default`.
- The App Service Authentication configuration must accept the Application ID URI as an allowed audience.

### Important implementation note

Flask should trust Easy Auth only when the app is running behind App Service Authentication. The code should not assume the same headers are trustworthy in arbitrary hosting environments.

### Authorization note for the mixed website + API design

Because the sample hosts both browser pages and the API in the same App Service site, authorization must be enforced in Flask for the daemon-specific app role check on `GET /api/logins`.

Important reasoning:

- App Service built-in allowed-client authorization checks are site-wide.
- This sample still needs interactive browser access to `/dashboard`.
- Therefore, the daemon authorization rule must be enforced in route-specific application code even if platform-level allowlists are also configured later for a dedicated API deployment.

## 11. Azure SQL Security Requirements

Azure SQL must be configured so the App Service managed identity can access the database.

Required steps:

1. Set a Microsoft Entra admin on the Azure SQL logical server.
2. Enable the App Service system-assigned managed identity.
3. Create a contained database user for the managed identity.
4. Grant the minimum required permissions.

Minimum database permissions for the sample app:

- `db_datareader`
- `db_datawriter`
- `db_ddladmin`

`db_ddladmin` is included only because the app is expected to create the table if missing. If schema creation is moved to a separate deployment step, the runtime app should not receive `db_ddladmin`.

## 12. UI Requirements

The dashboard should be simple server-rendered HTML.

Required UI elements:

- Page title.
- Current user summary card.
- Table of recent user and application logins.
- Empty state when no rows exist.
- Sign-out link pointing to `/.auth/logout`.

Required display rules:

- Show timestamps in UTC and label them as UTC.
- Sort rows by newest first.
- Limit the table to the most recent 50 rows.

## 13. Error Handling Requirements

The app must handle these failures cleanly:

- Missing Easy Auth headers.
- Failure to obtain managed identity token.
- Failure to connect to Azure SQL.
- Failure to create the schema.
- Failure to insert login audit row.
- Failure to query recent login rows.

Minimum behavior:

- Log the error on the server.
- Return HTTP 500 with a simple user-facing message for browser requests.
- Return HTTP 401 or HTTP 500 with a JSON error body for JSON API endpoints.
- Return HTTP 403 with a JSON error body when an authenticated application principal lacks the required app role.
- Do not expose secrets or raw token contents in logs.

## 14. File Structure Expectation

The implementation can remain small. A recommended structure is:

```text
.
├── app.py
├── requirements.txt
├── templates/
│   └── dashboard.html
└── docs/
    └── spec.md
```

If the implementing agent prefers a small `db.py` or `auth.py` helper module, that is acceptable, but not required.

## 15. Delivery Plan

The implementation should proceed in this order:

### Phase 1: Provision Azure resources

1. Create the resource group.
2. Create the App Service plan.
3. Create the web app with Python runtime.
4. Enable the system-assigned managed identity.
5. Create the Azure Key Vault in Azure RBAC mode and grant the required Key Vault roles.
6. Create the Azure SQL logical server.
7. Create the Azure SQL Database.
8. Configure server firewall access as needed for setup tasks.
9. Set a Microsoft Entra admin on the SQL server.

### Phase 2: Configure identity and database access

1. Create the Microsoft Entra app registration used by Easy Auth.
2. Add the redirect URI for App Service authentication.
3. Store the Easy Auth client secret in Azure Key Vault.
4. Configure Easy Auth on the web app using the Key Vault-backed app setting.
5. Create a database user mapped to the App Service managed identity.
6. Grant the database permissions required by the app.

### Phase 3: Build the Flask app

1. Create the Flask app skeleton.
2. Implement Easy Auth principal parsing.
3. Implement managed identity Azure SQL connection helper.
4. Implement idempotent schema creation.
5. Implement login audit insert logic.
6. Implement dashboard query and rendering.
7. Add login events JSON endpoint.
8. Add daemon-application principal parsing and app-role authorization for `GET /api/logins`.
9. Add health endpoint.

### Phase 4: Deploy and validate

1. Deploy the Flask code to App Service.
2. Configure app settings.
3. Browse to the site.
4. Confirm redirect to Microsoft sign-in.
5. Confirm successful sign-in.
6. Confirm the login row is inserted.
7. Confirm recent logins appear on the dashboard.

## 16. Azure CLI Command Set

The following command set is intended as the provisioning baseline. Replace placeholder values before execution.

### 16.1 Variables

```bash
RG="rg-flask-sql-auth"
LOCATION="westeurope"
APP_PLAN="plan-flask-sql-auth"
WEBAPP_NAME="app-flask-sql-auth-weeu-01"
KEY_VAULT_NAME="kvflasksqlauthweeu01"
SQL_SERVER_NAME="sql-flask-sql-auth-weeu-01"
SQL_DB_NAME="appdb"
SQL_DB_EDITION="GeneralPurpose"
SQL_DB_FAMILY="Gen5"
SQL_DB_CAPACITY="2"
SQL_DB_COMPUTE_MODEL="Serverless"
SQL_DB_AUTO_PAUSE_DELAY="60"
SQL_DB_BACKUP_REDUNDANCY="Local"
SQL_DB_FREE_LIMIT_EXHAUSTION_BEHAVIOR="AutoPause"
RUNTIME="PYTHON|3.12"
TENANT_ID="$(az account show --query tenantId -o tsv)"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

# Microsoft Entra admin for the SQL server.
# Use either a user or group that is allowed to administer Azure SQL.
SQL_AAD_ADMIN_NAME="Steven Mertens"
SQL_AAD_ADMIN_OBJECT_ID="595d861c-6322-4ca1-a607-4e502649c6aa"

# Easy Auth app registration values.
AAD_APP_NAME="app-${WEBAPP_NAME}"
AAD_APP_REDIRECT_URI="https://${WEBAPP_NAME}.azurewebsites.net/.auth/login/aad/callback"
AAD_APP_IDENTIFIER_URI="api://<easy-auth-client-id>"
LOGIN_EVENTS_APP_ROLE="read_login_events"
DAEMON_APP_NAME="${WEBAPP_NAME}-daemon"
EASY_AUTH_SECRET_NAME="easy-auth-client-secret"
DAEMON_APP_SECRET_NAME="daemon-client-secret"
```

Notes:

- The current Azure SQL free offer applies to eligible General Purpose serverless databases, not to the legacy `Basic` tier.
- Microsoft documents the free offer as including 100,000 vCore seconds, 32 GB of data storage, and 32 GB of backup storage per free database each month. The free-offer article states that up to 10 databases are supported per subscription, while current Azure CLI help for `--use-free-limit` still says one database per subscription. This sample only requires one free database, so no multi-database assumption is needed.
- If the subscription already contains a free-offer database created with advanced configuration, Azure may require subsequent free-offer databases in that subscription to use the same region.

### 16.2 Create the resource group

```bash
az group create \
  --name "$RG" \
  --location "$LOCATION"
```

### 16.3 Create the App Service plan

```bash
az appservice plan create \
  --name "$APP_PLAN" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --is-linux \
  --sku F1
```

### 16.4 Create the Flask web app

```bash
az webapp create \
  --resource-group "$RG" \
  --plan "$APP_PLAN" \
  --name "$WEBAPP_NAME" \
  --runtime "$RUNTIME"
```

### 16.5 Enable the system-assigned managed identity

```bash
az webapp identity assign \
  --resource-group "$RG" \
  --name "$WEBAPP_NAME"
```

Capture the principal ID because it identifies the managed identity in Microsoft Entra:

```bash
WEBAPP_MI_PRINCIPAL_ID="$(az webapp identity assign \
  --resource-group "$RG" \
  --name "$WEBAPP_NAME" \
  --query principalId -o tsv)"
```

### 16.5a Create the Azure Key Vault in RBAC mode and allow the web app to read secrets

```bash
az keyvault create \
  --name "$KEY_VAULT_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --enable-rbac-authorization true
```

Grant the web app managed identity the `Key Vault Secrets User` role:

```bash
KEY_VAULT_ID="$(az keyvault show \
  --name "$KEY_VAULT_NAME" \
  --resource-group "$RG" \
  --query id -o tsv)"

az role assignment create \
  --assignee-object-id "$WEBAPP_MI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "$KEY_VAULT_ID"
```

Before storing secrets, the identity running the provisioning commands must also have a write-capable data-plane role on the vault, such as `Key Vault Secrets Officer` or `Key Vault Administrator`.

### 16.6 Create the Azure SQL logical server

```bash
az sql server create \
  --name "$SQL_SERVER_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --enable-ad-only-auth true
```

### 16.7 Create the Azure SQL Database

```bash
az sql db create \
  --resource-group "$RG" \
  --server "$SQL_SERVER_NAME" \
  --name "$SQL_DB_NAME" \
  --edition "$SQL_DB_EDITION" \
  --family "$SQL_DB_FAMILY" \
  --capacity "$SQL_DB_CAPACITY" \
  --compute-model "$SQL_DB_COMPUTE_MODEL" \
  --auto-pause-delay "$SQL_DB_AUTO_PAUSE_DELAY" \
  --backup-storage-redundancy "$SQL_DB_BACKUP_REDUNDANCY" \
  --use-free-limit true \
  --free-limit-exhaustion-behavior "$SQL_DB_FREE_LIMIT_EXHAUSTION_BEHAVIOR"
```

Rationale:

- `Basic` is the old DTU-based tier and does not match the current Azure SQL free offer.
- The Azure CLI now supports free-offer creation through `--use-free-limit`.
- `AutoPause` is the safer default for this sample because it avoids overage charges if the monthly free allowance is exhausted.
- `Local` backup redundancy is explicitly specified because it is the applicable backup mode when the free database is configured to auto-pause at the free limit.

### 16.8 Set the Microsoft Entra admin on the SQL server

```bash
az sql server ad-admin create \
  --resource-group "$RG" \
  --server "$SQL_SERVER_NAME" \
  --display-name "$SQL_AAD_ADMIN_NAME" \
  --object-id "$SQL_AAD_ADMIN_OBJECT_ID"
```

### 16.9 Allow Azure services during setup

This is acceptable for a sample app. A stricter production design would use private networking instead.

```bash
az sql server firewall-rule create \
  --resource-group "$RG" \
  --server "$SQL_SERVER_NAME" \
  --name "AllowAzureServices" \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0
```

### 16.10 Create the Microsoft Entra app registration for Easy Auth

```bash
AAD_APP_CLIENT_ID="$(az ad app create \
  --display-name "$AAD_APP_NAME" \
  --web-redirect-uris "$AAD_APP_REDIRECT_URI" \
  --query appId -o tsv)"
```

Create a client secret:

```bash
AAD_APP_CLIENT_SECRET="$(az ad app credential reset \
  --id "$AAD_APP_CLIENT_ID" \
  --append \
  --query password -o tsv)"
```

Store the Easy Auth secret in Key Vault:

```bash
az keyvault secret set \
  --vault-name "$KEY_VAULT_NAME" \
  --name "$EASY_AUTH_SECRET_NAME" \
  --value "$AAD_APP_CLIENT_SECRET"
```

If the role assignment was created immediately beforehand, allow for RBAC propagation before running `az keyvault secret set`.

### 16.10a Expose the App Service API and define the daemon app role

Set the Application ID URI:

```bash
AAD_APP_IDENTIFIER_URI="api://${AAD_APP_CLIENT_ID}"

az ad app update \
  --id "$AAD_APP_CLIENT_ID" \
  --identifier-uris "$AAD_APP_IDENTIFIER_URI"
```

Create an application role in the app manifest for daemon access:

```bash
LOGIN_EVENTS_APP_ROLE_ID="$(python - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
```

Retrieve the current app manifest, append the role, and update the app registration:

```bash
az ad app show \
  --id "$AAD_APP_CLIENT_ID" \
  --query appRoles -o json
```

The resulting app registration must contain an app role equivalent to:

```json
{
  "allowedMemberTypes": ["Application"],
  "description": "Allows daemon apps to read login events from the Flask API.",
  "displayName": "Read Login Events",
  "id": "00000000-0000-0000-0000-000000000000",
  "isEnabled": true,
  "origin": "Application",
  "value": "read_login_events"
}
```

Implementation note:

- The exact CLI mechanics for patching `appRoles` can vary over time.
- Terraform should be preferred for repeatable role creation.
- If the portal is available, defining the app role there is acceptable.

### 16.10b Create the daemon client application

```bash
DAEMON_APP_CLIENT_ID="$(az ad app create \
  --display-name "$DAEMON_APP_NAME" \
  --query appId -o tsv)"
```

Create a client secret for the daemon:

```bash
DAEMON_APP_CLIENT_SECRET="$(az ad app credential reset \
  --id "$DAEMON_APP_CLIENT_ID" \
  --append \
  --query password -o tsv)"
```

Store the daemon secret in Key Vault:

```bash
az keyvault secret set \
  --vault-name "$KEY_VAULT_NAME" \
  --name "$DAEMON_APP_SECRET_NAME" \
  --value "$DAEMON_APP_CLIENT_SECRET"
```

Resolve the daemon service principal object ID:

```bash
DAEMON_APP_OBJECT_ID="$(az ad sp show \
  --id "$DAEMON_APP_CLIENT_ID" \
  --query id -o tsv)"
```

### 16.10c Grant the daemon application permission and admin consent

Add the application permission:

```bash
az ad app permission add \
  --id "$DAEMON_APP_CLIENT_ID" \
  --api "$AAD_APP_CLIENT_ID" \
  --api-permissions "<login-events-app-role-id>=Role"
```
 
Grant admin consent:

```bash
az ad app permission admin-consent \
  --id "$DAEMON_APP_CLIENT_ID"
```

Implementation note:

- The placeholder `<login-events-app-role-id>` is the GUID of the `read_login_events` app role on the App Service app registration.
- Terraform should provision this grant directly for the repeatable path.

### 16.11 Configure web app app settings

```bash
az webapp config appsettings set \
  --resource-group "$RG" \
  --name "$WEBAPP_NAME" \
  --settings \
    LOGIN_EVENTS_API_APP_ROLE="$LOGIN_EVENTS_APP_ROLE" \
    SQL_SERVER_NAME="${SQL_SERVER_NAME}.database.windows.net" \
    SQL_DATABASE_NAME="$SQL_DB_NAME" \
    FLASK_SECRET_KEY="<generate-a-random-secret>" \
    MICROSOFT_PROVIDER_AUTHENTICATION_SECRET="@Microsoft.KeyVault(VaultName=${KEY_VAULT_NAME};SecretName=${EASY_AUTH_SECRET_NAME})" \
    SCM_DO_BUILD_DURING_DEPLOYMENT=true
```

### 16.12 Configure Easy Auth

Enable auth settings V2 and require authentication:

```bash
az webapp auth update \
  --resource-group "$RG" \
  --name "$WEBAPP_NAME" \
  --enabled true \
  --action LoginWithAzureActiveDirectory
```

Configure the Microsoft identity provider:

```bash
az webapp auth microsoft update \
  --resource-group "$RG" \
  --name "$WEBAPP_NAME" \
  --client-id "$AAD_APP_CLIENT_ID" \
  --client-secret-setting-name MICROSOFT_PROVIDER_AUTHENTICATION_SECRET \
  --tenant-id "$TENANT_ID" \
  --issuer "https://sts.windows.net/${TENANT_ID}/" \
  --yes
```

Add the API audience so daemon access tokens requested for the Application ID URI are accepted:

```bash
az resource update \
  --resource-group "$RG" \
  --resource-type "Microsoft.Web/sites/config" \
  --name "${WEBAPP_NAME}/authsettingsV2" \
  --set properties.identityProviders.azureActiveDirectory.validation.allowedAudiences='["'"$AAD_APP_CLIENT_ID"'","'"$AAD_APP_IDENTIFIER_URI"'"]' \
  --set properties.globalValidation.excludedPaths='["/healthz"]'
```

### 16.13 Deploy application code

One simple option is ZIP deploy:

```bash
zip -r app.zip app.py requirements.txt templates

az webapp deploy \
  --resource-group "$RG" \
  --name "$WEBAPP_NAME" \
  --src-path app.zip \
  --type zip
```

### 16.14 Create the database user for the web app managed identity

This step must be executed while authenticated as the Microsoft Entra SQL admin.

The SQL to run against the target database is:

```sql
CREATE USER [<webapp-name>] FROM EXTERNAL PROVIDER WITH OBJECT_ID = '<webapp-managed-identity-object-id>';
ALTER ROLE db_datareader ADD MEMBER [<webapp-name>];
ALTER ROLE db_datawriter ADD MEMBER [<webapp-name>];
ALTER ROLE db_ddladmin ADD MEMBER [<webapp-name>];
```

Implementation note:

- The contained user name can still follow the web app name, but using `WITH OBJECT_ID = '<principal-id>'` removes ambiguity when Microsoft Entra display names are duplicated or drift from the resource name.
- If `WITH OBJECT_ID` is not used, the contained user name should match the App Service managed identity service principal display name as resolved in Microsoft Entra.
- In this repository, `infra/terraform` may optionally automate this step with a `local-exec` helper when `create_webapp_managed_identity_db_user = true`. That helper still requires the `terraform apply` host to have `sqlcmd`, network access to the SQL endpoint, and a Microsoft Entra-authenticated SQL admin context.

### 16.15 Validate the deployment

```bash
az webapp browse \
  --resource-group "$RG" \
  --name "$WEBAPP_NAME"
```

### 16.16 Request a daemon access token and call the API

Request a token:

```bash
ACCESS_TOKEN="$(curl -sS -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=${DAEMON_APP_CLIENT_ID}" \
  --data-urlencode "client_secret=${DAEMON_APP_CLIENT_SECRET}" \
  --data-urlencode "scope=${AAD_APP_IDENTIFIER_URI}/.default" \
  --data-urlencode "grant_type=client_credentials" | jq -r '.access_token')"
```

Call the API:

```bash
curl -sS \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://${WEBAPP_NAME}.azurewebsites.net/api/logins"
```

### 16.17 Portal steps for the same daemon setup

Equivalent Microsoft Entra and App Service portal steps:

1. Open the App Service app registration in Microsoft Entra admin center.
2. Go to `Expose an API`.
3. Set the Application ID URI to `api://<easy-auth-client-id>` unless a different approved URI is required.
4. Add an app role:
   - Display name: `Read Login Events`
   - Allowed member types: `Applications`
   - Value: `read_login_events`
   - Description: a description that states the role allows daemon access to the login events API
5. Create a new app registration for the daemon client.
6. Create a client secret or upload a certificate for the daemon client.
7. On the daemon app registration, go to `API permissions`.
8. Add a permission:
   - `My APIs`
   - select the App Service app registration
   - choose `Application permissions`
   - select `read_login_events`
9. Grant admin consent for the tenant.
10. Open the App Service Authentication blade in Azure portal.
11. Edit the Microsoft identity provider settings if needed and make sure the App Service app registration is the same one that exposes the API.
12. Add the Application ID URI to the allowed token audiences if it is not already accepted.

Portal recommendation:

- For production daemon clients, prefer a certificate credential over a client secret.
- For this sample, a client secret is acceptable because the focus is implementation simplicity.

## 17. Acceptance Criteria

The implementation is complete only when all of the following are true:

- Visiting the site while anonymous causes a Microsoft sign-in flow.
- After sign-in, the user reaches the dashboard successfully.
- The dashboard shows the signed-in user's identity details.
- Authenticated `GET /api/logins` returns recent login rows as JSON.
- Authenticated `GET /api/logins` with a daemon application token that contains `read_login_events` returns recent login rows as JSON.
- Authenticated `GET /dashboard` with an application token is rejected.
- The app creates `dbo.user_logins` automatically if it does not exist.
- The app inserts a login row for a newly authenticated browser session.
- The app inserts an application login row when an authorized daemon calls `GET /api/logins`.
- The dashboard shows recent login rows ordered from newest to oldest.
- The JSON API returns the same recent rows ordered from newest to oldest.
- A daemon client can acquire a client-credentials access token for the App Service API Application ID URI.
- No SQL username/password is stored in the app configuration.
- The app uses the App Service system-assigned managed identity for Azure SQL access.
- The Azure SQL Database is provisioned with the free-offer configuration instead of the legacy `Basic` service objective.

## 18. Non-Goals and Simplifications

These choices are intentional for the sample implementation:

- The dashboard is server-rendered HTML, not a SPA.
- Login tracking is session-based, not a globally deduplicated audit stream.
- The app can create its own table at runtime.
- Public internet access plus Easy Auth is acceptable for the sample.

## 19. Risks and Notes for the Implementing Agent

- Easy Auth header formats are platform-provided; do not hardcode assumptions beyond the documented base64 JSON principal contract.
- Azure SQL access through managed identity requires both server-level Entra setup and database-level user creation. Both are necessary.
- If ODBC Driver 18 is not present in the chosen App Service image, deployment will fail until the runtime environment includes it.
- Some Azure CLI auth commands rely on the `authV2` extension. If the CLI prompts to install an extension, allow it.
- The exact display name used by the managed identity in `CREATE USER ... FROM EXTERNAL PROVIDER` must match the Entra service principal identity visible to Azure SQL.
- Microsoft documents the free-offer database as production-quality infrastructure but without an SLA while it remains in the free amount; this sample should therefore be treated as a dev/test or proof-of-concept baseline rather than a production database sizing recommendation.
- When the free-limit exhaustion behavior is `AutoPause`, the database can become unavailable for the remainder of the calendar month after the free allowance is consumed. That is acceptable for this sample because the goal is lowest-cost provisioning.

## 20. Minimum Test Checklist

- Anonymous request to `/dashboard` redirects to sign-in.
- Authenticated request to `/dashboard` returns HTTP 200.
- Application-principal request to `/dashboard` returns HTTP 403.
- Anonymous request to `/api/logins` returns HTTP 401 JSON.
- Authenticated request to `/api/logins` returns HTTP 200 JSON.
- Application-principal request to `/api/logins` without `read_login_events` returns HTTP 403 JSON.
- Application-principal request to `/api/logins` with `read_login_events` returns HTTP 200 JSON.
- First authenticated request in a new browser session inserts one login row.
- Refreshing `/dashboard` in the same session does not insert another row.
- Recent rows query returns newest first.
- `/healthz` returns HTTP 200.
