terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

variable "sql_connection_string" {
  description = "Azure SQL connection string used by CatalogConnection and IdentityConnection. Do not commit the real value; pass it through terraform.tfvars or -var."
  type        = string
  sensitive   = true
}

locals {
  prefix  = "eshop"
  rg_name = "rg-eshop"
  api_url = "https://${azurerm_windows_web_app.publicapi.default_hostname}"

  db_connection_key_vault_reference = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.db_connection_string.versionless_id})"

  common_app_settings = {
    "UseOnlyInMemoryDatabase"           = "false"
    "ASPNETCORE_ENVIRONMENT"           = "Development"
    "SCM_DO_BUILD_DURING_DEPLOYMENT"   = "false"
    "ConnectionStrings__CatalogConnection"  = local.db_connection_key_vault_reference
    "ConnectionStrings__IdentityConnection" = local.db_connection_key_vault_reference
  }
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "azurerm_resource_group" "rg" {
  name     = local.rg_name
  location = "West Europe"
}

# App Service Plans
resource "azurerm_service_plan" "west" {
  name                = "asp-eshop-west"
  resource_group_name = azurerm_resource_group.rg.name
  location            = "West Europe"
  os_type             = "Windows"
  sku_name            = "S1"
}

resource "azurerm_service_plan" "central" {
  name                = "asp-eshop-central"
  resource_group_name = azurerm_resource_group.rg.name
  location            = "France Central"
  os_type             = "Windows"
  sku_name            = "B1"
}

# Key Vault for SQL connection string
resource "azurerm_key_vault" "sql" {
  name                = "eshop-sql-kv-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization = true
}

resource "azurerm_role_assignment" "current_user_key_vault_secrets_officer" {
  scope                = azurerm_key_vault.sql.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "db_connection_string" {
  name         = "DbConnectionString"
  value        = var.sql_connection_string
  key_vault_id = azurerm_key_vault.sql.id

  depends_on = [
    azurerm_role_assignment.current_user_key_vault_secrets_officer
  ]
}

# Public API
resource "azurerm_windows_web_app" "publicapi" {
  name                = "eshop-publicapi-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.west.location
  service_plan_id     = azurerm_service_plan.west.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      current_stack  = "dotnet"
      dotnet_version = "v8.0"
    }
  }

  app_settings = local.common_app_settings
}

# Web app - West Europe
resource "azurerm_windows_web_app" "web_west" {
  name                = "eshop-web-west-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.west.location
  service_plan_id     = azurerm_service_plan.west.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      current_stack  = "dotnet"
      dotnet_version = "v8.0"
    }
  }

  app_settings = merge(local.common_app_settings, {
    "baseUrls__apiBase" = local.api_url
  })
}

# Web app - France Central
resource "azurerm_windows_web_app" "web_central" {
  name                = "eshop-web-central-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.central.location
  service_plan_id     = azurerm_service_plan.central.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      current_stack  = "dotnet"
      dotnet_version = "v8.0"
    }
  }

  app_settings = merge(local.common_app_settings, {
    "baseUrls__apiBase" = local.api_url
  })
}

# Deployment slot for Web West
resource "azurerm_windows_web_app_slot" "web_west_staging" {
  name           = "staging"
  app_service_id = azurerm_windows_web_app.web_west.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      current_stack  = "dotnet"
      dotnet_version = "v8.0"
    }
  }

  app_settings = merge(local.common_app_settings, {
    "baseUrls__apiBase" = local.api_url
  })
}

# Allow App Service managed identities to read the SQL connection string secret.
resource "azurerm_role_assignment" "publicapi_key_vault_secrets_user" {
  scope                = azurerm_key_vault.sql.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_windows_web_app.publicapi.identity[0].principal_id
}

resource "azurerm_role_assignment" "web_west_key_vault_secrets_user" {
  scope                = azurerm_key_vault.sql.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_windows_web_app.web_west.identity[0].principal_id
}

resource "azurerm_role_assignment" "web_central_key_vault_secrets_user" {
  scope                = azurerm_key_vault.sql.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_windows_web_app.web_central.identity[0].principal_id
}

resource "azurerm_role_assignment" "web_west_staging_key_vault_secrets_user" {
  scope                = azurerm_key_vault.sql.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_windows_web_app_slot.web_west_staging.identity[0].principal_id
}

# Traffic Manager
resource "azurerm_traffic_manager_profile" "tm" {
  name                   = "eshop-tm-${random_string.suffix.result}"
  resource_group_name    = azurerm_resource_group.rg.name
  traffic_routing_method = "Performance"

  dns_config {
    relative_name = "eshop-tm-${random_string.suffix.result}"
    ttl           = 30
  }

  monitor_config {
    protocol = "HTTPS"
    port     = 443
    path     = "/"
  }
}

resource "azurerm_traffic_manager_azure_endpoint" "web_west" {
  name               = "web-west"
  profile_id         = azurerm_traffic_manager_profile.tm.id
  target_resource_id = azurerm_windows_web_app.web_west.id
  priority           = 1
  weight             = 100
}

resource "azurerm_traffic_manager_azure_endpoint" "web_central" {
  name               = "web-central"
  profile_id         = azurerm_traffic_manager_profile.tm.id
  target_resource_id = azurerm_windows_web_app.web_central.id
  priority           = 2
  weight             = 100
}

# Autoscale for the west App Service Plan, where Public API is deployed.
resource "azurerm_monitor_autoscale_setting" "api_autoscale" {
  name                = "asp-eshop-west-autoscale"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  target_resource_id  = azurerm_service_plan.west.id
  enabled             = true

  profile {
    name = "default"

    capacity {
      default = 1
      minimum = 1
      maximum = 2
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.west.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 50
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.west.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }
}

output "public_api_url" {
  value = "https://${azurerm_windows_web_app.publicapi.default_hostname}"
}

output "web_west_url" {
  value = "https://${azurerm_windows_web_app.web_west.default_hostname}"
}

output "web_central_url" {
  value = "https://${azurerm_windows_web_app.web_central.default_hostname}"
}

output "traffic_manager_url" {
  value = "https://${azurerm_traffic_manager_profile.tm.fqdn}"
}

output "key_vault_name" {
  value = azurerm_key_vault.sql.name
}
