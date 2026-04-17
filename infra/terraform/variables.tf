variable "rg" {
  description = "Resource group name."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
}

variable "app_plan" {
  description = "App Service plan name."
  type        = string
}

variable "webapp_name" {
  description = "Linux App Service name."
  type        = string
}

variable "sql_server_name" {
  description = "Azure SQL logical server name."
  type        = string
}

variable "sql_db_name" {
  description = "Azure SQL database name."
  type        = string
}

variable "sql_aad_admin_name" {
  description = "Display name of the Microsoft Entra admin for the SQL server."
  type        = string
}

variable "sql_aad_admin_object_id" {
  description = "Object ID of the Microsoft Entra admin for the SQL server."
  type        = string
}

variable "app_plan_sku" {
  description = "App Service plan SKU."
  type        = string
  default     = "F1"
}

variable "python_version" {
  description = "Python version for the Linux web app application stack."
  type        = string
  default     = "3.12"
}

variable "sql_db_edition" {
  description = "Logical edition input kept to mirror the deployment spec."
  type        = string
  default     = "GeneralPurpose"

  validation {
    condition     = var.sql_db_edition == "GeneralPurpose"
    error_message = "This Terraform translation only supports the GeneralPurpose SQL database edition from the current spec."
  }
}

variable "sql_db_family" {
  description = "Compute family for the Azure SQL database SKU."
  type        = string
  default     = "Gen5"
}

variable "sql_db_capacity" {
  description = "vCore capacity for the Azure SQL database SKU."
  type        = number
  default     = 2
}

variable "sql_db_compute_model" {
  description = "Logical compute model input kept to mirror the deployment spec."
  type        = string
  default     = "Serverless"

  validation {
    condition     = var.sql_db_compute_model == "Serverless"
    error_message = "This Terraform translation only supports the Serverless compute model from the current spec."
  }
}

variable "sql_db_auto_pause_delay" {
  description = "Auto-pause delay in minutes for the serverless SQL database."
  type        = number
  default     = 60
}

variable "sql_db_backup_redundancy" {
  description = "Backup storage redundancy for the SQL database."
  type        = string
  default     = "Local"

  validation {
    condition     = contains(["Geo", "GeoZone", "Local", "Zone"], var.sql_db_backup_redundancy)
    error_message = "sql_db_backup_redundancy must be one of Geo, GeoZone, Local, or Zone."
  }
}

variable "sql_db_free_limit_exhaustion_behavior" {
  description = "Behavior when the monthly Azure SQL free limit is exhausted."
  type        = string
  default     = "AutoPause"

  validation {
    condition     = contains(["AutoPause", "BillOverUsage"], var.sql_db_free_limit_exhaustion_behavior)
    error_message = "sql_db_free_limit_exhaustion_behavior must be AutoPause or BillOverUsage."
  }
}

variable "sql_db_max_size_gb" {
  description = "Maximum size in GB for the Azure SQL database."
  type        = number
  default     = 32
}

variable "sql_db_min_capacity" {
  description = "Minimum vCore capacity for the serverless SQL database. Leave null to use the platform default."
  type        = number
  default     = null
  nullable    = true
}

variable "aad_app_name" {
  description = "Optional override for the Microsoft Entra app registration display name."
  type        = string
  default     = null
  nullable    = true
}

variable "aad_app_redirect_uri" {
  description = "Optional override for the Easy Auth redirect URI."
  type        = string
  default     = null
  nullable    = true
}

variable "aad_app_identifier_uri" {
  description = "Optional override for the App Service API Application ID URI. Defaults to api://<easy-auth-client-id>."
  type        = string
  default     = null
  nullable    = true
}

variable "login_events_api_app_role" {
  description = "Application role value required for daemon access to GET /api/logins."
  type        = string
  default     = "read_login_events"
}

variable "create_daemon_client" {
  description = "Whether Terraform should create a daemon client app registration and grant it application permission to the web app API."
  type        = bool
  default     = true
}

variable "daemon_client_name" {
  description = "Optional override for the daemon client application display name."
  type        = string
  default     = null
  nullable    = true
}

variable "daemon_client_secret_end_date_relative" {
  description = "Relative lifetime for the generated daemon client secret."
  type        = string
  default     = "2160h"
}

variable "flask_secret_key" {
  description = "Optional Flask secret key. If null, Terraform generates one."
  type        = string
  default     = null
  nullable    = true
  sensitive   = true
}

variable "tags" {
  description = "Additional tags applied to Azure resources."
  type        = map(string)
  default     = {}
}
