# Terraform Deployment

This Terraform configuration translates the Azure resource deployment and platform configuration from [docs/spec.md](../../docs/spec.md).

It covers:

- Resource group
- Linux App Service plan
- Linux web app with system-assigned managed identity
- App settings required by the Flask app
- Azure Key Vault for generated Microsoft Entra client secrets
- App Service Authentication / Easy Auth with a Microsoft Entra app registration
- Application ID URI and app role exposure for the App Service API and dashboard administration
- Optional daemon client app registration with application permission to `GET /api/logins`
- Azure SQL logical server with Microsoft Entra-only authentication
- Azure SQL serverless database
- SQL firewall rule allowing Azure services
- Optional SQL firewall rules for the public IPs that run `terraform apply`

It intentionally does not deploy the application package.

## Module Layout

The configuration is split by concern so the module stays readable as it grows:

- `versions.tf`: Terraform version and required provider constraints
- `providers.tf`: provider configuration
- `data.tf`: shared data sources
- `locals.tf`: derived values and shared tags
- `random.tf`: generated values used across resources
- `core.tf`: shared Azure foundation resources such as the resource group and App Service plan
- `auth.tf`: Microsoft Entra app registrations, service principals, permissions, and daemon client resources
- `app_service.tf`: Linux web app configuration and Key Vault reference refresh
- `key_vault.tf`: Key Vault, RBAC assignments, and generated secret storage
- `sql.tf`: Azure SQL resources and the optional post-provision database user helper
- `variables.tf` and `outputs.tf`: module input and output contracts

## Why `azapi` Is Included

The AzureRM SQL database resource does not map cleanly to the current free-offer serverless flow from the shell script. This configuration uses `azapi_resource` for the database itself so the ARM payload can explicitly set `useFreeLimit`, `freeLimitExhaustionBehavior`, and omit `minCapacity` unless it is intentionally configured.

## Usage

1. Create a local variables file:

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
```

2. Update at least:

- `rg`
- `location`
- `app_plan`
- `webapp_name`
- `sql_server_name`
- `sql_db_name`

By default, the SQL Microsoft Entra admin is set to the identity running Terraform, using `data.azurerm_client_config.current.object_id` and an Azure AD lookup for the display name. Only set these if you need to override that default:

- `sql_aad_admin_name`
- `sql_aad_admin_object_id`

Optional daemon-related inputs:

- `clear_logins_app_role`
- `clear_logins_admin_group_object_id`
- `create_daemon_client`
- `daemon_client_name`
- `aad_app_identifier_uri`
- `login_events_api_app_role`
- `daemon_client_secret_end_date_relative`

Optional Key Vault input:

- `key_vault_name`

Optional SQL admin override inputs:

- `sql_aad_admin_name`
- `sql_aad_admin_object_id`

Optional SQL firewall input:

- `sql_firewall_allowed_ipv4_addresses`

3. Initialize and apply:

```bash
terraform init
terraform apply
```

4. Generate a reusable env file for `scripts/deploy_app_only.sh` and `scripts/test_daemon_api.sh`:

```bash
terraform output -raw scripts_deploy_env > ../../scripts/deploy.env
```

## Post-Provision SQL Step

By default, Terraform provisions the Azure resources and platform configuration, but it does not create the contained database user for the web app managed identity. After `terraform apply`, connect to the target database as the configured Microsoft Entra admin and run:

```sql
CREATE USER [<webapp-name>] FROM EXTERNAL PROVIDER WITH OBJECT_ID = '<webapp-managed-identity-object-id>';
ALTER ROLE db_datareader ADD MEMBER [<webapp-name>];
ALTER ROLE db_datawriter ADD MEMBER [<webapp-name>];
ALTER ROLE db_ddladmin ADD MEMBER [<webapp-name>];
```

You can also read the exact SQL from the `post_provision_sql` Terraform output.

If you want Terraform to execute this step on the machine running `terraform apply`, set:

```hcl
create_webapp_managed_identity_db_user = true
```

This opt-in helper uses a `local-exec` provisioner that runs [`scripts/create_webapp_managed_identity_db_user.sh`](/vagrant/azure-webapp-sql-with-auth/scripts/create_webapp_managed_identity_db_user.sh). The apply host must have:

- `sqlcmd` installed with support for `--authentication-method ActiveDirectoryDefault`
- a Microsoft Entra-authenticated identity that is the configured Azure SQL admin for the server
- by default, that SQL admin is the same identity running `terraform apply`, unless you override `sql_aad_admin_name` and `sql_aad_admin_object_id`
- network access to `<sql-server>.database.windows.net:1433`

If the apply host is outside Azure, `AllowAzureServices` is not sufficient. Add the host's public egress IP to `sql_firewall_allowed_ipv4_addresses`. For the current workstation used with this repository, the detected breakout IP is `81.164.248.111`, so the input looks like:

```hcl
sql_firewall_allowed_ipv4_addresses = ["81.164.248.111"]
```

Optional inputs:

- `sql_firewall_allowed_ipv4_addresses`
- `webapp_managed_identity_db_user_name`
- `webapp_managed_identity_db_user_use_object_id`

The helper is idempotent and retries transient propagation failures, but it still runs from the local Terraform client, not from Azure. Keep the variable disabled in CI or remote runners that don't have the required SQL tooling, auth context, and a predictable outbound IP.

## Auth Outputs

Terraform also creates:

- a user app role on the App Service app registration for clearing dashboard login rows
- an optional assignment of that clear-logins role to an existing external security group when `clear_logins_admin_group_object_id` is set
- when `create_daemon_client = true`, an app role on the App Service app registration for daemon access to `GET /api/logins`
- when `create_daemon_client = true`, a daemon client application registration
- when `create_daemon_client = true`, a daemon client secret stored in Azure Key Vault
- when `create_daemon_client = true`, the application-permission grant and admin-consent equivalent app-role assignment

Useful outputs:

- `clear_logins_app_role`
- `clear_logins_admin_group_object_id`
- `key_vault_name`
- `easy_auth_application_id_uri`
- `easy_auth_client_secret_name`
- `login_events_api_app_role`
- `daemon_client_id`
- `daemon_client_secret_name`
- `daemon_token_request_example`
- `scripts_deploy_env`

The daemon requests a token for:

```text
<easy_auth_application_id_uri>/.default
```

and calls:

```text
https://<webapp-name>.azurewebsites.net/api/logins
```

## Notes

- The generated app registration is single-tenant (`AzureADMyOrg`) to match the current sample.
- The web app is configured for HTTPS-only and Easy Auth redirects unauthenticated users to Microsoft Entra sign-in.
- `/healthz` is excluded from the Easy Auth redirect so platform health checks can reach it anonymously.
- The web app uses its system-assigned managed identity to resolve the Easy Auth client secret from Key Vault.
- The Key Vault uses Azure RBAC authorization, not legacy access policies.
- Terraform grants the web app managed identity the `Key Vault Secrets User` role on the vault.
- Terraform grants the identity running `terraform apply` the `Key Vault Secrets Officer` role on the vault so it can write generated secrets.
- The role assignments require enough control-plane permission to create Azure RBAC assignments, such as `Owner` or `User Access Administrator` on the vault scope or above.
- The web app authentication settings accept both the Easy Auth client ID and the exposed Application ID URI as valid audiences.
- The Easy Auth app setting `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` is stored as an App Service Key Vault reference rather than a raw secret value.
- Terraform waits briefly for Key Vault RBAC propagation before creating secrets because data-plane permissions are not always effective immediately.
- Terraform still sees generated secret values because it creates the app-registration passwords before writing them into Key Vault.
- Daemon authorization for `GET /api/logins` is still enforced in Flask because the sample site also hosts interactive browser routes.
- The SQL server uses Microsoft Entra-only authentication and does not provision a SQL admin login.
