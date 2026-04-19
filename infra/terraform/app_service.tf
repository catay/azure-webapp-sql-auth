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
    CLEAR_LOGINS_APP_ROLE                    = local.clear_logins_app_role
    DASHBOARD_READ_APP_ROLE                  = local.dashboard_read_app_role
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
    excluded_paths         = ["/healthz"]
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
