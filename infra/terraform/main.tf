terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.8"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.67"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

provider "azapi" {}

data "azurerm_client_config" "current" {}

locals {
  aad_app_name                  = coalesce(var.aad_app_name, "app-${var.webapp_name}")
  aad_app_redirect_uri          = coalesce(var.aad_app_redirect_uri, "https://${var.webapp_name}.azurewebsites.net/.auth/login/aad/callback")
  aad_app_identifier_uri        = coalesce(var.aad_app_identifier_uri, "api://${azuread_application.easy_auth.client_id}")
  daemon_client_name            = coalesce(var.daemon_client_name, "${var.webapp_name}-daemon")
  key_vault_name                = coalesce(var.key_vault_name, substr("kv${replace(var.webapp_name, "-", "")}${random_string.key_vault_suffix.result}", 0, 24))
  easy_auth_secret_name         = "easy-auth-client-secret"
  daemon_client_secret_name     = "daemon-client-secret"
  flask_secret_key              = coalesce(var.flask_secret_key, random_password.flask_secret_key.result)
  login_events_api_app_role     = var.login_events_api_app_role
  sql_sku_name                  = "GP_S_${var.sql_db_family}"
  managed_identity_db_user_name = coalesce(var.webapp_managed_identity_db_user_name, azurerm_linux_web_app.main.name)
  app_service_always_on_skus    = ["FREE", "F1", "D1"]
  app_service_always_on         = !contains(local.app_service_always_on_skus, upper(var.app_plan_sku))

  default_tags = {
    managed_by  = "terraform"
    application = var.webapp_name
  }

  tags = merge(local.default_tags, var.tags)
}

resource "random_password" "flask_secret_key" {
  length  = 64
  special = false
}

resource "random_string" "key_vault_suffix" {
  length  = 5
  lower   = true
  numeric = true
  special = false
  upper   = false
}

resource "azurerm_resource_group" "main" {
  name     = var.rg
  location = var.location
  tags     = local.tags
}

resource "azurerm_service_plan" "main" {
  name                = var.app_plan
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = var.app_plan_sku
  tags                = local.tags
}

resource "azuread_application" "easy_auth" {
  display_name     = local.aad_app_name
  sign_in_audience = "AzureADMyOrg"

  app_role {
    allowed_member_types = ["Application"]
    description          = "Allows daemon apps to read login events from the Flask API."
    display_name         = "Read Login Events"
    enabled              = true
    id                   = random_uuid.login_events_api_app_role.result
    value                = local.login_events_api_app_role
  }

  lifecycle {
    ignore_changes = [
      identifier_uris,
    ]
  }

  web {
    redirect_uris = [local.aad_app_redirect_uri]

    implicit_grant {
      id_token_issuance_enabled = true
    }
  }
}

resource "azuread_application_identifier_uri" "easy_auth" {
  application_id = azuread_application.easy_auth.id
  identifier_uri = local.aad_app_identifier_uri
}

resource "azuread_service_principal" "easy_auth" {
  client_id = azuread_application.easy_auth.client_id
}

resource "azuread_application_password" "easy_auth" {
  application_id = azuread_application.easy_auth.id
  display_name   = "App Service Easy Auth"
}

resource "random_uuid" "login_events_api_app_role" {}

resource "azuread_application" "daemon_client" {
  count            = var.create_daemon_client ? 1 : 0
  display_name     = local.daemon_client_name
  sign_in_audience = "AzureADMyOrg"

  # when using azuread_application_api_access, required_resource_access should be ignored.
  # https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/application_api_access

  lifecycle {
    ignore_changes = [
      required_resource_access,
    ]
  }
}

resource "azuread_service_principal" "daemon_client" {
  count     = var.create_daemon_client ? 1 : 0
  client_id = azuread_application.daemon_client[0].client_id
}

resource "time_static" "daemon_client_secret_start" {
  count = var.create_daemon_client ? 1 : 0
}

resource "azuread_application_password" "daemon_client" {
  count          = var.create_daemon_client ? 1 : 0
  application_id = azuread_application.daemon_client[0].id
  display_name   = "Daemon Client Secret"
  end_date       = timeadd(time_static.daemon_client_secret_start[0].rfc3339, var.daemon_client_secret_end_date_relative)
}

resource "azuread_application_api_access" "daemon_client_login_events" {
  count          = var.create_daemon_client ? 1 : 0
  application_id = azuread_application.daemon_client[0].id
  api_client_id  = azuread_application.easy_auth.client_id
  role_ids = [
    azuread_application.easy_auth.app_role_ids[local.login_events_api_app_role],
  ]
}

resource "azuread_app_role_assignment" "daemon_client_login_events" {
  count               = var.create_daemon_client ? 1 : 0
  app_role_id         = azuread_application.easy_auth.app_role_ids[local.login_events_api_app_role]
  principal_object_id = azuread_service_principal.daemon_client[0].object_id
  resource_object_id  = azuread_service_principal.easy_auth.object_id
}

resource "azurerm_linux_web_app" "main" {
  name                = var.webapp_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on           = local.app_service_always_on
    minimum_tls_version = "1.2"

    application_stack {
      python_version = var.python_version
    }
  }

  app_settings = {
    FLASK_SECRET_KEY                         = local.flask_secret_key
    LOGIN_EVENTS_API_APP_ROLE                = local.login_events_api_app_role
    MICROSOFT_PROVIDER_AUTHENTICATION_SECRET = "@Microsoft.KeyVault(VaultName=${local.key_vault_name};SecretName=${local.easy_auth_secret_name})"
    SCM_DO_BUILD_DURING_DEPLOYMENT           = "true"
    SQL_DATABASE_NAME                        = var.sql_db_name
    SQL_SERVER_NAME                          = azurerm_mssql_server.main.fully_qualified_domain_name
  }

  auth_settings_v2 {
    auth_enabled           = true
    default_provider       = "azureactivedirectory"
    require_authentication = true
    require_https          = true
    unauthenticated_action = "RedirectToLoginPage"

    active_directory_v2 {
      client_id                  = azuread_application.easy_auth.client_id
      client_secret_setting_name = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
      tenant_auth_endpoint       = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"
      allowed_audiences = [
        azuread_application.easy_auth.client_id,
        azuread_application_identifier_uri.easy_auth.identifier_uri,
      ]
    }

    login {
      token_store_enabled = true
    }
  }
}

resource "azurerm_key_vault" "main" {
  name                            = local.key_vault_name
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  sku_name                        = "standard"
  soft_delete_retention_days      = 7
  purge_protection_enabled        = false
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = false
  tags                            = local.tags

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "Delete",
      "Get",
      "List",
      "Purge",
      "Recover",
      "Set",
    ]
  }

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = azurerm_linux_web_app.main.identity[0].principal_id

    secret_permissions = [
      "Get",
      "List",
    ]
  }
}

resource "azurerm_key_vault_secret" "easy_auth" {
  name         = local.easy_auth_secret_name
  value        = azuread_application_password.easy_auth.value
  key_vault_id = azurerm_key_vault.main.id
  content_type = "Microsoft Entra app registration client secret"

  depends_on = [
    azurerm_key_vault.main,
  ]
}

resource "azurerm_key_vault_secret" "daemon_client" {
  count        = var.create_daemon_client ? 1 : 0
  name         = local.daemon_client_secret_name
  value        = azuread_application_password.daemon_client[0].value
  key_vault_id = azurerm_key_vault.main.id
  content_type = "Microsoft Entra daemon client secret"

  depends_on = [
    azurerm_key_vault.main,
  ]
}

resource "azapi_resource_action" "refresh_key_vault_references" {
  type        = "Microsoft.Web/sites@2022-03-01"
  resource_id = azurerm_linux_web_app.main.id
  action      = "config/configreferences/appsettings/refresh"
  method      = "POST"

  depends_on = [
    azurerm_key_vault_secret.easy_auth,
    azurerm_key_vault_secret.daemon_client,
  ]
}

resource "azurerm_mssql_server" "main" {
  name                          = var.sql_server_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  tags                          = local.tags

  azuread_administrator {
    azuread_authentication_only = true
    login_username              = var.sql_aad_admin_name
    object_id                   = var.sql_aad_admin_object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
  }
}

resource "azapi_resource" "sql_database" {
  type      = "Microsoft.Sql/servers/databases@2023-08-01"
  name      = var.sql_db_name
  parent_id = azurerm_mssql_server.main.id
  location  = azurerm_resource_group.main.location
  tags      = local.tags

  body = {
    sku = {
      name     = local.sql_sku_name
      tier     = var.sql_db_edition
      family   = var.sql_db_family
      capacity = var.sql_db_capacity
    }
    properties = merge(
      {
        autoPauseDelay                   = var.sql_db_auto_pause_delay
        freeLimitExhaustionBehavior      = var.sql_db_free_limit_exhaustion_behavior
        maxSizeBytes                     = var.sql_db_max_size_gb * 1073741824
        requestedBackupStorageRedundancy = var.sql_db_backup_redundancy
        useFreeLimit                     = true
      },
      var.sql_db_min_capacity == null ? {} : {
        minCapacity = var.sql_db_min_capacity
      }
    )
  }
}

resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "terraform_data" "webapp_managed_identity_db_user" {
  count = var.create_webapp_managed_identity_db_user ? 1 : 0

  triggers_replace = {
    sql_server_fqdn = azurerm_mssql_server.main.fully_qualified_domain_name
    sql_database    = azapi_resource.sql_database.name
    principal_id    = azurerm_linux_web_app.main.identity[0].principal_id
    db_user_name    = local.managed_identity_db_user_name
    use_object_id   = tostring(var.webapp_managed_identity_db_user_use_object_id)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/../../scripts/create_webapp_managed_identity_db_user.sh"
    environment = {
      SQL_SERVER_FQDN            = azurerm_mssql_server.main.fully_qualified_domain_name
      SQL_DATABASE_NAME          = azapi_resource.sql_database.name
      DB_USER_NAME               = local.managed_identity_db_user_name
      MANAGED_IDENTITY_OBJECT_ID = azurerm_linux_web_app.main.identity[0].principal_id
      USE_OBJECT_ID              = tostring(var.webapp_managed_identity_db_user_use_object_id)
    }
  }

  depends_on = [
    azurerm_linux_web_app.main,
    azurerm_mssql_server.main,
    azapi_resource.sql_database,
    azurerm_mssql_firewall_rule.allow_azure_services,
  ]
}
