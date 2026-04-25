resource "azurerm_mssql_server" "main" {
  name                          = local.sql_server_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  tags                          = local.tags

  lifecycle {
    precondition {
      condition     = local.sql_aad_admin_name != null
      error_message = "Unable to resolve the SQL Microsoft Entra admin display name from the current Terraform identity. Set sql_aad_admin_name explicitly or authenticate with an identity that the AzureAD provider can read."
    }
  }

  azuread_administrator {
    azuread_authentication_only = true
    login_username              = local.sql_aad_admin_name
    object_id                   = local.sql_aad_admin_object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
  }
}

resource "azapi_resource" "sql_database" {
  type      = "Microsoft.Sql/servers/databases@2023-08-01"
  name      = local.sql_db_name
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

resource "azurerm_mssql_firewall_rule" "terraform_clients" {
  for_each = toset(var.sql_firewall_allowed_ipv4_addresses)

  name             = "AllowClient-${replace(each.value, ".", "-")}"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = each.value
  end_ip_address   = each.value
}

resource "terraform_data" "sql_database_access" {
  count = length(local.sql_database_access_principal_keys) > 0 ? 1 : 0

  triggers_replace = {
    sql_server_fqdn          = azurerm_mssql_server.main.fully_qualified_domain_name
    sql_database_access_json = jsonencode(local.sql_database_access)
  }

  provisioner "local-exec" {
    command = "python3 ${abspath("${path.module}/scripts/configure_sql_database_access.py")}"
    environment = {
      SQL_SERVER_FQDN          = azurerm_mssql_server.main.fully_qualified_domain_name
      SQL_DATABASE_ACCESS_JSON = jsonencode(local.sql_database_access)
    }
  }

  depends_on = [
    azurerm_linux_web_app.main,
    azurerm_mssql_server.main,
    azapi_resource.sql_database,
    azurerm_mssql_firewall_rule.allow_azure_services,
    azurerm_mssql_firewall_rule.terraform_clients,
  ]
}
