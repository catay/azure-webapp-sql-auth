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
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

provider "azapi" {}

data "azurerm_client_config" "current" {}

locals {
  aad_app_name               = coalesce(var.aad_app_name, "app-${var.webapp_name}")
  aad_app_redirect_uri       = coalesce(var.aad_app_redirect_uri, "https://${var.webapp_name}.azurewebsites.net/.auth/login/aad/callback")
  flask_secret_key           = coalesce(var.flask_secret_key, random_password.flask_secret_key.result)
  sql_sku_name               = "GP_S_${var.sql_db_family}_${var.sql_db_capacity}"
  app_service_always_on_skus = ["FREE", "F1", "D1"]
  app_service_always_on      = !contains(local.app_service_always_on_skus, upper(var.app_plan_sku))

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

  web {
    redirect_uris = [local.aad_app_redirect_uri]

    implicit_grant {
      id_token_issuance_enabled = true
    }
  }
}

resource "azuread_service_principal" "easy_auth" {
  client_id = azuread_application.easy_auth.client_id
}

resource "azuread_application_password" "easy_auth" {
  application_id = azuread_application.easy_auth.id
  display_name   = "App Service Easy Auth"
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
    MICROSOFT_PROVIDER_AUTHENTICATION_SECRET = azuread_application_password.easy_auth.value
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
    }

    login {
      token_store_enabled = true
    }
  }
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
