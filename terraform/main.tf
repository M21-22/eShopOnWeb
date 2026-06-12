# terraform apply -var="sql_admin_password=PASSWORD"
# Images must already exist in ACR before the Web Apps become healthy:
#   eshopwebmvc:latest
#   eshoppublicapi:latest

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

variable "sql_admin_login" {
  type    = string
  default = "sqladminuser"
}

variable "sql_admin_password" {
  type      = string
  sensitive = true
}

variable "container_image_tag" {
  type    = string
  default = "latest"
}

locals {
  prefix         = "eshop"
  rg_name        = "rg-eshop"
  primary_region = "West Europe"
  east_region    = "East Asia"
  data_region    = "West Europe"

  web_image = "eshopwebmvc:${var.container_image_tag}"
  api_image = "eshoppublicapi:${var.container_image_tag}"

  sql_connection_string = "Server=tcp:${azurerm_mssql_server.sql.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.eshop.name};Persist Security Info=False;User ID=${var.sql_admin_login};Password=${var.sql_admin_password};MultipleActiveResultSets=True;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

  db_connection_kv_reference = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.sql.name};SecretName=${azurerm_key_vault_secret.db_connection.name})"

  public_api_url               = "https://${azurerm_linux_web_app.publicapi.default_hostname}/"
  reserve_order_items_url      = "https://${azurerm_windows_function_app.orderitems.default_hostname}/api/ReserveOrderItems?code=${data.azurerm_function_app_host_keys.orderitems.default_function_key}"
  delivery_order_processor_url = "https://${azurerm_windows_function_app.delivery.default_hostname}/api/DeliveryOrderProcessor?code=${data.azurerm_function_app_host_keys.delivery.default_function_key}"

  common_container_settings = {
    ASPNETCORE_URLS                    = "http://+:8080"
    WEBSITES_PORT                      = "8080"
    DOCKER_ENABLE_CI                   = "true"
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
  }

  common_seq_settings = {
    "Aspire__Seq__ServerUrl"            = "http://localhost:5341"
    "Aspire__Seq__DisableHealthChecks"  = "true"
  }
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
# Azure Container Registry
# -------------------------
resource "azurerm_container_registry" "acr" {
  name                = "eshopcr${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.primary_region
  sku                 = "Basic"
  admin_enabled       = true
}

# -------------------------
# App Service Plans
# -------------------------
resource "azurerm_service_plan" "container_west" {
  name                = "asp-eshop-container-west"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.primary_region
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_service_plan" "container_east" {
  name                = "asp-eshop-container-east"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.east_region
  os_type             = "Linux"
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
# Azure SQL + Key Vault
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
  name        = "eshop-sql-db"
  server_id   = azurerm_mssql_server.sql.id
  sku_name    = "GP_S_Gen5_1"
  min_capacity = 0.5
  auto_pause_delay_in_minutes = 60
  max_size_gb = 32
  zone_redundant = false
}

resource "azurerm_key_vault" "sql" {
  name                       = "eshop-sql-kv-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = local.primary_region
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
}

resource "azurerm_role_assignment" "current_user_kv_admin" {
  scope                = azurerm_key_vault.sql.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "db_connection" {
  name         = "DbConnectionString"
  value        = local.sql_connection_string
  key_vault_id = azurerm_key_vault.sql.id

  depends_on = [azurerm_role_assignment.current_user_kv_admin]
}

# -------------------------
# Storage, Service Bus, Cosmos DB
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

resource "azurerm_servicebus_namespace" "orders" {
  name                = "eshop-sb-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.primary_region
  sku                 = "Basic"
}

resource "azurerm_servicebus_queue" "orders" {
  name         = "orders"
  namespace_id = azurerm_servicebus_namespace.orders.id
}

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
# Function Apps
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
    FUNCTIONS_WORKER_RUNTIME    = "dotnet-isolated"
    BlobStorageConnectionString = azurerm_storage_account.functions.primary_connection_string
    BlobContainerName           = azurerm_storage_container.order_requests.name
    ServiceBusConnection        = azurerm_servicebus_namespace.orders.default_primary_connection_string
    ServiceBusQueueName         = azurerm_servicebus_queue.orders.name
  }
}

resource "azurerm_windows_function_app" "delivery" {
  name                       = "deliveryorderprocessor-func-${random_string.suffix.result}"
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
    FUNCTIONS_WORKER_RUNTIME = "dotnet-isolated"
    ServiceBusConnection     = azurerm_servicebus_namespace.orders.default_primary_connection_string
    ServiceBusQueueName      = azurerm_servicebus_queue.orders.name
    CosmosDbConnection       = azurerm_cosmosdb_account.delivery.primary_sql_connection_string
    CosmosDbDatabase         = azurerm_cosmosdb_sql_database.delivery.name
    CosmosDbContainer        = azurerm_cosmosdb_sql_container.orders.name
  }
}

data "azurerm_function_app_host_keys" "orderitems" {
  name                = azurerm_windows_function_app.orderitems.name
  resource_group_name = azurerm_resource_group.rg.name

  depends_on = [azurerm_windows_function_app.orderitems]
}

data "azurerm_function_app_host_keys" "delivery" {
  name                = azurerm_windows_function_app.delivery.name
  resource_group_name = azurerm_resource_group.rg.name

  depends_on = [azurerm_windows_function_app.delivery]
}

# -------------------------
# Container Web Apps
# -------------------------
resource "azurerm_linux_web_app" "publicapi" {
  name                = "eshop-c-publicapi-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.container_west.location
  service_plan_id     = azurerm_service_plan.container_west.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on = false

    application_stack {
      docker_image_name        = local.api_image
      docker_registry_url      = "https://${azurerm_container_registry.acr.login_server}"
      docker_registry_username = azurerm_container_registry.acr.admin_username
      docker_registry_password = azurerm_container_registry.acr.admin_password
    }
  }

  app_settings = merge(
    local.common_container_settings,
    local.common_seq_settings,
    {
      ASPNETCORE_ENVIRONMENT                 = "Development"
      UseOnlyInMemoryDatabase                = "false"
      "ConnectionStrings__CatalogConnection" = local.db_connection_kv_reference
      "ConnectionStrings__IdentityConnection" = local.db_connection_kv_reference
    }
  )
}

resource "azurerm_linux_web_app" "web_west" {
  name                = "eshop-c-web-west-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.container_west.location
  service_plan_id     = azurerm_service_plan.container_west.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on = false

    application_stack {
      docker_image_name        = local.web_image
      docker_registry_url      = "https://${azurerm_container_registry.acr.login_server}"
      docker_registry_username = azurerm_container_registry.acr.admin_username
      docker_registry_password = azurerm_container_registry.acr.admin_password
    }
  }

  app_settings = merge(
    local.common_container_settings,
    local.common_seq_settings,
    {
      ASPNETCORE_ENVIRONMENT                  = "Development"
      baseUrls__apiBase                       = local.public_api_url
      "ConnectionStrings__CatalogConnection"  = local.db_connection_kv_reference
      "ConnectionStrings__IdentityConnection" = local.db_connection_kv_reference
      DeliveryOrderProcessorUrl               = local.delivery_order_processor_url
      ServiceBusConnection                    = azurerm_servicebus_namespace.orders.default_primary_connection_string
    }
  )
}

resource "azurerm_linux_web_app" "web_east" {
  name                = "eshop-c-web-east-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.container_east.location
  service_plan_id     = azurerm_service_plan.container_east.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on = false

    application_stack {
      docker_image_name        = local.web_image
      docker_registry_url      = "https://${azurerm_container_registry.acr.login_server}"
      docker_registry_username = azurerm_container_registry.acr.admin_username
      docker_registry_password = azurerm_container_registry.acr.admin_password
    }
  }

  app_settings = merge(
    local.common_container_settings,
    local.common_seq_settings,
    {
      ASPNETCORE_ENVIRONMENT                  = "Development"
      baseUrls__apiBase                       = local.public_api_url
      "ConnectionStrings__CatalogConnection"  = local.db_connection_kv_reference
      "ConnectionStrings__IdentityConnection" = local.db_connection_kv_reference
      DeliveryOrderProcessorUrl               = local.delivery_order_processor_url
      ServiceBusConnection                    = azurerm_servicebus_namespace.orders.default_primary_connection_string
    }
  )
}

# -------------------------
# Deployment Slot for Web West
# -------------------------
resource "azurerm_linux_web_app_slot" "web_west_staging" {
  name           = "staging"
  app_service_id = azurerm_linux_web_app.web_west.id

  site_config {
    always_on = false

    application_stack {
      docker_image_name        = local.web_image
      docker_registry_url      = "https://${azurerm_container_registry.acr.login_server}"
      docker_registry_username = azurerm_container_registry.acr.admin_username
      docker_registry_password = azurerm_container_registry.acr.admin_password
    }
  }

  app_settings = azurerm_linux_web_app.web_west.app_settings
}

# -------------------------
# Key Vault access for Web Apps
# -------------------------
resource "azurerm_role_assignment" "publicapi_kv_secrets_user" {
  scope                = azurerm_key_vault.sql.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.publicapi.identity[0].principal_id
}

resource "azurerm_role_assignment" "web_west_kv_secrets_user" {
  scope                = azurerm_key_vault.sql.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.web_west.identity[0].principal_id
}

resource "azurerm_role_assignment" "web_east_kv_secrets_user" {
  scope                = azurerm_key_vault.sql.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.web_east.identity[0].principal_id
}

# -------------------------
# Traffic Manager
# -------------------------
resource "azurerm_traffic_manager_profile" "tm" {
  name                = "eshop-tm-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
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
  target_resource_id = azurerm_linux_web_app.web_west.id
  priority           = 1
  weight             = 100
}

resource "azurerm_traffic_manager_azure_endpoint" "web_east" {
  name               = "web-east"
  profile_id         = azurerm_traffic_manager_profile.tm.id
  target_resource_id = azurerm_linux_web_app.web_east.id
  priority           = 2
  weight             = 100
}

# -------------------------
# Outputs
# -------------------------
output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "public_api_url" {
  value = "https://${azurerm_linux_web_app.publicapi.default_hostname}"
}

output "web_west_url" {
  value = "https://${azurerm_linux_web_app.web_west.default_hostname}"
}

output "web_east_url" {
  value = "https://${azurerm_linux_web_app.web_east.default_hostname}"
}

output "web_west_staging_url" {
  value = "https://${azurerm_linux_web_app_slot.web_west_staging.default_hostname}"
}

output "traffic_manager_url" {
  value = "https://${azurerm_traffic_manager_profile.tm.fqdn}"
}

output "orderitems_function_app_name" {
  value = azurerm_windows_function_app.orderitems.name
}

output "delivery_function_app_name" {
  value = azurerm_windows_function_app.delivery.name
}

output "sql_server_name" {
  value = azurerm_mssql_server.sql.name
}

output "sql_database_name" {
  value = azurerm_mssql_database.eshop.name
}

output "key_vault_name" {
  value = azurerm_key_vault.sql.name
}

output "servicebus_namespace_name" {
  value = azurerm_servicebus_namespace.orders.name
}

output "servicebus_queue_name" {
  value = azurerm_servicebus_queue.orders.name
}

output "blob_storage_account_name" {
  value = azurerm_storage_account.functions.name
}

output "blob_container_name" {
  value = azurerm_storage_container.order_requests.name
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
