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

The module uses the repository defaults from `docs/spec.md`, including the current sample group assignments, App Service plan SKU, Python version, SQL configuration, and the optional SQL database access helper.

## SQL Database Access

The module configures database-level Microsoft Entra contained users only. Server-level logins and server role grants are intentionally out of scope.

The web app system-assigned managed identity is merged into the effective `sql_database_access` map by default and receives the roles required by the sample app. Additional users, groups, managed identities, or service principals can be configured through tfvars:

```hcl
sql_database_access = {
  app = {
    principals = {
      developers = {
        name      = "sg-app01-dev-sql-readers"
        object_id = "00000000-0000-0000-0000-000000000000"
        roles     = ["db_datareader"]
      }
    }
  }

  reporting = {
    name = "reporting-db"
    principals = {
      analysts = {
        name      = "sg-app01-reporting-readers"
        object_id = "11111111-1111-1111-1111-111111111111"
        roles     = ["db_datareader"]
      }
    }
  }
}
```

The `app` database entry defaults to the module-created database name. Additional database entries must set `name` explicitly.

## Outputs

The `scripts_deploy_env` output exposes shell-friendly environment variables that an environment wrapper can write to `<environment>.env` during `terraform apply`.
