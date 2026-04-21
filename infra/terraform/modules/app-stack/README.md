# App Stack Module

This module packages the Azure infrastructure for the sample application into a reusable Terraform module.

The module derives Azure resource names from two required inputs:

- `name`
- `environment`

All Azure resource names use a shared random suffix so one deployment is easy to identify as a single stack.

## Usage

```hcl
module "app_stack" {
  source = "../../modules/app-stack"

  name        = "flask-sql-auth"
  environment = "dev"
}
```

## Generated Names

The module derives these resource names automatically:

- Resource group: `rg-<name>-<environment>-<random>`
- App Service plan: `plan-<name>-<environment>-<random>`
- Web app: `app-<name>-<environment>-<random>`
- SQL server: `sql-<name>-<environment>-<random>`
- SQL database: `db-<name>-<environment>-<random>`
- Key Vault: `kv-<name>-<environment>-<random>` with a compact form to stay within Azure Key Vault length limits

## Defaults

The module uses the repository defaults from `docs/reorg.md`, including the current sample group assignments, App Service plan SKU, Python version, SQL configuration, and the optional managed-identity database-user helper.

## Outputs

The `scripts_deploy_env` output exposes shell-friendly environment variables that an environment wrapper can write to `<environment>.env` during `terraform apply`.
