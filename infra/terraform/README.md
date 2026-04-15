# Terraform Deployment

This Terraform configuration translates the Azure resource deployment and platform configuration from [docs/spec.md](../../docs/spec.md) and [scripts/deploy_azure.sh](../../scripts/deploy_azure.sh).

It covers:

- Resource group
- Linux App Service plan
- Linux web app with system-assigned managed identity
- App settings required by the Flask app
- App Service Authentication / Easy Auth with a Microsoft Entra app registration
- Azure SQL logical server with Microsoft Entra-only authentication
- Azure SQL serverless database
- SQL firewall rule allowing Azure services

It intentionally does not deploy the application package.

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
- `sql_aad_admin_name`
- `sql_aad_admin_object_id`

3. Initialize and apply:

```bash
terraform init
terraform apply
```

## Post-Provision SQL Step

Terraform provisions the Azure resources and platform configuration, but it does not create the contained database user for the web app managed identity. After `terraform apply`, connect to the target database as the configured Microsoft Entra admin and run:

```sql
CREATE USER [<webapp-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<webapp-name>];
ALTER ROLE db_datawriter ADD MEMBER [<webapp-name>];
ALTER ROLE db_ddladmin ADD MEMBER [<webapp-name>];
```

You can also read the exact SQL from the `post_provision_sql` Terraform output.

## Notes

- The generated app registration is single-tenant (`AzureADMyOrg`) to match the current sample.
- The web app is configured for HTTPS-only and Easy Auth redirects unauthenticated users to Microsoft Entra sign-in.
- The SQL server uses Microsoft Entra-only authentication and does not provision a SQL admin login.
