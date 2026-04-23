locals {
  sanitized_name        = trim(replace(lower(var.name), "/[^a-z0-9-]/", "-"), "-")
  sanitized_environment = trim(replace(lower(var.environment), "/[^a-z0-9-]/", "-"), "-")
  compact_name          = substr(replace(local.sanitized_name, "-", ""), 0, 8)
  compact_environment   = substr(replace(local.sanitized_environment, "-", ""), 0, 4)
  stack_suffix          = lower(random_id.stack.hex)

  resource_group_name = "rg-${local.sanitized_name}-${local.sanitized_environment}-${local.stack_suffix}"
  app_plan_name       = "plan-${local.sanitized_name}-${local.sanitized_environment}-${local.stack_suffix}"
  webapp_name         = "app-${local.sanitized_name}-${local.sanitized_environment}-${local.stack_suffix}"
  sql_server_name     = "sql-${local.sanitized_name}-${local.sanitized_environment}-${local.stack_suffix}"
  sql_db_name         = "db-${local.sanitized_name}-${local.sanitized_environment}-${local.stack_suffix}"
  key_vault_name      = "kv-${local.compact_name}-${local.compact_environment}-${local.stack_suffix}"

  aad_app_name              = coalesce(var.aad_app_name, local.webapp_name)
  aad_app_redirect_uri      = coalesce(var.aad_app_redirect_uri, "https://${local.webapp_name}.azurewebsites.net/.auth/login/aad/callback")
  aad_app_identifier_uri    = coalesce(var.aad_app_identifier_uri, "api://${azuread_application.easy_auth.client_id}")
  daemon_client_name        = coalesce(var.daemon_client_name, "${local.webapp_name}-daemon")
  easy_auth_secret_name     = "easy-auth-client-secret"
  daemon_client_secret_name = "daemon-client-secret"
  flask_secret_key          = coalesce(var.flask_secret_key, random_password.flask_secret_key.result)
  dashboard_read_app_role   = "dashboard_read"
  dashboard_write_app_role  = "dashboard_write"
  api_read_app_role         = "api_read"
  app_role_authorizations = merge({
    dashboard_read = {
      group_object_ids = []
    }
    dashboard_write = {
      group_object_ids = []
    }
  }, var.app_role_authorizations)
  dashboard_read_group_object_ids  = local.app_role_authorizations.dashboard_read.group_object_ids
  dashboard_write_group_object_ids = local.app_role_authorizations.dashboard_write.group_object_ids
  sql_sku_name                     = "GP_S_${var.sql_db_family}"
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
    application = local.webapp_name
    environment = var.environment
    stack       = var.name
  }

  tags = merge(local.default_tags, var.tags)
}
