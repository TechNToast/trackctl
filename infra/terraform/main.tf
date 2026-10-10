# Athena runs inside a resource group, log workspace, and deploy identity owned by techntoast-platform.
# Nothing here uses passwords or shared keys: every service-to-service call signs in with one of the
# two managed identities below.
#
#   api      the API and the ingest job. Reads/writes data; reads secrets; sends/receives messages.
#   migrate  the migration job. Database administrator; runs schema changes and grants the api role.

locals {
  name   = "athena-${var.environment}"
  suffix = var.resource_name_suffix
  tags   = data.azurerm_resource_group.this.tags
}

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "this" {
  name = "rg-athena-${var.environment}"
}

resource "azurerm_user_assigned_identity" "api" {
  name                = "id-${local.name}-api"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "migrate" {
  name                = "id-${local.name}-migrate"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  tags                = local.tags
}

# --- Registry ---

resource "azurerm_container_registry" "this" {
  name                   = replace("acr${local.name}${local.suffix}", "-", "")
  resource_group_name    = data.azurerm_resource_group.this.name
  location               = data.azurerm_resource_group.this.location
  sku                    = "Basic"
  admin_enabled          = false
  anonymous_pull_enabled = false
  tags                   = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  for_each = {
    api     = azurerm_user_assigned_identity.api.principal_id
    migrate = azurerm_user_assigned_identity.migrate.principal_id
  }

  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = each.value
  principal_type       = "ServicePrincipal"
}

# --- Secrets ---

resource "azurerm_key_vault" "this" {
  name                       = "kv-${local.name}-${local.suffix}"
  resource_group_name        = data.azurerm_resource_group.this.name
  location                   = data.azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = var.key_vault_purge_protection
  soft_delete_retention_days = var.key_vault_purge_protection ? 90 : 7
  tags                       = local.tags
}

resource "azurerm_role_assignment" "api_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Telemetry (sends to the shared environment workspace; Entra auth only) ---

resource "azurerm_application_insights" "this" {
  name                         = "appi-${local.name}"
  resource_group_name          = data.azurerm_resource_group.this.name
  location                     = data.azurerm_resource_group.this.location
  workspace_id                 = var.log_analytics_workspace_id
  application_type             = "web"
  local_authentication_enabled = false
  tags                         = local.tags
}

resource "azurerm_role_assignment" "api_telemetry" {
  scope                = azurerm_application_insights.this.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Messaging ---

resource "azurerm_servicebus_namespace" "this" {
  name                = "sb-${local.name}-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  sku                 = "Basic"
  local_auth_enabled  = false
  minimum_tls_version = "1.2"
  tags                = local.tags
}

resource "azurerm_servicebus_queue" "notifications" {
  name                  = "notifications"
  namespace_id          = azurerm_servicebus_namespace.this.id
  max_size_in_megabytes = 1024
  default_message_ttl   = "P14D"
}

resource "azurerm_role_assignment" "api_servicebus" {
  for_each = toset(["Azure Service Bus Data Sender", "Azure Service Bus Data Receiver"])

  scope                = azurerm_servicebus_namespace.this.id
  role_definition_name = each.key
  principal_id         = azurerm_user_assigned_identity.api.principal_id
  principal_type       = "ServicePrincipal"
}
