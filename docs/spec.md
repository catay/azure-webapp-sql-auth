# Azure App Service + Azure SQL + Easy Auth Specification

## 1. Objective

Build a small production-style sample application that runs on Azure App Service, uses Flask, stores login audit data in Azure SQL Database, and relies on Azure App Service Authentication ("Easy Auth") with Microsoft Entra ID for user sign-in.

The application must:

- Require users to authenticate before accessing the app.
- Use the web app's system-assigned managed identity to connect to Azure SQL Database without a SQL username/password in application settings.
- Record a login event for each authenticated user.
- Show recorded login events on a dashboard after sign-in.
- Expose a protected JSON API endpoint that returns recent login events.
- Use the current Azure SQL Database free offer for the sample database so the baseline deployment stays in the no-cost tier when the subscription is eligible and monthly limits are not exceeded.

This document is the implementation contract. An agent should be able to build the app and the infrastructure from this file alone.

## 2. Scope

### In scope

- One Flask web application deployed to Azure App Service.
- One Azure SQL logical server and one Azure SQL Database.
- Easy Auth configured on the App Service app with Microsoft Entra ID.
- A simple schema for login audit records.
- A dashboard page that displays the recorded login data.
- A JSON API endpoint that returns recent login audit rows.
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
- One Microsoft Entra app registration for Easy Auth.

### Authentication flow

The authentication model is:

1. A browser requests the web app.
2. Easy Auth intercepts unauthenticated requests.
3. Easy Auth redirects the user to Microsoft Entra ID.
4. After successful sign-in, Easy Auth injects authenticated user information into request headers.
5. Flask reads the injected headers and treats the request as authenticated.
6. Flask writes a login record into Azure SQL.
7. Flask renders the dashboard with recent login events.

The application must not implement its own OpenID Connect flow in Flask. Authentication is handled by App Service Authentication.

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

## 5. Functional Requirements

### FR-1: Protected application

All user-facing app routes must require authentication.

- Anonymous users must not be able to access the dashboard.
- App Service Authentication should enforce this before Flask handles the request.
- The app may expose `/healthz` anonymously for operational checks if needed.

### FR-2: Login auditing

The app must record one login event whenever an authenticated user first reaches the dashboard in a new browser session.

Implementation rule:

- Use Flask session state to avoid inserting duplicate audit rows on page refresh in the same browser session.
- Set a session flag after the first successful insert.
- If a new browser session is started, insert a new login row again.

This rule is intentionally simple and sufficient for the sample app.

### FR-3: Dashboard

The dashboard must show:

- The current signed-in user summary.
- A table of recent login events.

The table must include:

- Login timestamp in UTC.
- Display name.
- Email or preferred username.
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
  - `display_name`
  - `email`
  - `aad_object_id`
  - `identity_provider`
- Rows must be ordered from newest to oldest.
- The endpoint should return the same most recent 50 rows shown on the dashboard.
- The endpoint must not insert a new login audit row by itself.

If the request is unauthenticated, the endpoint must return HTTP 401 with a JSON body:

```json
{
  "error": "authentication_required"
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
  - Records the login event for the current browser session if not already recorded.
  - Loads recent login rows from Azure SQL.
  - Renders the main HTML page.
- `GET /api/logins`
  - Requires authentication.
  - Loads recent login rows from Azure SQL.
  - Returns the rows as JSON.
  - Does not insert a login audit row.
- `GET /healthz`
  - Returns `200 OK` and a simple body like `ok`.
  - May remain anonymous to support health checks.
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
- `display_name NVARCHAR(256) NOT NULL`
- `email NVARCHAR(256) NULL`
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
        display_name NVARCHAR(256) NOT NULL,
        email NVARCHAR(256) NULL,
        identity_provider NVARCHAR(64) NOT NULL,
        login_at DATETIMEOFFSET NOT NULL
            CONSTRAINT DF_user_logins_login_at DEFAULT SYSDATETIMEOFFSET()
    );

    CREATE INDEX IX_user_logins_login_at
        ON dbo.user_logins (login_at DESC);

    CREATE INDEX IX_user_logins_aad_object_id
        ON dbo.user_logins (aad_object_id);
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

### Important implementation note

Flask should trust Easy Auth only when the app is running behind App Service Authentication. The code should not assume the same headers are trustworthy in arbitrary hosting environments.

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
- Table of recent logins.
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
5. Create the Azure SQL logical server.
6. Create the Azure SQL Database.
7. Configure server firewall access as needed for setup tasks.
8. Set a Microsoft Entra admin on the SQL server.

### Phase 2: Configure identity and database access

1. Create the Microsoft Entra app registration used by Easy Auth.
2. Add the redirect URI for App Service authentication.
3. Configure Easy Auth on the web app.
4. Create a database user mapped to the App Service managed identity.
5. Grant the database permissions required by the app.

### Phase 3: Build the Flask app

1. Create the Flask app skeleton.
2. Implement Easy Auth principal parsing.
3. Implement managed identity Azure SQL connection helper.
4. Implement idempotent schema creation.
5. Implement login audit insert logic.
6. Implement dashboard query and rendering.
7. Add login events JSON endpoint.
8. Add health endpoint.

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

### 16.11 Configure web app app settings

```bash
az webapp config appsettings set \
  --resource-group "$RG" \
  --name "$WEBAPP_NAME" \
  --settings \
    SQL_SERVER_NAME="${SQL_SERVER_NAME}.database.windows.net" \
    SQL_DATABASE_NAME="$SQL_DB_NAME" \
    FLASK_SECRET_KEY="<generate-a-random-secret>" \
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
  --client-secret "$AAD_APP_CLIENT_SECRET" \
  --tenant-id "$TENANT_ID" \
  --issuer "https://sts.windows.net/${TENANT_ID}/"
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
CREATE USER [<webapp-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<webapp-name>];
ALTER ROLE db_datawriter ADD MEMBER [<webapp-name>];
ALTER ROLE db_ddladmin ADD MEMBER [<webapp-name>];
```

Implementation note:

- The contained user name should match the App Service managed identity service principal display name as resolved in Microsoft Entra. In many sample environments, using the web app name is the simplest working choice.
- If the exact display name differs, resolve it before running `CREATE USER`.

### 16.15 Validate the deployment

```bash
az webapp browse \
  --resource-group "$RG" \
  --name "$WEBAPP_NAME"
```

## 17. Acceptance Criteria

The implementation is complete only when all of the following are true:

- Visiting the site while anonymous causes a Microsoft sign-in flow.
- After sign-in, the user reaches the dashboard successfully.
- The dashboard shows the signed-in user's identity details.
- Authenticated `GET /api/logins` returns recent login rows as JSON.
- The app creates `dbo.user_logins` automatically if it does not exist.
- The app inserts a login row for a newly authenticated browser session.
- The dashboard shows recent login rows ordered from newest to oldest.
- The JSON API returns the same recent rows ordered from newest to oldest.
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
- Anonymous request to `/api/logins` returns HTTP 401 JSON.
- Authenticated request to `/api/logins` returns HTTP 200 JSON.
- First authenticated request in a new browser session inserts one login row.
- Refreshing `/dashboard` in the same session does not insert another row.
- Recent rows query returns newest first.
- `/healthz` returns HTTP 200.
