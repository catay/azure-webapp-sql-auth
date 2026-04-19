resource "azurerm_key_vault" "main" {
  name                            = local.key_vault_name
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  rbac_authorization_enabled      = true
  sku_name                        = "standard"
  soft_delete_retention_days      = 7
  purge_protection_enabled        = false
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = false
  tags                            = local.tags
}

resource "azurerm_role_assignment" "key_vault_secrets_officer_current" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "key_vault_secrets_user_webapp" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.main.identity[0].principal_id
}

resource "time_sleep" "wait_for_key_vault_rbac" {
  create_duration = "60s"

  depends_on = [
    azurerm_role_assignment.key_vault_secrets_officer_current,
    azurerm_role_assignment.key_vault_secrets_user_webapp,
  ]
}

resource "azurerm_key_vault_secret" "easy_auth" {
  name         = local.easy_auth_secret_name
  value        = azuread_application_password.easy_auth.value
  key_vault_id = azurerm_key_vault.main.id
  content_type = "Microsoft Entra app registration client secret"

  depends_on = [
    time_sleep.wait_for_key_vault_rbac,
  ]
}

resource "azurerm_key_vault_secret" "daemon_client" {
  count        = var.create_daemon_client ? 1 : 0
  name         = local.daemon_client_secret_name
  value        = azuread_application_password.daemon_client[0].value
  key_vault_id = azurerm_key_vault.main.id
  content_type = "Microsoft Entra daemon client secret"

  depends_on = [
    time_sleep.wait_for_key_vault_rbac,
  ]
}
