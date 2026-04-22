terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.8"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.67"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

provider "azuread" {}

provider "azapi" {}

module "app_stack" {
  source = "../../modules/app-stack"

  name        = var.name
  environment = var.environment

  location                                      = var.location
  sql_aad_admin_name                            = var.sql_aad_admin_name
  sql_aad_admin_object_id                       = var.sql_aad_admin_object_id
  create_webapp_managed_identity_db_user        = var.create_webapp_managed_identity_db_user
  sql_firewall_allowed_ipv4_addresses           = var.sql_firewall_allowed_ipv4_addresses
  webapp_managed_identity_db_user_name          = var.webapp_managed_identity_db_user_name
  webapp_managed_identity_db_user_use_object_id = var.webapp_managed_identity_db_user_use_object_id
  app_plan_sku                                  = var.app_plan_sku
  python_version                                = var.python_version
  sql_db_edition                                = var.sql_db_edition
  sql_db_family                                 = var.sql_db_family
  sql_db_capacity                               = var.sql_db_capacity
  sql_db_compute_model                          = var.sql_db_compute_model
  sql_db_auto_pause_delay                       = var.sql_db_auto_pause_delay
  sql_db_backup_redundancy                      = var.sql_db_backup_redundancy
  sql_db_free_limit_exhaustion_behavior         = var.sql_db_free_limit_exhaustion_behavior
  sql_db_max_size_gb                            = var.sql_db_max_size_gb
  sql_db_min_capacity                           = var.sql_db_min_capacity
  aad_app_name                                  = var.aad_app_name
  aad_app_redirect_uri                          = var.aad_app_redirect_uri
  aad_app_identifier_uri                        = var.aad_app_identifier_uri
  api_read_app_role                             = var.api_read_app_role
  dashboard_read_app_role                       = var.dashboard_read_app_role
  dashboard_read_group_object_id                = var.dashboard_read_group_object_id
  dashboard_write_app_role                      = var.dashboard_write_app_role
  dashboard_write_group_object_id               = var.dashboard_write_group_object_id
  create_daemon_client                          = var.create_daemon_client
  daemon_client_name                            = var.daemon_client_name
  daemon_client_secret_end_date_relative        = var.daemon_client_secret_end_date_relative
  flask_secret_key                              = var.flask_secret_key
  tags                                          = var.tags
}

resource "local_file" "deployment_env" {
  filename = "${path.module}/${var.environment}.env"
  content  = module.app_stack.scripts_deploy_env
}

output "env_file_path" {
  description = "Generated deployment environment file path."
  value       = local_file.deployment_env.filename
}

output "resource_group_name" {
  description = "Resource group name."
  value       = module.app_stack.resource_group_name
}

output "webapp_name" {
  description = "Web app name."
  value       = module.app_stack.webapp_name
}

output "webapp_url" {
  description = "Web app base URL."
  value       = module.app_stack.webapp_url
}

variable "name" {
  description = "Base application name used to derive Azure resource names."
  type        = string
}

variable "environment" {
  description = "Deployment environment name used to derive Azure resource names."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westeurope"
}

variable "sql_aad_admin_name" {
  description = "Optional override for the Microsoft Entra admin display name on the SQL server."
  type        = string
  default     = null
  nullable    = true
}

variable "sql_aad_admin_object_id" {
  description = "Optional override for the Microsoft Entra admin object ID on the SQL server."
  type        = string
  default     = null
  nullable    = true
}

variable "create_webapp_managed_identity_db_user" {
  description = "Whether Terraform should run a local helper to create the web app managed identity database user after provisioning."
  type        = bool
  default     = true
}

variable "sql_firewall_allowed_ipv4_addresses" {
  description = "Additional public IPv4 addresses allowed through the Azure SQL firewall."
  type        = list(string)
  default     = []
}

variable "webapp_managed_identity_db_user_name" {
  description = "Optional override for the contained database user name created for the web app managed identity."
  type        = string
  default     = null
  nullable    = true
}

variable "webapp_managed_identity_db_user_use_object_id" {
  description = "Whether the managed identity database user helper should use CREATE USER ... WITH OBJECT_ID."
  type        = bool
  default     = true
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
}

variable "sql_db_free_limit_exhaustion_behavior" {
  description = "Behavior when the monthly Azure SQL free limit is exhausted."
  type        = string
  default     = "AutoPause"
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
  description = "Optional override for the App Service API Application ID URI."
  type        = string
  default     = null
  nullable    = true
}

variable "api_read_app_role" {
  description = "Application role value required for daemon access to GET /api/logins."
  type        = string
  default     = "api_read"
}

variable "dashboard_read_app_role" {
  description = "User app role value required to view the dashboard and read login events."
  type        = string
  default     = "dashboard_read"
}

variable "dashboard_read_group_object_id" {
  description = "Optional object ID of an existing Microsoft Entra security group that should be assigned the dashboard-read user role."
  type        = string
  default     = null
  nullable    = true
}

variable "dashboard_write_app_role" {
  description = "User app role value required to clear dashboard login rows."
  type        = string
  default     = "dashboard_write"
}

variable "dashboard_write_group_object_id" {
  description = "Optional object ID of an existing Microsoft Entra security group that should be assigned the dashboard-write user role."
  type        = string
  default     = null
  nullable    = true
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
