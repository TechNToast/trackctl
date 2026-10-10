output "container_app_url" {
  value = "https://${azurerm_container_app.api.ingress[0].fqdn}"
}

output "container_app_name" {
  value = azurerm_container_app.api.name
}

output "container_registry" {
  value = azurerm_container_registry.this.name
}

output "migrate_job" {
  value = azurerm_container_app_job.migrate.name
}

output "ingest_job" {
  value = azurerm_container_app_job.ingest.name
}

output "key_vault" {
  value = azurerm_key_vault.this.name
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}
