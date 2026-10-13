# The API and its two jobs share one image. Terraform owns their shape (identity, env, schedule);
# the deploy workflow owns which image runs, so image changes here are ignored after creation.

locals {
  db_env = var.database_enabled ? {
    PGHOST        = azurerm_postgresql_flexible_server.this[0].fqdn
    PGDATABASE    = azurerm_postgresql_flexible_server_database.athena[0].name
    DATABASE_AUTH = "entra"
  } : {}

  # Without database settings the API starts in stub mode (sample data, no DB-backed endpoints).
  api_env = merge(local.db_env, {
    ATHENA_ENV                            = var.environment
    PGUSER                                = azurerm_user_assigned_identity.api.name
    AZURE_CLIENT_ID                       = azurerm_user_assigned_identity.api.client_id
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this.connection_string
    SERVICE_BUS_NAMESPACE                 = "${azurerm_servicebus_namespace.this.name}.servicebus.windows.net"
  })

  migrate_env = merge(local.db_env, {
    ATHENA_ENV      = var.environment
    PGUSER          = azurerm_user_assigned_identity.migrate.name
    AZURE_CLIENT_ID = azurerm_user_assigned_identity.migrate.client_id
    APP_DB_ROLE     = azurerm_user_assigned_identity.api.name
  })
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${local.name}"
  resource_group_name        = data.azurerm_resource_group.this.name
  location                   = local.workload_location
  log_analytics_workspace_id = var.log_analytics_workspace_id
  tags                       = local.tags
}

resource "azurerm_container_app" "api" {
  name                         = "ca-${local.name}-backend"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = data.azurerm_resource_group.this.name
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.api.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.api.id
  }

  dynamic "secret" {
    for_each = var.hf_token_enabled ? [1] : []
    content {
      name                = "hf-token"
      key_vault_secret_id = "${azurerm_key_vault.this.vault_uri}secrets/hf-token"
      identity            = azurerm_user_assigned_identity.api.id
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.container_min_replicas
    max_replicas = var.container_max_replicas

    container {
      name   = "api"
      image  = var.container_image
      cpu    = var.container_cpu
      memory = var.container_memory

      dynamic "env" {
        for_each = local.api_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.hf_token_enabled ? [1] : []
        content {
          name        = "HF_TOKEN"
          secret_name = "hf-token"
        }
      }

      liveness_probe {
        transport               = "HTTP"
        path                    = "/health"
        port                    = 8080
        interval_seconds        = 15
        timeout                 = 3
        failure_count_threshold = 3
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }

  depends_on = [azurerm_role_assignment.acr_pull, azurerm_role_assignment.api_secrets]
}

resource "azurerm_container_app_job" "migrate" {
  count = var.database_enabled ? 1 : 0

  name                         = "caj-${local.name}-migrate"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = data.azurerm_resource_group.this.name
  location                     = local.workload_location
  replica_timeout_in_seconds   = 300
  replica_retry_limit          = 0
  tags                         = local.tags

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.migrate.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.migrate.id
  }

  template {
    container {
      name    = "migrate"
      image   = var.container_image
      cpu     = 0.25
      memory  = "0.5Gi"
      command = ["sh", "-c", "alembic upgrade head && python scripts/grant_app_role.py"]

      dynamic "env" {
        for_each = local.migrate_env
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_postgresql_flexible_server_active_directory_administrator.migrate,
  ]
}

# Idempotent upsert of athlete data. Runs on the schedule; start it by hand to seed a fresh database.
resource "azurerm_container_app_job" "ingest" {
  count = var.database_enabled ? 1 : 0

  name                         = "caj-${local.name}-ingest"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = data.azurerm_resource_group.this.name
  location                     = local.workload_location
  replica_timeout_in_seconds   = 600
  replica_retry_limit          = 1
  tags                         = local.tags

  schedule_trigger_config {
    cron_expression          = var.ingest_schedule
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.api.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.api.id
  }

  template {
    container {
      name    = "ingest"
      image   = var.container_image
      cpu     = 0.25
      memory  = "0.5Gi"
      command = ["python", "scripts/seed_athletes.py"]

      dynamic "env" {
        for_each = local.api_env
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }

  depends_on = [azurerm_role_assignment.acr_pull]
}
