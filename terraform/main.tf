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

locals {
  prefix         = "eshop"
  rg_name        = "rg-eshop"
  blob_container = "order-requests"

  api_url = "https://${azurerm_windows_web_app.publicapi.default_hostname}"

  order_items_reserver_url = "https://${azurerm_linux_function_app.orderitemsreserver.default_hostname}/api/ReserveOrderItems?code=${data.azurerm_function_app_host_keys.orderitemsreserver.default_function_key}"
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

resource "azurerm_service_plan" "function" {
  name                = "ASP-rgeshop-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_storage_account" "orders" {
  name                     = "eshoporders${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "order_requests" {
  name                  = local.blob_container
  storage_account_id    = azurerm_storage_account.orders.id
  container_access_type = "private"
}

resource "azurerm_linux_function_app" "orderitemsreserver" {
  name                = "orderitemsreserver-func-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  service_plan_id            = azurerm_service_plan.function.id
  storage_account_name       = azurerm_storage_account.orders.name
  storage_account_access_key = azurerm_storage_account.orders.primary_access_key

  site_config {
    application_stack {
      dotnet_version              = "8.0"
      use_dotnet_isolated_runtime = true
    }
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"     = "dotnet-isolated"
    "AzureWebJobsStorage"          = azurerm_storage_account.orders.primary_connection_string
    "BlobStorageConnectionString"  = azurerm_storage_account.orders.primary_connection_string
    "BlobContainerName"            = azurerm_storage_container.order_requests.name
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
  }
}

data "azurerm_function_app_host_keys" "orderitemsreserver" {
  name                = azurerm_linux_function_app.orderitemsreserver.name
  resource_group_name = azurerm_resource_group.rg.name

  depends_on = [
    azurerm_linux_function_app.orderitemsreserver
  ]
}

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
    "UseOnlyInMemoryDatabase"       = "true"
    "ASPNETCORE_ENVIRONMENT"        = "Development"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
  }
}

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
    "UseOnlyInMemoryDatabase"        = "true"
    "ASPNETCORE_ENVIRONMENT"         = "Development"
    "baseUrls__apiBase"              = local.api_url
    "OrderItemsReserverUrl"          = local.order_items_reserver_url
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
  }
}

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
    "UseOnlyInMemoryDatabase"        = "true"
    "ASPNETCORE_ENVIRONMENT"         = "Development"
    "baseUrls__apiBase"              = local.api_url
    "OrderItemsReserverUrl"          = local.order_items_reserver_url
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
  }
}

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
    "UseOnlyInMemoryDatabase"        = "true"
    "ASPNETCORE_ENVIRONMENT"         = "Development"
    "baseUrls__apiBase"              = local.api_url
    "OrderItemsReserverUrl"          = local.order_items_reserver_url
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
  }
}

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

output "orderitemsreserver_function_url" {
  value     = local.order_items_reserver_url
  sensitive = true
}

output "order_requests_container_name" {
  value = azurerm_storage_container.order_requests.name
}