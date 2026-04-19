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
