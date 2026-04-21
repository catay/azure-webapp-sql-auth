data "azurerm_client_config" "current" {}

data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "msgraph" {
  client_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
}

data "azuread_users" "current_sql_admin" {
  count = var.sql_aad_admin_name == null ? 1 : 0

  object_ids     = [data.azurerm_client_config.current.object_id]
  ignore_missing = true
}

data "azuread_service_principals" "current_sql_admin" {
  count = var.sql_aad_admin_name == null ? 1 : 0

  object_ids     = [data.azurerm_client_config.current.object_id]
  ignore_missing = true
}
