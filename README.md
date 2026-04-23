# Azure App Service + Azure SQL + Easy Auth Sample

## Introduction

This repository deploys a small Flask application to Azure App Service. The app uses App Service Authentication with Microsoft Entra ID for sign-in, stores login events in Azure SQL Database, and connects to the database with the web app's system-assigned managed identity instead of a SQL username and password.

The default Terraform configuration targets free Azure options where available: the App Service plan defaults to `F1`, and the Azure SQL database defaults to the Azure SQL free offer settings. In an eligible subscription and while staying within the free monthly limits, the default sample deployment should not incur cost.

Use this repo when you want to:

- Provision the Azure infrastructure with Terraform
- Deploy or redeploy the Flask app package
- Run the daemon/API verification script against a deployed environment

The functional contract for the app and infrastructure lives in [docs/spec.md](docs/spec.md).

## Prerequisites

### Local tools

Install these tools locally before you deploy:

- `bash`
- `python3.12` with `venv`
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [Terraform 1.6+](https://developer.hashicorp.com/terraform/install)
- `sqlcmd` from go-sqlcmd or another build that supports `--authentication-method ActiveDirectoryDefault`
- `zip` for app package deployment
- `curl` and `jq` for the daemon API test script

The Terraform deployment uses `sqlcmd` during `terraform apply` to create the Azure SQL contained database user for the web app managed identity. There is no separate manual post-provision SQL step in the normal flow anymore.

### Azure and Microsoft Entra permissions

The identity that runs `terraform apply` needs both Azure resource permissions and Microsoft Entra application-management permissions:

- Azure subscription or resource-group scope:
  - `Contributor` plus `User Access Administrator`, or
  - `Owner`
- Azure Key Vault data plane:
  - `Key Vault Secrets Officer`
- Microsoft Entra ID:
  - `Application Administrator`, or
  - `Cloud Application Administrator`

Notes:

- Terraform creates Azure resources and also creates Key Vault role assignments, so plain `Contributor` is not enough on its own.
- Terraform writes generated client secrets into Azure Key Vault, so the deployment identity also needs `Key Vault Secrets Officer` on the target vault for data-plane secret management.
- Terraform creates app registrations, service principals, app roles, client secrets, and app role assignments in Microsoft Entra ID.
- By default, the identity running Terraform is also set as the Azure SQL Microsoft Entra administrator. If Terraform cannot resolve that identity automatically, set `sql_aad_admin_name` and `sql_aad_admin_object_id` in your local `*.auto.tfvars` file.
- If you plan to assign dashboard access to existing Entra groups, you need those groups' object IDs for `app_role_authorizations`.

## Terraform Deployment

This repo includes environment wrappers under [infra/terraform/environments](infra/terraform/environments). The checked-in `terraform.tfvars` files contain safe shared defaults such as the base app name and environment name. Put local-only overrides in an ignored `*.auto.tfvars` file.

### Set up an environment from scratch

If you want a brand-new environment wrapper, copy an existing one and then adjust its checked-in `terraform.tfvars`:

```bash
cp -R infra/terraform/environments/dev infra/terraform/environments/myenv
```

Then update `infra/terraform/environments/myenv/terraform.tfvars`:

```hcl
name        = "app01"
environment = "myenv"
```

If you only need the existing `dev` or `tst` wrappers, you can skip this copy step.

### Create the local auto tfvars file

Choose the wrapper you want to deploy, then create a local file named `<environment>.auto.tfvars` in that directory. For example:

- `infra/terraform/environments/dev/dev.auto.tfvars`
- `infra/terraform/environments/tst/tst.auto.tfvars`

Example `infra/terraform/environments/dev/dev.auto.tfvars`:

```hcl
# Add the public IPv4 address of the machine running terraform apply so the
# sqlcmd helper can create the managed-identity database user.
sql_firewall_allowed_ipv4_addresses = ["203.0.113.10"]

# Optional if Terraform cannot resolve the current identity automatically.
# sql_aad_admin_name      = "Ada Lovelace"
# sql_aad_admin_object_id = "00000000-0000-0000-0000-000000000000"

# Optional dashboard role assignments for existing Entra groups.
app_role_authorizations = {
  dashboard_read = {
    group_object_ids = ["00000000-0000-0000-0000-000000000001"]
  }
  dashboard_write = {
    group_object_ids = ["00000000-0000-0000-0000-000000000002"]
  }
}

# Optional tags.
tags = {
  environment = "dev"
}
```

The repo ignores `*.auto.tfvars`, so keep environment-specific values there instead of committing them.

### Deploy with Terraform

1. Sign in to Azure CLI and select the target subscription.

```bash
az login
az account set --subscription "<subscription-id-or-name>"
```

2. Change into the environment wrapper or use Terraform's `-chdir` flag.

```bash
terraform -chdir=infra/terraform/environments/dev init
terraform -chdir=infra/terraform/environments/dev apply
```

What Terraform does:

- Provisions the resource group, App Service plan, Linux web app, Azure SQL server and database, Key Vault, and Microsoft Entra app registrations
- Configures Easy Auth on the web app
- Creates the web app managed identity database user automatically through `sqlcmd`
- Writes a generated environment file at `infra/terraform/environments/<environment>/<environment>.env`

By default, the deployment uses the free-oriented settings from this repository:

- App Service plan SKU `F1`
- Azure SQL Database free-offer configuration

That generated `.env` file is used by:

- [scripts/deploy_app_only.sh](scripts/deploy_app_only.sh)
- [scripts/test_daemon_api.sh](scripts/test_daemon_api.sh)

After `terraform apply`, keep the generated `.env` file for later app deployments and API testing.

## App Deployment

Use the app deployment flow when the Azure resources already exist and you only want to push a new version of the Flask app.

### Set up the Python environment

```bash
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

### Deploy the app package

The deployment script uses the `.env` file generated by Terraform and deploys a ZIP package that contains `app.py`, `requirements.txt`, and `templates/`.

```bash
./scripts/deploy_app_only.sh ./infra/terraform/environments/dev/dev.env
```

You can also pass the file through `ENV_FILE`:

```bash
ENV_FILE=./infra/terraform/environments/dev/dev.env ./scripts/deploy_app_only.sh
```

Requirements for this step:

- Azure CLI must already be logged in
- The target web app must already exist
- The generated environment file must contain `RG` and `WEBAPP_NAME`

Optional variables:

- `PACKAGE_PATH` to override the ZIP output path
- `SKIP_BROWSE=true` to skip opening the site after deployment
- `AZURE_CONFIG_DIR` if you want the script to use a non-default Azure CLI profile

## Testing

### Run the unit tests locally

```bash
.venv/bin/python -m unittest discover -s tests -v
```

### Run the daemon API test script

The daemon test script uses the generated environment file from Terraform to request a client-credentials token and call `GET /api/logins`.

```bash
./scripts/test_daemon_api.sh ./infra/terraform/environments/dev/dev.env
```

You can also use:

```bash
ENV_FILE=./infra/terraform/environments/dev/dev.env ./scripts/test_daemon_api.sh
```

The script expects the generated `.env` file to provide:

- `TENANT_ID`
- `CLIENT_ID`
- `SCOPE`
- `TOKEN_URL`
- `API_URL`

For the daemon secret, use one of these options:

- Preferred: `KEY_VAULT_NAME` and `DAEMON_CLIENT_SECRET_NAME`
- Fallback: `CLIENT_SECRET`

The script:

- Waits for `healthz` to return HTTP 200 before calling the API
- Uses Azure CLI to read the daemon secret from Key Vault when Key Vault variables are present
- Prints the decoded access token payload
- Calls the deployed `GET /api/logins` endpoint and prints the JSON response

If your app needs longer to warm up, override the health-check settings such as `HEALTH_MAX_ATTEMPTS` or `HEALTH_RETRY_SECONDS` before running the script.
