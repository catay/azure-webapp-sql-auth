# Azure App Service + Azure SQL + Easy Auth Sample

This repository contains a small Flask application that relies on Azure App Service Authentication for Microsoft Entra sign-in and uses the web app system-assigned managed identity to connect to Azure SQL Database without a SQL username or password.

## Files

- `app.py`: Flask app, Easy Auth principal parsing, managed-identity SQL connection, schema bootstrap, and dashboard routes.
- `templates/dashboard.html`: server-rendered dashboard UI.
- `requirements.txt`: runtime dependencies.
- `tests/test_app.py`: unit tests for auth, session deduplication, and dashboard behavior.
- `docs/spec.md`: implementation contract.

## Local Verification

Create a virtual environment, install dependencies, and run tests:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m unittest discover -s tests -v
```

## Terraform Deploy

If you only want the Azure resource deployment and platform configuration, use the modular Terraform layout under `infra/terraform/`.

The current entry point is `infra/terraform/environments/dev`, which calls the reusable `infra/terraform/modules/app-stack` module.

That Terraform path provisions:

- Resource group
- Linux App Service plan
- Linux web app with system-assigned managed identity
- Azure SQL logical server and serverless database
- SQL firewall rule allowing Azure services
- Azure Key Vault for generated Microsoft Entra client secrets
- Microsoft Entra app registration for Easy Auth
- Optional daemon client app registration
- App Service Authentication configuration
- Required app settings

It intentionally does not deploy the application package, and it still requires the same post-provision SQL grants for the web app managed identity.

The generated Easy Auth and daemon client secrets are stored in Azure Key Vault. The Easy Auth app setting `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` is configured as an App Service Key Vault reference rather than a raw secret value.
The Terraform deployment configures the vault in Azure RBAC mode, grants the web app managed identity the `Key Vault Secrets User` role for secret reads, and grants the identity running `terraform apply` the `Key Vault Secrets Officer` role so Terraform can write the generated secrets.
Terraform can also define a baseline `dashboard_read` user app role, optionally assign an existing Microsoft Entra security group to that role by object ID, and separately assign the `dashboard_write` admin role to a narrower group.

Initialize and apply from the dev environment wrapper:

```bash
terraform -chdir=infra/terraform/environments/dev init
terraform -chdir=infra/terraform/environments/dev apply
```

Keep generic environment values such as `name` and `environment` in `infra/terraform/environments/dev/terraform.tfvars`. Put environment-specific values such as object IDs, firewall IPs, and similar potentially confidential overrides in `infra/terraform/environments/dev/dev.auto.tfvars`. The `dev.auto.tfvars` file is intentionally local-only and should not be committed.

During `terraform apply`, the environment wrapper writes a ready-to-use env file for [scripts/deploy_app_only.sh](scripts/deploy_app_only.sh) and [scripts/test_daemon_api.sh](scripts/test_daemon_api.sh) at `infra/terraform/environments/dev/dev.env`.

## App-Only Deploy

If the infrastructure already exists and you only want to push a new Flask app package, use [scripts/deploy_app_only.sh](scripts/deploy_app_only.sh).

Pass the generated env file either as the first argument or through `ENV_FILE`. The script requires:

- `RG`
- `WEBAPP_NAME`

By default it uses your current Azure CLI login session. Set `AZURE_CONFIG_DIR` only if you need to point at a non-default Azure CLI profile.

Example:

```bash
./scripts/deploy_app_only.sh ./infra/terraform/environments/dev/dev.env
```

## Required Post-Provision SQL Step

The Terraform deployment intentionally stops short of creating the contained database user automatically, because that step must run while authenticated to Azure SQL as the configured Microsoft Entra admin.

Run the following against the target database:

```sql
CREATE USER [<webapp-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<webapp-name>];
ALTER ROLE db_datawriter ADD MEMBER [<webapp-name>];
ALTER ROLE db_ddladmin ADD MEMBER [<webapp-name>];
```

Replace `<webapp-name>` with the actual App Service name, which is also the expected managed identity display name in the sample deployment path.

## Daemon API Testing

Pass the generated `infra/terraform/environments/dev/dev.env` file as the first argument, or set `ENV_FILE` if you want to point the script at a different environment file:

```bash
./scripts/test_daemon_api.sh ./infra/terraform/environments/dev/dev.env
```

For `scripts/test_daemon_api.sh`, set:

- `TENANT_ID`
- `CLIENT_ID`
- `SCOPE`
- `TOKEN_URL`
- `API_URL`

Then choose one secret source:

- Preferred: `KEY_VAULT_NAME` and `DAEMON_CLIENT_SECRET_NAME`
- Fallback: `CLIENT_SECRET`

When Key Vault variables are provided, the script reads the daemon secret from Key Vault with the current Azure CLI login.
The script now waits for the app to report healthy before calling `GET /api/logins`; override `HEALTH_URL` if it cannot be derived from `API_URL`, and tune `HEALTH_MAX_ATTEMPTS`, `HEALTH_RETRY_SECONDS`, `HEALTH_CONNECT_TIMEOUT_SECONDS`, or `HEALTH_TIMEOUT_SECONDS` if your App Service or database regularly needs a longer warm-up window.

## Validation

After the SQL grants are applied:

1. Open `https://<webapp-name>.azurewebsites.net/dashboard` while signed out.
2. Confirm Microsoft sign-in is required.
3. Confirm the dashboard loads after sign-in.
4. Confirm the signed-in user summary is displayed.
5. Confirm one login row is inserted for the new browser session.
6. Refresh `/dashboard` and confirm no second row is inserted in the same browser session.
7. Confirm `https://<webapp-name>.azurewebsites.net/healthz` returns `200 OK` without requiring sign-in.

## Notes

- The application expects `SQL_SERVER_NAME`, `SQL_DATABASE_NAME`, and `FLASK_SECRET_KEY` as app settings.
- The application also supports optional `DASHBOARD_READ_APP_ROLE`, `API_READ_APP_ROLE`, and `DASHBOARD_WRITE_APP_ROLE` overrides when role values differ from the defaults.
- The application does not use `SQL_USERNAME` or `SQL_PASSWORD`.
- App Service must have ODBC Driver 18 for SQL Server available at runtime for `pyodbc` connections.
- Outside Azure App Service, Easy Auth headers are not trusted by default.
