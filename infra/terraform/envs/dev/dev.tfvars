environment          = "dev"
resource_name_suffix = "tnt"

container_min_replicas = 0
container_max_replicas = 1

# Postgres is restricted in eastus2 for this subscription until Microsoft approves region access.
database_enabled = false

key_vault_purge_protection = false
hf_token_enabled           = false
