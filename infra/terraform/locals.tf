locals {
  aad_app_name              = coalesce(var.aad_app_name, "app-${var.webapp_name}")
  aad_app_redirect_uri      = coalesce(var.aad_app_redirect_uri, "https://${var.webapp_name}.azurewebsites.net/.auth/login/aad/callback")
  aad_app_identifier_uri    = coalesce(var.aad_app_identifier_uri, "api://${azuread_application.easy_auth.client_id}")
  daemon_client_name        = coalesce(var.daemon_client_name, "${var.webapp_name}-daemon")
  key_vault_name            = coalesce(var.key_vault_name, substr("kv${replace(var.webapp_name, "-", "")}${random_string.key_vault_suffix.result}", 0, 24))
  easy_auth_secret_name     = "easy-auth-client-secret"
  daemon_client_secret_name = "daemon-client-secret"
  flask_secret_key          = coalesce(var.flask_secret_key, random_password.flask_secret_key.result)
  dashboard_read_app_role   = var.dashboard_read_app_role
  clear_logins_app_role     = var.clear_logins_app_role
  login_events_api_app_role = var.login_events_api_app_role
  sql_sku_name              = "GP_S_${var.sql_db_family}"
  sql_aad_admin_name = coalesce(
    var.sql_aad_admin_name,
    try(data.azuread_users.current_sql_admin[0].users[0].display_name, null),
    try(data.azuread_service_principals.current_sql_admin[0].service_principals[0].display_name, null),
  )
  sql_aad_admin_object_id       = coalesce(var.sql_aad_admin_object_id, data.azurerm_client_config.current.object_id)
  managed_identity_db_user_name = coalesce(var.webapp_managed_identity_db_user_name, azurerm_linux_web_app.main.name)
  app_service_always_on_skus    = ["FREE", "F1", "D1"]
  app_service_always_on         = !contains(local.app_service_always_on_skus, upper(var.app_plan_sku))

  default_tags = {
    managed_by  = "terraform"
    application = var.webapp_name
  }

  tags = merge(local.default_tags, var.tags)
}
