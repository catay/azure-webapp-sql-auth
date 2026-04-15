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

output "post_provision_sql" {
  description = "Run this SQL against the target database as the configured Microsoft Entra admin."
  value       = <<-EOT
    CREATE USER [${azurerm_linux_web_app.main.name}] FROM EXTERNAL PROVIDER;
    ALTER ROLE db_datareader ADD MEMBER [${azurerm_linux_web_app.main.name}];
    ALTER ROLE db_datawriter ADD MEMBER [${azurerm_linux_web_app.main.name}];
    ALTER ROLE db_ddladmin ADD MEMBER [${azurerm_linux_web_app.main.name}];
  EOT
}
