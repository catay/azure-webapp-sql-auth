output "resource_group_name" {
  description = "Resource group name."
  value       = azurerm_resource_group.main.name
}

output "webapp_name" {
  description = "Web app name."
  value       = azurerm_linux_web_app.main.name
}

output "webapp_url" {
  description = "Web app base URL."
  value       = "https://${azurerm_linux_web_app.main.default_hostname}"
}

output "webapp_managed_identity_principal_id" {
  description = "System-assigned managed identity principal ID for the web app."
  value       = azurerm_linux_web_app.main.identity[0].principal_id
}

output "key_vault_name" {
  description = "Azure Key Vault name that stores generated app registration secrets."
  value       = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  description = "Azure Key Vault URI."
  value       = azurerm_key_vault.main.vault_uri
}

output "sql_server_fqdn" {
  description = "Fully qualified Azure SQL server hostname."
  value       = azurerm_mssql_server.main.fully_qualified_domain_name
}

output "sql_database_name" {
  description = "Azure SQL database name."
  value       = azapi_resource.sql_database.name
}

output "easy_auth_client_id" {
  description = "Client ID of the Microsoft Entra app registration used by Easy Auth."
  value       = azuread_application.easy_auth.client_id
}

output "easy_auth_application_id_uri" {
  description = "Application ID URI exposed by the App Service app registration."
  value       = azuread_application_identifier_uri.easy_auth.identifier_uri
}

output "login_events_api_app_role" {
  description = "Application role required for daemon access to GET /api/logins."
  value       = var.login_events_api_app_role
}

output "daemon_client_id" {
  description = "Client ID of the generated daemon application registration, if enabled."
  value       = var.create_daemon_client ? azuread_application.daemon_client[0].client_id : null
}

output "daemon_client_object_id" {
  description = "Object ID of the daemon service principal, if enabled."
  value       = var.create_daemon_client ? azuread_service_principal.daemon_client[0].object_id : null
}

output "easy_auth_client_secret_name" {
  description = "Key Vault secret name that stores the Easy Auth app registration client secret."
  value       = azurerm_key_vault_secret.easy_auth.name
}

output "easy_auth_client_secret_versionless_id" {
  description = "Versionless Key Vault secret ID for the Easy Auth app registration client secret."
  value       = azurerm_key_vault_secret.easy_auth.versionless_id
}

output "daemon_client_secret_name" {
  description = "Key Vault secret name for the generated daemon application registration secret, if enabled."
  value       = var.create_daemon_client ? azurerm_key_vault_secret.daemon_client[0].name : null
}

output "daemon_client_secret_versionless_id" {
  description = "Versionless Key Vault secret ID for the generated daemon application registration secret, if enabled."
  value       = var.create_daemon_client ? azurerm_key_vault_secret.daemon_client[0].versionless_id : null
}

output "post_provision_sql" {
  description = "Run this SQL against the target database as the configured Microsoft Entra admin."
  value       = <<-EOT
    CREATE USER [${azurerm_linux_web_app.main.name}] FROM EXTERNAL PROVIDER;
    ALTER ROLE db_datareader ADD MEMBER [${azurerm_linux_web_app.main.name}];
    ALTER ROLE db_datawriter ADD MEMBER [${azurerm_linux_web_app.main.name}];
    ALTER ROLE db_ddladmin ADD MEMBER [${azurerm_linux_web_app.main.name}];
  EOT
}

output "daemon_token_request_example" {
  description = "Example client-credentials token request inputs for the generated daemon app."
  value = var.create_daemon_client ? {
    tenant_id = data.azurerm_client_config.current.tenant_id
    token_url = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/oauth2/v2.0/token"
    scope     = "${azuread_application_identifier_uri.easy_auth.identifier_uri}/.default"
  } : null
}

output "scripts_deploy_env" {
  description = "Copy this into scripts/deploy.env for deploy_app_only.sh and test_daemon_api.sh."
  value       = <<-EOT
    RG="${azurerm_resource_group.main.name}"
    WEBAPP_NAME="${azurerm_linux_web_app.main.name}"

    # Optional for scripts/deploy_app_only.sh
    # PACKAGE_PATH="/tmp/${azurerm_linux_web_app.main.name}.zip"
    # SKIP_BROWSE="false"

    # Inputs for scripts/test_daemon_api.sh
    TENANT_ID="${data.azurerm_client_config.current.tenant_id}"
    CLIENT_ID="${try(azuread_application.daemon_client[0].client_id, "")}"
    KEY_VAULT_NAME="${azurerm_key_vault.main.name}"
    DAEMON_CLIENT_SECRET_NAME="${try(azurerm_key_vault_secret.daemon_client[0].name, "")}"
    SCOPE="${azuread_application_identifier_uri.easy_auth.identifier_uri}/.default"
    TOKEN_URL="https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/oauth2/v2.0/token"
    API_URL="https://${azurerm_linux_web_app.main.default_hostname}/api/logins"

    # Optional alternative to Key Vault lookup:
    # CLIENT_SECRET=""
  EOT
}
