terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  prefix   = "eshop"
  rg_name  = "rg-eshop"
  api_url  = "https://${azurerm_windows_web_app.publicapi.default_hostname}"
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

# Public API
resource "azurerm_windows_web_app" "publicapi" {
  name                = "eshop-publicapi-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.west.location
  service_plan_id     = azurerm_service_plan.west.id

  site_config {
    application_stack {
      current_stack  = "dotnet"
      dotnet_version = "v8.0"
    }
  }

  app_settings = {
    "UseOnlyInMemoryDatabase"     = "true"
    "ASPNETCORE_ENVIRONMENT"     = "Development"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
  }
}

# Web app - West Europe
resource "azurerm_windows_web_app" "web_west" {
  name                = "eshop-web-west-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.west.location
  service_plan_id     = azurerm_service_plan.west.id

  site_config {
    application_stack {
      current_stack  = "dotnet"
      dotnet_version = "v8.0"
    }
  }

  app_settings = {
    "UseOnlyInMemoryDatabase"     = "true"
    "ASPNETCORE_ENVIRONMENT"     = "Development"
    "baseUrls__apiBase"          = local.api_url
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
  }
}

# Web app - France Central
resource "azurerm_windows_web_app" "web_central" {
  name                = "eshop-web-central-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.central.location
  service_plan_id     = azurerm_service_plan.central.id

  site_config {
    application_stack {
      current_stack  = "dotnet"
      dotnet_version = "v8.0"
    }
  }

  app_settings = {
    "UseOnlyInMemoryDatabase"     = "true"
    "ASPNETCORE_ENVIRONMENT"     = "Development"
    "baseUrls__apiBase"          = local.api_url
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
  }
}

# Deployment slot for Web West
resource "azurerm_windows_web_app_slot" "web_west_staging" {
  name           = "staging"
  app_service_id = azurerm_windows_web_app.web_west.id

  site_config {
    application_stack {
      current_stack  = "dotnet"
      dotnet_version = "v8.0"
    }
  }

  app_settings = {
    "UseOnlyInMemoryDatabase"     = "true"
    "ASPNETCORE_ENVIRONMENT"     = "Development"
    "baseUrls__apiBase"          = local.api_url
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
  }
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

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
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