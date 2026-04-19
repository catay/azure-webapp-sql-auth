resource "random_uuid" "login_events_api_app_role" {}
resource "random_uuid" "clear_logins_app_role" {}

resource "azuread_application" "easy_auth" {
  display_name     = local.aad_app_name
  sign_in_audience = "AzureADMyOrg"

  required_resource_access {
    resource_app_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]

    resource_access {
      id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids["openid"]
      type = "Scope"
    }

    resource_access {
      id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids["profile"]
      type = "Scope"
    }

    resource_access {
      id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids["email"]
      type = "Scope"
    }
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Allows assigned users or groups to clear dashboard login rows."
    display_name         = "Clear Login Events"
    enabled              = true
    id                   = random_uuid.clear_logins_app_role.result
    value                = local.clear_logins_app_role
  }

  app_role {
    allowed_member_types = ["Application"]
    description          = "Allows daemon apps to read login events from the Flask API."
    display_name         = "Read Login Events"
    enabled              = true
    id                   = random_uuid.login_events_api_app_role.result
    value                = local.login_events_api_app_role
  }

  lifecycle {
    ignore_changes = [
      identifier_uris,
    ]
  }

  web {
    redirect_uris = [local.aad_app_redirect_uri]

    implicit_grant {
      id_token_issuance_enabled = true
    }
  }
}

resource "azuread_application_identifier_uri" "easy_auth" {
  application_id = azuread_application.easy_auth.id
  identifier_uri = local.aad_app_identifier_uri
}

resource "azuread_service_principal" "easy_auth" {
  client_id = azuread_application.easy_auth.client_id
}

resource "azuread_application_password" "easy_auth" {
  application_id = azuread_application.easy_auth.id
  display_name   = "App Service Easy Auth"
}

resource "azuread_application" "daemon_client" {
  count            = var.create_daemon_client ? 1 : 0
  display_name     = local.daemon_client_name
  sign_in_audience = "AzureADMyOrg"

  # When using azuread_application_api_access, required_resource_access should
  # be ignored to avoid provider churn.
  lifecycle {
    ignore_changes = [
      required_resource_access,
    ]
  }
}

resource "azuread_service_principal" "daemon_client" {
  count     = var.create_daemon_client ? 1 : 0
  client_id = azuread_application.daemon_client[0].client_id
}

resource "time_static" "daemon_client_secret_start" {
  count = var.create_daemon_client ? 1 : 0
}

resource "azuread_application_password" "daemon_client" {
  count          = var.create_daemon_client ? 1 : 0
  application_id = azuread_application.daemon_client[0].id
  display_name   = "Daemon Client Secret"
  end_date       = timeadd(time_static.daemon_client_secret_start[0].rfc3339, var.daemon_client_secret_end_date_relative)
}

resource "azuread_application_api_access" "daemon_client_login_events" {
  count          = var.create_daemon_client ? 1 : 0
  application_id = azuread_application.daemon_client[0].id
  api_client_id  = azuread_application.easy_auth.client_id
  role_ids = [
    azuread_application.easy_auth.app_role_ids[local.login_events_api_app_role],
  ]
}

resource "azuread_app_role_assignment" "daemon_client_login_events" {
  count               = var.create_daemon_client ? 1 : 0
  app_role_id         = azuread_application.easy_auth.app_role_ids[local.login_events_api_app_role]
  principal_object_id = azuread_service_principal.daemon_client[0].object_id
  resource_object_id  = azuread_service_principal.easy_auth.object_id
}

resource "azuread_app_role_assignment" "clear_logins_admin_group" {
  count               = var.clear_logins_admin_group_object_id != null ? 1 : 0
  app_role_id         = azuread_application.easy_auth.app_role_ids[local.clear_logins_app_role]
  principal_object_id = var.clear_logins_admin_group_object_id
  resource_object_id  = azuread_service_principal.easy_auth.object_id
}
