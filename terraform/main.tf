# terraform apply -var="sql_admin_password=PASSWORD"
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

variable "sql_admin_login" {
  type    = string
  default = "sqladminuser"
}

variable "sql_admin_password" {
  type      = string
  sensitive = true
}

locals {
  prefix         = "eshop"
  rg_name        = "rg-eshop"
  primary_region = "West Europe"
  second_region  = "France Central"

  # Use another allowed region if your subscription blocks SQL/Cosmos in the primary region.
  data_region = "West US 2"

  api_url = "https://${azurerm_windows_web_app.publicapi.default_hostname}"

  sql_connection_string = "Server=tcp:${azurerm_mssql_server.sql.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.eshop.name};Persist Security Info=False;User ID=${var.sql_admin_login};Password=${var.sql_admin_password};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

  reserve_order_items_url      = "https://${azurerm_windows_function_app.orderitems.default_hostname}/api/ReserveOrderItems?code=${data.azurerm_function_app_host_keys.orderitems.default_function_key}"
  delivery_order_processor_url = "https://${azurerm_windows_function_app.orderitems.default_hostname}/api/DeliveryOrderProcessor?code=${data.azurerm_function_app_host_keys.orderitems.default_function_key}"
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "azurerm_resource_group" "rg" {
  name     = local.rg_name
  location = local.primary_region
}

# -------------------------
# App Service Plans
# -------------------------

resource "azurerm_service_plan" "west" {
  name                = "asp-eshop-west"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.primary_region
  os_type             = "Windows"
  sku_name            = "S1"
}

resource "azurerm_service_plan" "central" {
  name                = "asp-eshop-central"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.second_region
  os_type             = "Windows"
  sku_name            = "B1"
}

resource "azurerm_service_plan" "functions" {
  name                = "asp-eshop-functions"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.primary_region
  os_type             = "Windows"
  sku_name            = "Y1"
}

# -------------------------
# Azure SQL
# -------------------------

resource "azurerm_mssql_server" "sql" {
  name                         = "eshop-sqlserver-${random_string.suffix.result}"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = local.data_region
  version                      = "12.0"
  administrator_login          = var.sql_admin_login
  administrator_login_password = var.sql_admin_password
}

resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_database" "eshop" {
  name                        = "eShopOnWebDb"
  server_id                   = azurerm_mssql_server.sql.id
  sku_name                    = "GP_S_Gen5_1"
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = 60
  max_size_gb                 = 32
  zone_redundant              = false
}

# -------------------------
# Storage for ReserveOrderItems Function
# -------------------------

resource "azurerm_storage_account" "functions" {
  name                     = "eshopfuncsa${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = local.primary_region
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "order_requests" {
  name                  = "order-requests"
  storage_account_id    = azurerm_storage_account.functions.id
  container_access_type = "private"
}

# -------------------------
# Cosmos DB for DeliveryOrderProcessor Function
# -------------------------

resource "azurerm_cosmosdb_account" "delivery" {
  name                = "eshop-delivery-cosmos-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.data_region
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = local.data_region
    failover_priority = 0
  }

  backup {
    type                = "Periodic"
    interval_in_minutes = 240
    retention_in_hours  = 8
  }
}

resource "azurerm_cosmosdb_sql_database" "delivery" {
  name                = "DeliveryDb"
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.delivery.name
}

resource "azurerm_cosmosdb_sql_container" "orders" {
  name                = "Orders"
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.delivery.name
  database_name       = azurerm_cosmosdb_sql_database.delivery.name
  partition_key_paths = ["/orderId"]
}

# -------------------------
# Function App
# Contains:
# - ReserveOrderItems -> Blob Storage
# - DeliveryOrderProcessor -> Cosmos DB
# -------------------------

resource "azurerm_windows_function_app" "orderitems" {
  name                       = "orderitemsreserver-func-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = local.primary_region
  service_plan_id            = azurerm_service_plan.functions.id
  storage_account_name       = azurerm_storage_account.functions.name
  storage_account_access_key = azurerm_storage_account.functions.primary_access_key
  functions_extension_version = "~4"

  site_config {
    application_stack {
      dotnet_version              = "v8.0"
      use_dotnet_isolated_runtime = true
    }
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME" = "dotnet-isolated"

    "BlobStorageConnectionString" = azurerm_storage_account.functions.primary_connection_string
    "BlobContainerName"           = azurerm_storage_container.order_requests.name

    "CosmosDbConnection" = azurerm_cosmosdb_account.delivery.primary_sql_connection_string
    "CosmosDbDatabase"   = azurerm_cosmosdb_sql_database.delivery.name
    "CosmosDbContainer"  = azurerm_cosmosdb_sql_container.orders.name
  }
}

data "azurerm_function_app_host_keys" "orderitems" {
  name                = azurerm_windows_function_app.orderitems.name
  resource_group_name = azurerm_resource_group.rg.name

  depends_on = [
    azurerm_windows_function_app.orderitems
  ]
}

# -------------------------
# Public API
# -------------------------

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
    "UseOnlyInMemoryDatabase"        = "false"
    "ASPNETCORE_ENVIRONMENT"        = "Development"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"

    "ConnectionStrings__CatalogConnection"  = local.sql_connection_string
    "ConnectionStrings__IdentityConnection" = local.sql_connection_string
  }
}

# -------------------------
# Web App - West Europe
# -------------------------

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
    "UseOnlyInMemoryDatabase"        = "false"
    "ASPNETCORE_ENVIRONMENT"        = "Development"
    "baseUrls__apiBase"             = local.api_url
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"

    "ConnectionStrings__CatalogConnection"  = local.sql_connection_string
    "ConnectionStrings__IdentityConnection" = local.sql_connection_string

    "OrderItemsReserverUrl"      = local.reserve_order_items_url
    "DeliveryOrderProcessorUrl"  = local.delivery_order_processor_url
  }
}

# -------------------------
# Web App - France Central
# -------------------------

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
    "UseOnlyInMemoryDatabase"        = "false"
    "ASPNETCORE_ENVIRONMENT"        = "Development"
    "baseUrls__apiBase"             = local.api_url
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"

    "ConnectionStrings__CatalogConnection"  = local.sql_connection_string
    "ConnectionStrings__IdentityConnection" = local.sql_connection_string

    "OrderItemsReserverUrl"      = local.reserve_order_items_url
    "DeliveryOrderProcessorUrl"  = local.delivery_order_processor_url
  }
}

# -------------------------
# Deployment Slot for Web West
# -------------------------

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
    "UseOnlyInMemoryDatabase"        = "false"
    "ASPNETCORE_ENVIRONMENT"        = "Development"
    "baseUrls__apiBase"             = local.api_url
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"

    "ConnectionStrings__CatalogConnection"  = local.sql_connection_string
    "ConnectionStrings__IdentityConnection" = local.sql_connection_string

    "OrderItemsReserverUrl"      = local.reserve_order_items_url
    "DeliveryOrderProcessorUrl"  = local.delivery_order_processor_url
  }
}

# -------------------------
# Traffic Manager
# -------------------------

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

# -------------------------
# Autoscale
# -------------------------

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

# -------------------------
# Outputs
# -------------------------

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

output "function_app_name" {
  value = azurerm_windows_function_app.orderitems.name
}

output "sql_server_name" {
  value = azurerm_mssql_server.sql.name
}

output "sql_database_name" {
  value = azurerm_mssql_database.eshop.name
}

output "cosmos_account_name" {
  value = azurerm_cosmosdb_account.delivery.name
}

output "cosmos_database_name" {
  value = azurerm_cosmosdb_sql_database.delivery.name
}

output "cosmos_container_name" {
  value = azurerm_cosmosdb_sql_container.orders.name
}