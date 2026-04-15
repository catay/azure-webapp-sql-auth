# Azure App Service + Azure SQL + Easy Auth Sample

This repository contains a small Flask application that relies on Azure App Service Authentication for Microsoft Entra sign-in and uses the web app system-assigned managed identity to connect to Azure SQL Database without a SQL username or password.

## Files

- `app.py`: Flask app, Easy Auth principal parsing, managed-identity SQL connection, schema bootstrap, and dashboard routes.
- `templates/dashboard.html`: server-rendered dashboard UI.
- `requirements.txt`: runtime dependencies.
- `tests/test_app.py`: unit tests for auth, session deduplication, and dashboard behavior.
- `scripts/deploy_azure.sh`: end-to-end Azure provisioning and ZIP deploy helper.
- `scripts/deploy.env.example`: environment variable template for the deployment script.
- `docs/spec.md`: implementation contract.

## Local Verification

Create a virtual environment, install dependencies, and run tests:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m unittest discover -s tests -v
```

## Deploy

1. Copy the deployment environment template and adjust the values:

```bash
cp scripts/deploy.env.example scripts/deploy.env
```

2. Review and update:

- `RG`
- `LOCATION`
- `APP_PLAN`
- `WEBAPP_NAME`
- `SQL_SERVER_NAME`
- `SQL_DB_NAME`
- `SQL_AAD_ADMIN_NAME`
- `SQL_AAD_ADMIN_OBJECT_ID`
- `SQL_AAD_ADMIN_PRINCIPAL_TYPE`

Use `User`, `Group`, or `Application` for `SQL_AAD_ADMIN_PRINCIPAL_TYPE`. Most setups will use `User` or `Group`.

3. Run the deployment script:

```bash
./scripts/deploy_azure.sh
```

The script automatically loads `scripts/deploy.env` if that file exists. If you want to point at a different file, use:

```bash
ENV_FILE=./scripts/deploy.env ./scripts/deploy_azure.sh
```

The deployment script is restart-safe for the common partial-failure cases:

- It reuses the resource group, App Service plan, web app, SQL server, SQL database, and firewall rule when they already exist.
- It re-applies the web app managed identity, SQL Entra admin, Entra-only auth, app settings, and Easy Auth configuration on rerun.
- It reuses an existing `FLASK_SECRET_KEY` from the web app if one is already set.
- It reuses an existing Entra app registration when exactly one app matches `AAD_APP_NAME`.
- It defaults `AZURE_CONFIG_DIR` to a writable `/tmp` path so Azure CLI logging and extensions work in restricted environments.

If multiple Entra app registrations share the same display name, set `AAD_APP_CLIENT_ID` explicitly in `scripts/deploy.env` before rerunning.

If your tenant behaves inconsistently when listing Entra applications, you can also set `AAD_APP_CLIENT_ID` and `AAD_APP_OBJECT_ID` explicitly in `scripts/deploy.env` to skip the lookup path.

If `AAD_APP_CLIENT_SECRET` is not provided, the script rotates the app registration client secret on each run and updates App Service Authentication with the new value. If you want to keep a fixed secret across reruns, set `AAD_APP_CLIENT_SECRET` explicitly.

The script provisions:

- Resource group
- Linux App Service plan
- Python web app
- System-assigned managed identity
- Azure SQL logical server
- Azure SQL Database using the current free-offer serverless configuration
- SQL firewall rule allowing Azure services for setup
- Microsoft Entra app registration for Easy Auth
- App Service Authentication configuration
- App settings
- ZIP deployment package

## Terraform Deploy

If you only want the Azure resource deployment and platform configuration, use the Terraform configuration in [infra/terraform](infra/terraform/README.md).

That Terraform path provisions:

- Resource group
- Linux App Service plan
- Linux web app with system-assigned managed identity
- Azure SQL logical server and serverless database
- SQL firewall rule allowing Azure services
- Microsoft Entra app registration for Easy Auth
- App Service Authentication configuration
- Required app settings

It intentionally does not deploy the application package, and it still requires the same post-provision SQL grants for the web app managed identity.

## App-Only Deploy

If the infrastructure already exists and you only want to push a new Flask app package, use [scripts/deploy_app_only.sh](scripts/deploy_app_only.sh).

It reuses `scripts/deploy.env` if present, but only requires:

- `RG`
- `WEBAPP_NAME`

By default it uses your current Azure CLI login session. Set `AZURE_CONFIG_DIR` only if you need to point at a non-default Azure CLI profile.

Example:

```bash
./scripts/deploy_app_only.sh
```

## Required Post-Provision SQL Step

The script intentionally stops short of creating the contained database user automatically, because that step must run while authenticated to Azure SQL as the configured Microsoft Entra admin.

Run the following against the target database:

```sql
CREATE USER [<webapp-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<webapp-name>];
ALTER ROLE db_datawriter ADD MEMBER [<webapp-name>];
ALTER ROLE db_ddladmin ADD MEMBER [<webapp-name>];
```

Replace `<webapp-name>` with the actual App Service name, which is also the expected managed identity display name in the sample deployment path.

## Validation

After the SQL grants are applied:

1. Open `https://<webapp-name>.azurewebsites.net/dashboard` while signed out.
2. Confirm Microsoft sign-in is required.
3. Confirm the dashboard loads after sign-in.
4. Confirm the signed-in user summary is displayed.
5. Confirm one login row is inserted for the new browser session.
6. Refresh `/dashboard` and confirm no second row is inserted in the same browser session.
7. Confirm `https://<webapp-name>.azurewebsites.net/healthz` returns `200 OK`.

## Notes

- The application expects `SQL_SERVER_NAME`, `SQL_DATABASE_NAME`, and `FLASK_SECRET_KEY` as app settings.
- The application does not use `SQL_USERNAME` or `SQL_PASSWORD`.
- App Service must have ODBC Driver 18 for SQL Server available at runtime for `pyodbc` connections.
- Outside Azure App Service, Easy Auth headers are not trusted by default.
