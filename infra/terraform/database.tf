# Postgres with Entra sign-in only: no admin password exists. Administrators are the migrate identity
# (for CI) and the operators group (for you). The API's own role is created by the migrate job
# (backend/scripts/grant_app_role.py) with read/write on tables and nothing else.

resource "azurerm_postgresql_flexible_server" "this" {
  count = var.database_enabled ? 1 : 0

  name                          = "psql-${local.name}-${local.suffix}"
  resource_group_name           = data.azurerm_resource_group.this.name
  location                      = local.workload_location
  version                       = "16"
  sku_name                      = var.postgres_sku_name
  storage_mb                    = var.postgres_storage_mb
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true
  tags                          = local.tags

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "athena" {
  count = var.database_enabled ? 1 : 0

  name      = "athena"
  server_id = azurerm_postgresql_flexible_server.this[0].id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# Reachable from Azure services only (Container Apps has no fixed outbound IP without a VNet).
# With password sign-in off, a connection still needs a valid Entra token for an admin or the api role.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  count = var.database_enabled ? 1 : 0

  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.this[0].id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "migrate" {
  count = var.database_enabled ? 1 : 0

  server_name         = azurerm_postgresql_flexible_server.this[0].name
  resource_group_name = data.azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = azurerm_user_assigned_identity.migrate.principal_id
  principal_name      = azurerm_user_assigned_identity.migrate.name
  principal_type      = "ServicePrincipal"
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "operators" {
  count = var.database_enabled ? 1 : 0

  server_name         = azurerm_postgresql_flexible_server.this[0].name
  resource_group_name = data.azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.operators_group_id
  principal_name      = var.operators_group_name
  principal_type      = "Group"

  # The server accepts one administrator change at a time.
  depends_on = [azurerm_postgresql_flexible_server_active_directory_administrator.migrate]
}
